import SwiftUI

// (Not Boring) Camera 스타일 팔레트 — Graphite 스킨 근사
enum Body3D {
    static let bodyTop = Color(red: 0.23, green: 0.23, blue: 0.24)
    static let bodyBottom = Color(red: 0.11, green: 0.11, blue: 0.12)
    static let track = Color(red: 0.17, green: 0.17, blue: 0.18)
    static let accent = Color(red: 1.0, green: 0.35, blue: 0.21) // Persimmon
    static let lcdAmber = Color(red: 1.0, green: 0.82, blue: 0.30)
}

// 눌림 시 스프링 스케일 + rigid 햅틱 — 하드웨어 버튼 촉감
struct TactileButtonStyle: ButtonStyle {
    var scale: CGFloat = 0.90
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? scale : 1.0)
            .animation(.spring(response: 0.18, dampingFraction: 0.55), value: configuration.isPressed)
            .onChange(of: configuration.isPressed) { _, pressed in
                if pressed { UIImpactFeedbackGenerator(style: .rigid).impactOccurred() }
            }
    }
}

struct ContentView: View {
    @StateObject private var camera = CameraManager()
    @State private var baseZoom: CGFloat = 1

    var body: some View {
        ZStack {
            LinearGradient(colors: [Body3D.bodyTop, Body3D.bodyBottom],
                           startPoint: .top, endPoint: .bottom)
                .ignoresSafeArea()

            VStack(spacing: 0) {
                topBar
                // 뷰파인더는 남는 공간 중앙에, 상단바/컨트롤은 위아래 고정
                ZStack { viewfinder }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                controlDeck
            }

            if camera.permissionDenied {
                Text("설정에서 카메라 권한을 허용해주세요.")
                    .padding()
                    .background(.black.opacity(0.7), in: RoundedRectangle(cornerRadius: 12))
            }
        }
        .statusBarHidden()
        .onAppear { camera.start() }
    }

    // MARK: - 상단 바

    private var topBar: some View {
        HStack {
            if camera.isRecording {
                Label("REC", systemImage: "circle.fill")
                    .font(.system(size: 15, weight: .bold, design: .monospaced))
                    .foregroundStyle(.red)
            }
            Spacer()
            // 비율 순환 (9:16 → 3:4 → 1:1)
            Button {
                UISelectionFeedbackGenerator().selectionChanged()
                camera.aspect = camera.aspect.next
            } label: {
                Text(camera.aspect.rawValue)
                    .font(.system(size: 13, weight: .bold, design: .monospaced))
                    .foregroundStyle(.white)
                    .frame(width: 48, height: 44)
                    .background(Body3D.track, in: Capsule())
                    .overlay(Capsule().stroke(.white.opacity(0.12), lineWidth: 1))
            }
            .buttonStyle(TactileButtonStyle())
            .disabled(camera.isRecording)

            // 광각 토글 (후면만)
            if camera.position == .back {
                Button {
                    UISelectionFeedbackGenerator().selectionChanged()
                    camera.toggleUltraWide()
                } label: {
                    Text(camera.isUltraWide ? "0.5x" : "1x")
                        .font(.system(size: 13, weight: .bold, design: .monospaced))
                        .foregroundStyle(camera.isUltraWide ? Body3D.lcdAmber : .white)
                        .frame(width: 48, height: 44)
                        .background(Body3D.track, in: Capsule())
                        .overlay(Capsule().stroke(.white.opacity(0.12), lineWidth: 1))
                }
                .buttonStyle(TactileButtonStyle())
                .disabled(camera.isRecording)
            }

            iconButton(camera.timestampOn ? "calendar.badge.clock" : "calendar.badge.minus",
                       tint: camera.timestampOn ? Body3D.lcdAmber : .gray) {
                camera.timestampOn.toggle()
            }
        }
        .padding(.horizontal, 20)
        .frame(height: 48)
    }

    private func iconButton(_ name: String, tint: Color, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: name)
                .font(.system(size: 19, weight: .semibold))
                .foregroundStyle(tint)
                .frame(width: 44, height: 44)
                .background(Body3D.track, in: Circle())
                .overlay(Circle().stroke(.white.opacity(0.12), lineWidth: 1))
        }
        .buttonStyle(TactileButtonStyle())
    }

    // MARK: - 뷰파인더: 바디 안의 창

    private var viewfinder: some View {
        MetalPreviewView(camera: camera)
            .aspectRatio(camera.aspect.ratio, contentMode: .fit)
            .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 20, style: .continuous)
                    .stroke(.black.opacity(0.8), lineWidth: 2)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 20, style: .continuous)
                    .stroke(.white.opacity(0.15), lineWidth: 1)
                    .padding(1)
            )
            .shadow(color: .black.opacity(0.6), radius: 6, y: 4)
            .padding(.horizontal, 12)
            .gesture(
                MagnifyGesture()
                    .onChanged { value in
                        camera.setZoom(baseZoom * value.magnification)
                    }
                    .onEnded { _ in
                        baseZoom = camera.currentZoom
                    }
            )
    }

    // MARK: - 하단 컨트롤 데크

    private var controlDeck: some View {
        VStack(spacing: 14) {
            if camera.filter == .digicam { modelDial }
            if camera.filter == .recipe { recipeDial }
            if camera.filter == .dither || camera.filter == .eink { ditherSlider }
            filterDial

            HStack {
                modeToggle
                Spacer()
                shutterButton
                Spacer()
                iconButton("arrow.triangle.2.circlepath.camera", tint: .white) {
                    camera.switchCamera()
                }
                .disabled(camera.isRecording)
                .frame(width: 96)
            }
            .padding(.horizontal, 28)
        }
        .padding(.top, 14)
        .padding(.bottom, 10)
    }

    private var filterDial: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 10) {
            ForEach(Filter.allCases) { f in
                Button {
                    UISelectionFeedbackGenerator().selectionChanged()
                    withAnimation(.spring(response: 0.35, dampingFraction: 0.75)) {
                        camera.filter = f
                    }
                } label: {
                    Text(f.rawValue)
                        .font(.system(size: 14, weight: .bold, design: .rounded))
                        .fixedSize()
                        .foregroundStyle(camera.filter == f ? .black : .white.opacity(0.8))
                        .padding(.horizontal, 14)
                        .padding(.vertical, 9)
                        .background(
                            camera.filter == f ? AnyShapeStyle(.white) : AnyShapeStyle(Body3D.track),
                            in: Capsule())
                        .overlay(Capsule().stroke(.white.opacity(0.12), lineWidth: 1))
                        .scaleEffect(camera.filter == f ? 1.08 : 1.0)
                }
                .buttonStyle(TactileButtonStyle(scale: 0.94))
            }
            }
            .padding(.horizontal, 16)
        }
    }

    private var modelDial: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(DigicamModel.all) { model in
                    Button {
                        UISelectionFeedbackGenerator().selectionChanged()
                        camera.digicamModel = model
                    } label: {
                        Text(model.name)
                            .font(.system(size: 12, weight: .semibold, design: .monospaced))
                            .foregroundStyle(camera.digicamModel == model ? .black : Body3D.lcdAmber)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 7)
                            .background(
                                camera.digicamModel == model
                                    ? AnyShapeStyle(Body3D.lcdAmber) : AnyShapeStyle(Body3D.track),
                                in: Capsule())
                            .overlay(Capsule().stroke(Body3D.lcdAmber.opacity(0.3), lineWidth: 1))
                    }
                    .buttonStyle(TactileButtonStyle(scale: 0.94))
                }
            }
            .padding(.horizontal, 16)
        }
    }

    private var recipeDial: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(RecipePreset.all) { preset in
                    Button {
                        UISelectionFeedbackGenerator().selectionChanged()
                        camera.recipePreset = preset
                    } label: {
                        Text(preset.name)
                            .font(.system(size: 12, weight: .semibold, design: .monospaced))
                            .foregroundStyle(camera.recipePreset == preset ? .black : Body3D.lcdAmber)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 7)
                            .background(
                                camera.recipePreset == preset
                                    ? AnyShapeStyle(Body3D.lcdAmber) : AnyShapeStyle(Body3D.track),
                                in: Capsule())
                            .overlay(Capsule().stroke(Body3D.lcdAmber.opacity(0.3), lineWidth: 1))
                    }
                    .buttonStyle(TactileButtonStyle(scale: 0.94))
                }
            }
            .padding(.horizontal, 16)
        }
    }

    private var ditherSlider: some View {
        HStack(spacing: 12) {
            Image(systemName: "square.grid.3x3")
                .foregroundStyle(.white.opacity(0.7))
            Slider(value: $camera.ditherBlock, in: 1...6, step: 1)
                .tint(Body3D.accent)
                .onChange(of: camera.ditherBlock) { _, _ in
                    UISelectionFeedbackGenerator().selectionChanged()
                }
            Text("\(Int(camera.ditherBlock))px")
                .font(.system(size: 13, weight: .semibold, design: .monospaced))
                .foregroundStyle(Body3D.lcdAmber)
                .frame(width: 36)
        }
        .padding(.horizontal, 32)
    }

    private var modeToggle: some View {
        HStack(spacing: 4) {
            ForEach(CaptureMode.allCases) { m in
                Button {
                    UISelectionFeedbackGenerator().selectionChanged()
                    withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
                        camera.mode = m
                    }
                } label: {
                    Image(systemName: m == .photo ? "camera.fill" : "video.fill")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(camera.mode == m ? .black : .white.opacity(0.6))
                        .frame(width: 44, height: 36)
                        .background(
                            camera.mode == m ? AnyShapeStyle(.white) : AnyShapeStyle(.clear),
                            in: Capsule())
                }
            }
        }
        .padding(3)
        .background(Body3D.track, in: Capsule())
        .overlay(Capsule().stroke(.white.opacity(0.12), lineWidth: 1))
        .frame(width: 96)
        .disabled(camera.isRecording)
    }

    private var shutterButton: some View {
        Button(action: camera.shutterTapped) {
            ZStack {
                Circle()
                    .fill(LinearGradient(colors: [.white.opacity(0.25), .clear],
                                         startPoint: .top, endPoint: .bottom))
                    .frame(width: 78, height: 78)
                    .background(Body3D.track, in: Circle())
                    .overlay(Circle().stroke(.white.opacity(0.25), lineWidth: 1.5))

                if camera.mode == .video {
                    RoundedRectangle(cornerRadius: camera.isRecording ? 7 : 29)
                        .fill(Body3D.accent)
                        .frame(width: camera.isRecording ? 30 : 58,
                               height: camera.isRecording ? 30 : 58)
                        .animation(.spring(response: 0.3, dampingFraction: 0.7), value: camera.isRecording)
                } else {
                    Circle()
                        .fill(LinearGradient(colors: [.white, Color(white: 0.82)],
                                             startPoint: .top, endPoint: .bottom))
                        .frame(width: 58, height: 58)
                }
            }
            .shadow(color: .black.opacity(0.5), radius: 8, y: 5)
        }
        .buttonStyle(TactileButtonStyle())
    }
}
