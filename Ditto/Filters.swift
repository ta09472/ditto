import CoreImage
import Foundation
import UIKit

// 캠코더식 오렌지 타임스탬프. 1분에 한 번만 다시 그려서 캐시.
enum Timestamp {
    private static var cached: (text: String, image: CIImage)?

    static func image() -> CIImage {
        // 레퍼런스 디카 스타일: "10:09 PM" / "2011/02/16" 두 줄, 우측 정렬
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US")
        formatter.dateFormat = "h:mm a'\n'yyyy/MM/dd"
        let text = formatter.string(from: Date())
        if let cached, cached.text == text { return cached.image }

        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .right
        let font = UIFont(name: "DotGothic16-Regular", size: 20)
            ?? .monospacedDigitSystemFont(ofSize: 18, weight: .bold)
        let attrs: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: UIColor(red: 1.0, green: 0.62, blue: 0.1, alpha: 0.9),
            .paragraphStyle: paragraph,
            .strokeWidth: -2.0,
            .strokeColor: UIColor(white: 0.3, alpha: 0.5),
        ]
        let bounds = (text as NSString).boundingRect(
            with: CGSize(width: 600, height: 200),
            options: .usesLineFragmentOrigin, attributes: attrs, context: nil)
        let size = CGSize(width: ceil(bounds.width), height: ceil(bounds.height))
        let renderer = UIGraphicsImageRenderer(size: size)
        let uiImage = renderer.image { _ in
            (text as NSString).draw(with: CGRect(origin: .zero, size: size),
                                    options: .usesLineFragmentOrigin,
                                    attributes: attrs, context: nil)
        }
        let ci = CIImage(image: uiImage)!
        cached = (text, ci)
        return ci
    }

    // 우하단에 합성. 이미지 해상도에 비례해 스케일 (프리뷰 1080 기준)
    static func stamp(on image: CIImage) -> CIImage {
        let scale = image.extent.width / 1080
        let ts = Self.image().transformed(by: .init(scaleX: scale, y: scale))
        let margin = 36 * scale
        let translated = ts.transformed(by: .init(
            translationX: image.extent.maxX - ts.extent.width - margin,
            y: image.extent.minY + margin))
        return translated.composited(over: image)
    }
}

// 실기종 스펙 기반 파라미터 (docs/research.md 참고)
struct DigicamModel: Identifiable, Equatable {
    let name: String
    let videoWidth: CGFloat   // 영상 모드 가로 해상도
    let halfFps: Bool         // 15fps 기종이면 true (30fps 입력 절반 사용)
    let saturation: Float     // 1.0 = 원본
    let rGain: Float
    let bGain: Float
    let sharpen: Float
    let noise: Float
    let bloom: Float

    var id: String { name }

    // 실기종 리뷰/스펙 기반 (docs/research.md §6). 일부 항목은 동세대 유추값
    static let all: [DigicamModel] = [
        .init(name: "KENOX 410", videoWidth: 640, halfFps: true,
              saturation: 1.20, rGain: 0.97, bGain: 1.05, sharpen: 0.20, noise: 0.025, bloom: 1.2),
        .init(name: "IXUS 90", videoWidth: 640, halfFps: false,
              saturation: 1.10, rGain: 1.02, bGain: 1.00, sharpen: 0.10, noise: 0.018, bloom: 1.4),
        .init(name: "CYBER-SHOT W81", videoWidth: 640, halfFps: false,
              saturation: 1.25, rGain: 1.06, bGain: 0.95, sharpen: 0.30, noise: 0.02, bloom: 1.0),
        .init(name: "EXILIM Z2300", videoWidth: 1280, halfFps: false,
              saturation: 1.15, rGain: 1.04, bGain: 0.98, sharpen: 0.15, noise: 0.015, bloom: 1.3),
        .init(name: "COOLPIX S3700", videoWidth: 1280, halfFps: false,
              saturation: 1.20, rGain: 1.00, bGain: 1.02, sharpen: 0.35, noise: 0.008, bloom: 0.8),
        .init(name: "POWERSHOT G9", videoWidth: 640, halfFps: false,
              saturation: 0.95, rGain: 1.00, bGain: 1.00, sharpen: 0.55, noise: 0.01, bloom: 0.6),
        .init(name: "IXUS 20", videoWidth: 640, halfFps: true,
              saturation: 1.10, rGain: 1.02, bGain: 1.00, sharpen: 0.05, noise: 0.03, bloom: 1.6),
    ]
}

// 핀터레스트 레시피들을 자체 프리셋으로 변환 (원 레시피 수치를 셰이더 단위로 정규화)
struct RecipePreset: Identifiable, Equatable {
    let name: String
    let tone: CIVector   // exposure곱, contrast, highlights, shadows
    let color: CIVector  // saturation, vibrance, rGain, bGain
    let fx: CIVector     // fade, sharpen, grain, vignette
    let shTint: CIVector // 섀도우 틴트 RGB
    let hiTint: CIVector // 하이라이트 틴트 RGB

    var id: String { name }
    static func == (a: RecipePreset, b: RecipePreset) -> Bool { a.name == b.name }

    static let neutral = CIVector(x: 1, y: 1, z: 1, w: 0)

    static let all: [RecipePreset] = [
        // iPhone 사진앱 "retro": dramatic warm, 하이라이트 -100, 대비 -47, 채도 +43
        .init(name: "RETRO",
              tone: .init(x: 0.92, y: 0.82, z: -0.35, w: 0.05),
              color: .init(x: 1.35, y: 0.1, z: 1.06, w: 0.93),
              fx: .init(x: 0.3, y: 0.4, z: 0.02, w: 0.5),
              shTint: .init(x: 1.0, y: 0.98, z: 0.95, w: 0),
              hiTint: .init(x: 1.04, y: 1.0, z: 0.92, w: 0)),
        // "1990's Film": 웜, vibrance 위주, 블랙포인트↑, 비네트
        .init(name: "1990 FILM",
              tone: .init(x: 0.88, y: 1.08, z: -0.1, w: -0.08),
              color: .init(x: 0.96, y: 0.45, z: 1.06, w: 0.94),
              fx: .init(x: 0.1, y: 0.35, z: 0.015, w: 0.65),
              shTint: neutral, hiTint: .init(x: 1.05, y: 1.01, z: 0.9, w: 0)),
        // VSCO "Retro 90s" P5: 페이드+그레인 강함
        .init(name: "90S TAPE",
              tone: .init(x: 0.9, y: 0.92, z: 0.0, w: 0.15),
              color: .init(x: 1.18, y: 0.1, z: 1.02, w: 0.98),
              fx: .init(x: 0.45, y: 0.25, z: 0.045, w: 0.3),
              shTint: neutral, hiTint: .init(x: 1.02, y: 1.0, z: 0.96, w: 0)),
        // VSCO "old film": 섀도우 리프트, 샤픈 강함, 그레인/비네트
        .init(name: "OLD FILM",
              tone: .init(x: 0.92, y: 0.95, z: 0.05, w: 0.12),
              color: .init(x: 0.95, y: 0.15, z: 1.0, w: 1.0),
              fx: .init(x: 0.18, y: 0.7, z: 0.03, w: 0.55),
              shTint: .init(x: 0.98, y: 1.0, z: 1.02, w: 0), hiTint: neutral),
        // VSCO "1998 CAM" M3: 일본 골목 그린-시안, 저대비
        .init(name: "1998 CAM",
              tone: .init(x: 0.85, y: 0.82, z: 0.2, w: 0.2),
              color: .init(x: 1.15, y: 0.1, z: 0.97, w: 1.0),
              fx: .init(x: 0.25, y: 0.2, z: 0.012, w: 0.2),
              shTint: .init(x: 0.96, y: 1.02, z: 1.0, w: 0),
              hiTint: .init(x: 0.98, y: 1.01, z: 0.98, w: 0)),
        // VSCO L4: 그린 재팬무드, 저대비+하이라이트 리프트
        .init(name: "L4 ALLEY",
              tone: .init(x: 0.9, y: 0.78, z: 0.28, w: 0.12),
              color: .init(x: 1.06, y: 0.1, z: 0.96, w: 0.99),
              fx: .init(x: 0.2, y: 0.25, z: 0.01, w: 0.15),
              shTint: .init(x: 0.95, y: 1.02, z: 1.0, w: 0), hiTint: neutral),
        // "Vintage" 캠코더 웜: 섀도우 리프트 강, 채도 높음
        .init(name: "VINTAGE",
              tone: .init(x: 0.92, y: 0.92, z: -0.15, w: 0.15),
              color: .init(x: 1.4, y: 0.08, z: 1.07, w: 0.9),
              fx: .init(x: 0.1, y: 0.3, z: 0.025, w: 0.35),
              shTint: .init(x: 1.02, y: 0.99, z: 0.94, w: 0),
              hiTint: .init(x: 1.05, y: 1.0, z: 0.9, w: 0)),
        // Lightroom "Retro": 그린-옐로 스플릿, 화이트 죽임, 블랙 리프트
        .init(name: "GREEN RM",
              tone: .init(x: 0.93, y: 1.1, z: -0.3, w: 0.15),
              color: .init(x: 0.88, y: 0.15, z: 0.98, w: 0.9),
              fx: .init(x: 0.4, y: 0.3, z: 0.02, w: 0.25),
              shTint: .init(x: 0.93, y: 1.0, z: 1.04, w: 0),
              hiTint: .init(x: 1.06, y: 1.03, z: 0.88, w: 0)),
        // "Sweet night dream": 쿨 블루 나이트, 섀도우 리프트+마젠타 틴트
        .init(name: "NIGHT DREAM",
              tone: .init(x: 0.88, y: 0.9, z: -0.12, w: 0.15),
              color: .init(x: 1.28, y: 0.25, z: 0.95, w: 1.08),
              fx: .init(x: 0.08, y: 0.25, z: 0.015, w: 0.3),
              shTint: .init(x: 0.96, y: 0.97, z: 1.06, w: 0),
              hiTint: .init(x: 1.02, y: 0.99, z: 1.02, w: 0)),
        // Foodie IN2: 그린 필름, 페이드+그레인, 웜 하이라이트
        .init(name: "FD GREEN",
              tone: .init(x: 0.92, y: 0.8, z: 0.1, w: 0.2),
              color: .init(x: 1.05, y: 0.1, z: 0.97, w: 0.96),
              fx: .init(x: 0.4, y: 0.15, z: 0.028, w: 0.35),
              shTint: .init(x: 0.94, y: 1.01, z: 0.98, w: 0),
              hiTint: .init(x: 1.03, y: 1.02, z: 0.92, w: 0)),
        // Foodie F Classic FL3: 웜 클래식 필름, 비네트 강함
        .init(name: "FD CLASSIC",
              tone: .init(x: 0.95, y: 0.85, z: -0.1, w: 0.1),
              color: .init(x: 1.1, y: 0.1, z: 1.06, w: 0.9),
              fx: .init(x: 0.25, y: 0.2, z: 0.03, w: 0.9),
              shTint: .init(x: 1.0, y: 0.98, z: 0.94, w: 0),
              hiTint: .init(x: 1.05, y: 1.0, z: 0.92, w: 0)),
        // Foodie VI5: 뉴진스 교복 무드 — 어둡고 뮤트된 그린-웜
        .init(name: "FD VI5",
              tone: .init(x: 0.82, y: 0.85, z: -0.2, w: 0.18),
              color: .init(x: 0.82, y: 0.1, z: 1.03, w: 0.92),
              fx: .init(x: 0.35, y: 0.2, z: 0.028, w: 0.35),
              shTint: .init(x: 0.96, y: 1.0, z: 0.98, w: 0),
              hiTint: .init(x: 1.04, y: 1.02, z: 0.93, w: 0)),
    ]
}

enum Filter: String, CaseIterable, Identifiable {
    case none = "원본"
    case ditto = "Ditto"
    case digicam = "디카"
    case recipe = "레시피"
    case dither = "Dither"
    case eink = "E-ink"

    var id: String { rawValue }

    private static let kernels: [String: CIKernel] = {
        guard let url = Bundle.main.url(forResource: "default", withExtension: "metallib"),
              let data = try? Data(contentsOf: url) else {
            fatalError("default.metallib not found")
        }
        var result: [String: CIKernel] = [:]
        for name in ["dittoLook", "digicamLook", "recipeLook", "ditherLook", "einkLook"] {
            result[name] = try! CIKernel(functionName: name, fromMetalLibraryData: data)
        }
        return result
    }()

    func apply(to image: CIImage, frameCount: Int,
               digicam: DigicamModel = DigicamModel.all[0],
               recipe: RecipePreset = RecipePreset.all[0],
               ditherBlock: Float = 1) -> CIImage {
        let extent = image.extent
        switch self {
        case .none:
            return image

        case .ditto:
            // 640급으로 다운샘플 → 필터 → 원해상도 업스케일 (저화질 룩 + 연산 절감)
            let scale = 640.0 / extent.width
            let small = image.transformed(by: .init(scaleX: scale, y: scale))
            let seed = Float(frameCount % 1000)
            guard let out = Filter.kernels["dittoLook"]!.apply(
                extent: small.extent,
                roiCallback: { _, rect in rect.insetBy(dx: -16, dy: -16) },
                arguments: [small, seed]
            ) else { return image }
            return out
                .transformed(by: .init(scaleX: 1 / scale, y: 1 / scale))
                .samplingNearest()
                .cropped(to: extent)

        case .digicam:
            let scale = digicam.videoWidth / extent.width
            let small = image.transformed(by: .init(scaleX: scale, y: scale))
            guard let out = Filter.kernels["digicamLook"]!.apply(
                extent: small.extent,
                roiCallback: { _, rect in rect.insetBy(dx: -12, dy: -12) },
                arguments: [small, digicam.saturation, digicam.rGain, digicam.bGain,
                            digicam.sharpen, digicam.noise, digicam.bloom]
            ) else { return image }
            // bilinear 업샘플 (nearest는 픽셀 격자가 보여 실기기와 다름)
            return out
                .transformed(by: .init(scaleX: 1 / scale, y: 1 / scale))
                .cropped(to: extent)

        case .recipe:
            // 레시피는 화질 열화가 목적이 아니라 그레이딩 — 1080폭에서 처리
            let scale = min(1.0, 1080.0 / extent.width)
            let small = scale < 1 ? image.transformed(by: .init(scaleX: scale, y: scale)) : image
            guard let out = Filter.kernels["recipeLook"]!.apply(
                extent: small.extent,
                roiCallback: { _, rect in rect.insetBy(dx: -4, dy: -4) },
                arguments: [small, recipe.tone, recipe.color, recipe.fx,
                            recipe.shTint, recipe.hiTint]
            ) else { return image }
            return scale < 1
                ? out.transformed(by: .init(scaleX: 1 / scale, y: 1 / scale)).cropped(to: extent)
                : out

        case .eink:
            let scale = 540.0 / extent.width
            let small = image.transformed(by: .init(scaleX: scale, y: scale))
            guard let out = Filter.kernels["einkLook"]!.apply(
                extent: small.extent,
                roiCallback: { _, rect in rect.insetBy(dx: -8, dy: -8) },
                arguments: [small, ditherBlock]
            ) else { return image }
            return out
                .transformed(by: .init(scaleX: 1 / scale, y: 1 / scale))
                .samplingNearest()
                .cropped(to: extent)

        case .dither:
            let scale = 480.0 / extent.width
            let small = image.transformed(by: .init(scaleX: scale, y: scale))
            guard let out = Filter.kernels["ditherLook"]!.apply(
                extent: small.extent,
                roiCallback: { _, rect in rect.insetBy(dx: -8, dy: -8) },
                arguments: [small, ditherBlock, Float(4.0)]
            ) else { return image }
            return out
                .transformed(by: .init(scaleX: 1 / scale, y: 1 / scale))
                .samplingNearest()
                .cropped(to: extent)
        }
    }
}
