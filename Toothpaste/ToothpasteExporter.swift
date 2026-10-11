import AVFoundation
import AppKit
import CoreVideo
import MetalKit

enum ToothpasteExporter {
    private static let width = 1920
    private static let height = 1080
    private static let fps: Int32 = 30

    static func frame(at time: Double, layout: ToothpasteLayout) -> Double {
        min(1, max(0, (time - ToothpasteLayout.leadIn) / layout.duration))
    }

    private static func surface(shaderURL: URL?, mode: ToothpasteRenderMode)
        throws -> (MetalToothpasteView.Renderer, MTLTexture, MTLRenderPassDescriptor) {
        let renderer = MetalToothpasteView.Renderer(shaderURL: shaderURL, mode: mode, onError: { _ in })
        guard let setup = renderer.setup else { throw ExportError("Metal could not start the export.") }
        let textureDescriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .bgra8Unorm, width: width, height: height, mipmapped: false)
        textureDescriptor.usage = .renderTarget
        guard let texture = setup.device.makeTexture(descriptor: textureDescriptor) else {
            throw ExportError("Metal could not create the export surface.")
        }
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = texture
        pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].storeAction = .store
        pass.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0)
        return (renderer, texture, pass)
    }

    static func image(_ layout: ToothpasteLayout, shaderURL: URL?, mode: ToothpasteRenderMode,
                      backgroundData: Data?, to output: URL) throws {
        let (renderer, texture, pass) = try surface(shaderURL: shaderURL, mode: mode)
        renderer.layout = layout
        renderer.backgroundData = backgroundData
        renderer.progress = 1
        guard let command = renderer.render(pass: pass, size: CGSize(width: width, height: height)) else {
            throw ExportError("Metal could not create the image.")
        }
        let finished = DispatchSemaphore(value: 0)
        command.addCompletedHandler { _ in finished.signal() }
        command.commit()
        guard finished.wait(timeout: .now() + 20) == .success else {
            throw ExportError("Metal did not finish the image.")
        }
        guard command.status == .completed else {
            throw command.error ?? ExportError("Metal failed to draw the image.")
        }
        guard renderer.backgroundReady else { throw ExportError("The background image could not be rendered.") }
        if mode == .glass && !renderer.glassReady {
            throw ExportError("The Toothpaste shader could not render this image.")
        }

        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        texture.getBytes(&pixels, bytesPerRow: width * 4,
                         from: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0)
        for index in stride(from: 0, to: pixels.count, by: 4) {
            let alpha = Int(pixels[index + 3])
            pixels[index] = UInt8(Int(pixels[index]) * alpha / 255)
            pixels[index + 1] = UInt8(Int(pixels[index + 1]) * alpha / 255)
            pixels[index + 2] = UInt8(Int(pixels[index + 2]) * alpha / 255)
            pixels[index + 3] = 255
        }
        guard let provider = CGDataProvider(data: Data(pixels) as CFData),
              let image = CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32,
                                  bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: .byteOrder32Little.union(
                                      CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipFirst.rawValue)),
                                  provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent),
              let png = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]) else {
            throw ExportError("The rendered image could not be encoded as PNG.")
        }
        let temporary = output.deletingLastPathComponent().appendingPathComponent(".\(UUID().uuidString).png")
        defer { try? FileManager.default.removeItem(at: temporary) }
        try png.write(to: temporary)
        if FileManager.default.fileExists(atPath: output.path) {
            _ = try FileManager.default.replaceItemAt(output, withItemAt: temporary)
        } else {
            try FileManager.default.moveItem(at: temporary, to: output)
        }
    }

    static func video(_ layout: ToothpasteLayout, shaderURL: URL?, mode: ToothpasteRenderMode,
                      backgroundData: Data?, to output: URL) throws {
        let temporary = output.deletingLastPathComponent()
            .appendingPathComponent(".\(UUID().uuidString).mp4")
        defer { try? FileManager.default.removeItem(at: temporary) }
        let (renderer, texture, pass) = try surface(shaderURL: shaderURL, mode: mode)
        let size = CGSize(width: width, height: height)
        let duration = ToothpasteLayout.leadIn + layout.duration + ToothpasteLayout.pause + 0.4
        let frames = Int(ceil(duration * Double(fps)))
        let writer = try AVAssetWriter(outputURL: temporary, fileType: .mp4)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: width,
            AVVideoHeightKey: height,
            AVVideoCompressionPropertiesKey: [
                AVVideoAverageBitRateKey: 10_000_000,
                AVVideoExpectedSourceFrameRateKey: fps
            ]
        ])
        let attributes = CVPixelBufferCreationAttributes(
            pixelFormatType: CVPixelFormatType(rawValue: kCVPixelFormatType_32BGRA),
            size: CVImageSize(width: width, height: height))
        let receiver = writer.inputPixelBufferReceiver(for: input, pixelBufferAttributes: attributes)
        try writer.start()
        defer { if writer.status == .writing { writer.cancelWriting() } }
        writer.startSession(atSourceTime: .zero)
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        renderer.layout = layout
        renderer.backgroundData = backgroundData

        for frame in 0..<frames {
            let time = Double(frame) / Double(fps)
            renderer.progress = self.frame(at: time, layout: layout)
            guard let command = renderer.render(pass: pass, size: size) else {
                throw ExportError("Metal could not create video frame \(frame + 1).")
            }
            let finished = DispatchSemaphore(value: 0)
            command.addCompletedHandler { _ in finished.signal() }
            command.commit()
            guard finished.wait(timeout: .now() + 20) == .success else {
                throw ExportError("Metal did not finish video frame \(frame + 1).")
            }
            guard command.status == .completed else {
                throw command.error ?? ExportError("Metal failed to draw video frame \(frame + 1).")
            }
            guard renderer.backgroundReady else { throw ExportError("The background image could not be rendered.") }
            if mode == .glass && !renderer.glassReady {
                throw ExportError("The Toothpaste shader could not render this video.")
            }
            texture.getBytes(&pixels, bytesPerRow: width * 4,
                from: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0)

            guard let pool = receiver.pixelBufferPool else {
                throw ExportError("The video encoder could not create a pixel buffer.")
            }
            var buffer = try pool.makeMutablePixelBuffer()
            try buffer.accessUnsafeMutableRawPlaneBytes { planes in
                guard planes.count == 1, let baseAddress = planes[0].bytes.baseAddress else {
                    throw ExportError("The video encoder could not access a frame.")
                }
                let destination = baseAddress.assumingMemoryBound(to: UInt8.self)
                let rowBytes = planes[0].properties.bytesPerRow
                for rowIndex in 0..<height {
                    let destinationRow = rowIndex * rowBytes
                    let sourceRow = rowIndex * width * 4
                    for columnIndex in 0..<width {
                        let sourcePixel = sourceRow + columnIndex * 4
                        let destinationPixel = destinationRow + columnIndex * 4
                        let alpha = Int(pixels[sourcePixel + 3])
                        destination[destinationPixel] = UInt8(
                            Int(pixels[sourcePixel]) * alpha / 255)
                        destination[destinationPixel + 1] = UInt8(
                            Int(pixels[sourcePixel + 1]) * alpha / 255)
                        destination[destinationPixel + 2] = UInt8(
                            Int(pixels[sourcePixel + 2]) * alpha / 255)
                        destination[destinationPixel + 3] = 255
                    }
                }
            }
            let presentationTime = CMTime(value: Int64(frame), timescale: fps)
            let readyBuffer = CVReadOnlyPixelBuffer(consume buffer)
            let deadline = Date().addingTimeInterval(30)
            while try !receiver.appendImmediately(readyBuffer, with: presentationTime) {
                guard writer.status == .writing, Date() < deadline else {
                    throw writer.error ?? ExportError("The video encoder stopped accepting frames.")
                }
                Thread.sleep(forTimeInterval: 0.005)
            }
        }
        receiver.finish()
        let done = DispatchSemaphore(value: 0)
        writer.finishWriting { done.signal() }
        guard done.wait(timeout: .now() + 30) == .success, writer.status == .completed else {
            throw writer.error ?? ExportError("The video encoder did not finish.")
        }
        if FileManager.default.fileExists(atPath: output.path) {
            _ = try FileManager.default.replaceItemAt(output, withItemAt: temporary)
        } else {
            try FileManager.default.moveItem(at: temporary, to: output)
        }
    }

    private struct ExportError: LocalizedError {
        let errorDescription: String?
        init(_ message: String) { errorDescription = message }
    }
}
