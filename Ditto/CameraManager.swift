import AudioToolbox
import AVFoundation
import CoreImage
import Photos
import UIKit

enum CaptureMode: String, CaseIterable, Identifiable {
    case photo = "사진"
    case video = "비디오"
    var id: String { rawValue }
}

enum AspectRatio: String, CaseIterable {
    case nineSixteen = "9:16"
    case threeFour = "3:4"
    case square = "1:1"

    // 세로 기준 가로/세로 비
    var ratio: CGFloat {
        switch self {
        case .nineSixteen: 9.0 / 16.0
        case .threeFour: 3.0 / 4.0
        case .square: 1.0
        }
    }

    var next: AspectRatio {
        let all = AspectRatio.allCases
        return all[(all.firstIndex(of: self)! + 1) % all.count]
    }
}

final class CameraManager: NSObject, ObservableObject {
    @Published var filter: Filter = .ditto
    @Published var mode: CaptureMode = .photo
    @Published var timestampOn = true
    @Published var digicamModel = DigicamModel.all[0]
    @Published var recipePreset = RecipePreset.all[0]
    @Published var ditherBlock: Float = 1 // 픽셀 블록 크기 (480px 기준)
    @Published var position: AVCaptureDevice.Position = .back
    @Published var aspect: AspectRatio = .nineSixteen
    @Published var isUltraWide = false
    @Published var isRecording = false
    @Published var permissionDenied = false
    private let photoOutput = AVCapturePhotoOutput()

    // 프리뷰가 그려갈 최신 필터 적용 프레임
    let ciContext = CIContext()
    private(set) var latestImage: CIImage?
    var onFrame: (() -> Void)?

    private let session = AVCaptureSession()
    private let sessionQueue = DispatchQueue(label: "camera.session")
    private let videoQueue = DispatchQueue(label: "camera.video")
    private var frameCount = 0
    private var camera: AVCaptureDevice?
    private var cameraInput: AVCaptureDeviceInput?
    private let videoOutput = AVCaptureVideoDataOutput()

    // 녹화
    private var writer: AVAssetWriter?
    private var videoInput: AVAssetWriterInput?
    private var audioInput: AVAssetWriterInput?
    private var pixelBufferAdaptor: AVAssetWriterInputPixelBufferAdaptor?
    private var recordingURL: URL?

    func start() {
        AVCaptureDevice.requestAccess(for: .video) { [weak self] granted in
            guard let self else { return }
            guard granted else {
                DispatchQueue.main.async { self.permissionDenied = true }
                return
            }
            AVCaptureDevice.requestAccess(for: .audio) { _ in
                self.sessionQueue.async { self.configureAndRun() }
            }
        }
    }

    private func configureAndRun() {
        guard session.inputs.isEmpty else { session.startRunning(); return }
        session.beginConfiguration()
        session.sessionPreset = .hd1920x1080

        attachCamera(position: position)

        if let mic = AVCaptureDevice.default(for: .audio),
           let micInput = try? AVCaptureDeviceInput(device: mic),
           session.canAddInput(micInput) {
            session.addInput(micInput)
        }

        videoOutput.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
        videoOutput.setSampleBufferDelegate(self, queue: videoQueue)
        if session.canAddOutput(videoOutput) { session.addOutput(videoOutput) }

        let audioOutput = AVCaptureAudioDataOutput()
        audioOutput.setSampleBufferDelegate(self, queue: videoQueue)
        if session.canAddOutput(audioOutput) { session.addOutput(audioOutput) }

        // 정지 사진은 photoOutput 경로 (Deep Fusion/Smart HDR/고해상도)
        if session.canAddOutput(photoOutput) {
            session.addOutput(photoOutput)
            photoOutput.maxPhotoQualityPrioritization = .balanced
        }

        configureConnections()
        session.commitConfiguration()
        observeInterruptions()
        session.startRunning()
    }

    // 기존 카메라 입력 제거 후 지정 방향 카메라 연결 (beginConfiguration 내에서 호출)
    private func attachCamera(position: AVCaptureDevice.Position) {
        if let cameraInput { session.removeInput(cameraInput) }
        let type: AVCaptureDevice.DeviceType =
            (isUltraWide && position == .back) ? .builtInUltraWideCamera : .builtInWideAngleCamera
        guard let camera = AVCaptureDevice.default(type, for: .video, position: position),
              let input = try? AVCaptureDeviceInput(device: camera),
              session.canAddInput(input) else { return }
        session.addInput(input)
        self.camera = camera
        self.cameraInput = input

        // 30fps 고정 (min/max 둘 다 — 가변 프레임레이트 방지)
        if camera.activeFormat.videoSupportedFrameRateRanges.contains(where: { $0.maxFrameRate >= 30 }),
           (try? camera.lockForConfiguration()) != nil {
            let duration = CMTime(value: 1, timescale: 30)
            camera.activeVideoMinFrameDuration = duration
            camera.activeVideoMaxFrameDuration = duration
            camera.unlockForConfiguration()
        }
    }

    // 입력이 바뀌면 connection이 재생성되므로 회전/손떨림 보정 재설정
    private func configureConnections() {
        if let connection = videoOutput.connection(with: .video) {
            connection.videoRotationAngle = 90 // portrait
            if connection.isVideoStabilizationSupported {
                connection.preferredVideoStabilizationMode = .standard
            }
            connection.isVideoMirrored = position == .front
        }
        photoOutput.connection(with: .video)?.videoRotationAngle = 90
        if let pc = photoOutput.connection(with: .video), pc.isVideoMirroringSupported {
            pc.automaticallyAdjustsVideoMirroring = false
            pc.isVideoMirrored = position == .front
        }
    }

    func switchCamera() {
        position = position == .back ? .front : .back
        reattachCamera()
    }

    func toggleUltraWide() {
        isUltraWide.toggle()
        reattachCamera()
    }

    private func reattachCamera() {
        let newPosition = position
        sessionQueue.async { [self] in
            session.beginConfiguration()
            attachCamera(position: newPosition)
            configureConnections()
            session.commitConfiguration()
        }
    }

    // 선택 비율로 센터 크롭 후 원점 이동
    private func cropToAspect(_ image: CIImage) -> CIImage {
        let e = image.extent
        let target = aspect.ratio
        guard abs(e.width / e.height - target) > 0.01 else { return image }
        var rect = e
        if e.width / e.height > target {
            rect.size.width = e.height * target
            rect.origin.x = e.midX - rect.width / 2
        } else {
            rect.size.height = e.width / target
            rect.origin.y = e.midY - rect.height / 2
        }
        return image.cropped(to: rect)
            .transformed(by: .init(translationX: -rect.origin.x, y: -rect.origin.y))
    }

    // 전화 수신·앱 전환 등으로 세션이 중단되면 죽은 채 남지 않게 복구
    private func observeInterruptions() {
        let center = NotificationCenter.default
        center.addObserver(forName: .AVCaptureSessionInterruptionEnded,
                           object: session, queue: nil) { [weak self] _ in
            guard let self else { return }
            self.sessionQueue.async {
                if !self.session.isRunning { self.session.startRunning() }
            }
        }
        center.addObserver(forName: .AVCaptureSessionRuntimeError,
                           object: session, queue: nil) { [weak self] _ in
            guard let self else { return }
            self.sessionQueue.async {
                if !self.session.isRunning { self.session.startRunning() }
            }
        }
        // 인터럽션 시작 시 녹화 중이면 저장하고 종료 (파일 유실 방지)
        center.addObserver(forName: .AVCaptureSessionWasInterrupted,
                           object: session, queue: nil) { [weak self] _ in
            guard let self else { return }
            DispatchQueue.main.async {
                if self.isRecording { self.shutterTapped() }
            }
        }
    }

    // MARK: - Recording

    // 핀치 제스처 중 계속 호출됨. baseZoom * pinchScale
    func setZoom(_ factor: CGFloat) {
        guard let camera else { return }
        let clamped = min(max(factor, camera.minAvailableVideoZoomFactor),
                          min(camera.maxAvailableVideoZoomFactor, 10))
        sessionQueue.async {
            guard (try? camera.lockForConfiguration()) != nil else { return }
            camera.videoZoomFactor = clamped
            camera.unlockForConfiguration()
        }
    }

    var currentZoom: CGFloat { camera?.videoZoomFactor ?? 1 }

    func shutterTapped() {
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        switch mode {
        case .photo:
            let settings = AVCapturePhotoSettings()
            settings.photoQualityPrioritization = .balanced
            photoOutput.capturePhoto(with: settings, delegate: self)
        case .video:
            AudioServicesPlaySystemSound(isRecording ? 1118 : 1117) // 녹화 시작/종료음
            isRecording ? stopRecording() : startRecording()
        }
    }

    private func savePhoto(_ image: CIImage) {
        guard let data = ciContext.jpegRepresentation(
            of: image,
            colorSpace: CGColorSpaceCreateDeviceRGB(),
            options: [:]
        ) else { return }
        PHPhotoLibrary.requestAuthorization(for: .addOnly) { status in
            guard status == .authorized || status == .limited else { return }
            PHPhotoLibrary.shared().performChanges {
                let request = PHAssetCreationRequest.forAsset()
                request.addResource(with: .photo, data: data, options: nil)
            }
        }
    }

    private func startRecording() {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString + ".mov")
        // 선택 비율에 맞는 출력 크기 (가로 1080 고정)
        let width = 1080
        let height = Int((1080.0 / aspect.ratio).rounded(.toNearestOrEven))
        videoQueue.async { [self] in
            guard let writer = try? AVAssetWriter(url: url, fileType: .mov) else { return }

            let videoInput = AVAssetWriterInput(mediaType: .video, outputSettings: [
                AVVideoCodecKey: AVVideoCodecType.h264,
                AVVideoWidthKey: width,
                AVVideoHeightKey: height,
                AVVideoCompressionPropertiesKey: [
                    AVVideoAverageBitRateKey: 12_000_000,
                    AVVideoExpectedSourceFrameRateKey: 30,
                ],
            ])
            videoInput.expectsMediaDataInRealTime = true
            let adaptor = AVAssetWriterInputPixelBufferAdaptor(
                assetWriterInput: videoInput,
                sourcePixelBufferAttributes: [
                    kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                    kCVPixelBufferWidthKey as String: width,
                    kCVPixelBufferHeightKey as String: height,
                ])
            writer.add(videoInput)

            let audioInput = AVAssetWriterInput(mediaType: .audio, outputSettings: [
                AVFormatIDKey: kAudioFormatMPEG4AAC,
                AVSampleRateKey: 44100,
                AVNumberOfChannelsKey: 1,
            ])
            audioInput.expectsMediaDataInRealTime = true
            writer.add(audioInput)

            self.writer = writer
            self.videoInput = videoInput
            self.audioInput = audioInput
            self.pixelBufferAdaptor = adaptor
            self.recordingURL = url
            DispatchQueue.main.async { self.isRecording = true }
        }
    }

    private func stopRecording() {
        videoQueue.async { [self] in
            guard let writer, let url = recordingURL else { return }
            self.writer = nil
            videoInput = nil
            audioInput = nil
            pixelBufferAdaptor = nil
            DispatchQueue.main.async { self.isRecording = false }
            guard writer.status == .writing else { return }
            writer.finishWriting {
                Self.saveToLibrary(url)
            }
        }
    }

    private static func saveToLibrary(_ url: URL) {
        PHPhotoLibrary.requestAuthorization(for: .addOnly) { status in
            guard status == .authorized || status == .limited else { return }
            PHPhotoLibrary.shared().performChanges {
                PHAssetChangeRequest.creationRequestForAssetFromVideo(atFileURL: url)
            } completionHandler: { _, _ in
                try? FileManager.default.removeItem(at: url)
            }
        }
    }
}

extension CameraManager: AVCapturePhotoCaptureDelegate {
    func photoOutput(_ output: AVCapturePhotoOutput,
                     willCapturePhotoFor resolvedSettings: AVCaptureResolvedPhotoSettings) {
        AudioServicesPlaySystemSound(1108) // 셔터음
    }

    func photoOutput(_ output: AVCapturePhotoOutput,
                     didFinishProcessingPhoto photo: AVCapturePhoto,
                     error: Error?) {
        guard error == nil, let data = photo.fileDataRepresentation(),
              var image = CIImage(data: data, options: [.applyOrientationProperty: true]) else { return }
        image = filter.apply(to: cropToAspect(image), frameCount: frameCount,
                             digicam: digicamModel, recipe: recipePreset,
                             ditherBlock: ditherBlock)
        if timestampOn { image = Timestamp.stamp(on: image) }
        savePhoto(image)
    }
}

extension CameraManager: AVCaptureVideoDataOutputSampleBufferDelegate, AVCaptureAudioDataOutputSampleBufferDelegate {
    func captureOutput(_ output: AVCaptureOutput,
                       didOutput sampleBuffer: CMSampleBuffer,
                       from connection: AVCaptureConnection) {
        if output is AVCaptureAudioDataOutput {
            if let audioInput, writer?.status == .writing, audioInput.isReadyForMoreMediaData {
                audioInput.append(sampleBuffer)
            }
            return
        }

        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        frameCount += 1
        // 15fps 기종은 30fps 입력을 절반만 사용
        if filter == .digicam && digicamModel.halfFps && frameCount % 2 == 1 { return }
        var filtered = filter.apply(to: cropToAspect(CIImage(cvPixelBuffer: pixelBuffer)),
                                    frameCount: frameCount, digicam: digicamModel,
                                    recipe: recipePreset, ditherBlock: ditherBlock)
        if timestampOn { filtered = Timestamp.stamp(on: filtered) }
        latestImage = filtered
        onFrame?()

        // 녹화 중이면 필터 적용 프레임을 인코딩
        guard let writer, let videoInput, let pixelBufferAdaptor else { return }
        let time = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        if writer.status == .unknown {
            writer.startWriting()
            writer.startSession(atSourceTime: time)
        }
        guard writer.status == .writing, videoInput.isReadyForMoreMediaData,
              let pool = pixelBufferAdaptor.pixelBufferPool else { return }
        var outBuffer: CVPixelBuffer?
        CVPixelBufferPoolCreatePixelBuffer(nil, pool, &outBuffer)
        guard let outBuffer else { return }
        ciContext.render(filtered, to: outBuffer)
        pixelBufferAdaptor.append(outBuffer, withPresentationTime: time)
    }
}
