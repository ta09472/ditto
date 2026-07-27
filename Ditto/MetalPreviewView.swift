import MetalKit
import SwiftUI

struct MetalPreviewView: UIViewRepresentable {
    let camera: CameraManager

    func makeUIView(context: Context) -> MTKView {
        let view = MTKView(frame: .zero, device: MTLCreateSystemDefaultDevice())
        view.framebufferOnly = false
        view.isPaused = true
        view.enableSetNeedsDisplay = false
        view.delegate = context.coordinator
        context.coordinator.view = view
        camera.onFrame = { [weak view] in
            view?.draw()
        }
        return view
    }

    func updateUIView(_ uiView: MTKView, context: Context) {}

    func makeCoordinator() -> Renderer { Renderer(camera: camera) }

    final class Renderer: NSObject, MTKViewDelegate {
        let camera: CameraManager
        weak var view: MTKView?
        private lazy var commandQueue = view!.device!.makeCommandQueue()!

        init(camera: CameraManager) { self.camera = camera }

        func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}

        func draw(in view: MTKView) {
            guard let image = camera.latestImage,
                  let drawable = view.currentDrawable,
                  let buffer = commandQueue.makeCommandBuffer() else { return }

            // aspect-fill로 drawable에 맞춤
            let target = view.drawableSize
            let scale = max(target.width / image.extent.width, target.height / image.extent.height)
            let scaled = image.transformed(by: .init(scaleX: scale, y: scale))
            let origin = CGPoint(x: (scaled.extent.width - target.width) / 2,
                                 y: (scaled.extent.height - target.height) / 2)

            camera.ciContext.render(
                scaled,
                to: drawable.texture,
                commandBuffer: buffer,
                bounds: CGRect(origin: origin, size: target),
                colorSpace: CGColorSpaceCreateDeviceRGB()
            )
            buffer.present(drawable)
            buffer.commit()
        }
    }
}
