import MetalKit
import SwiftUI

enum ToothpasteRenderMode {
    case glass
    case depth
}

// Matches the installed text shader's 192-byte buffer and DepthMap.metal.
private struct ToothpasteShaderUniforms {
    var drawableSize = SIMD4<Float>(repeating: 0)
    var textRect = SIMD4<Float>(repeating: 0)
    var animation = SIMD4<Float>(repeating: 0)
    var reserved = SIMD4<Float>(repeating: 0)
    var transform = SIMD4<Float>(repeating: 0)
    var alignedGridBounds = SIMD4<Float>(repeating: 0)
    var pointGridBounds = SIMD4<Float>(repeating: 0)
    var pointGridZBounds = SIMD4<Float>(repeating: 0)
    var keyLight = SIMD4<Float>(repeating: 0)
    var gridSize = SIMD4<Float>(repeating: 0)
    var pathLengthUnit = SIMD4<Float>(repeating: 0)
    var zoomScale = SIMD4<Float>(repeating: 0)
}

private struct ToothpasteShaderSegment {
    var start: SIMD4<Float>
    var end: SIMD4<Float>
    var rangeOfT: SIMD4<Float>
    var startTangent: SIMD4<Float>
    var endTangent: SIMD4<Float>
    var extremity: SIMD4<Float>
}

struct MetalToothpasteView: NSViewRepresentable {
    let layout: ToothpasteLayout?
    let progress: Double
    let shaderURL: URL?
    let mode: ToothpasteRenderMode
    let renderID: Int
    let backgroundData: Data?
    let backgroundID: Int
    let onError: @MainActor @Sendable (String) -> Void

    func makeNSView(context: Context) -> MTKView {
        let view = MTKView()
        view.device = context.coordinator.setup?.device
        view.colorPixelFormat = .bgra8Unorm
        view.clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0)
        view.isPaused = true
        view.enableSetNeedsDisplay = true
        view.framebufferOnly = true
        view.delegate = context.coordinator
        view.layer?.isOpaque = false
        return view
    }

    func updateNSView(_ view: MTKView, context: Context) {
        context.coordinator.layout = layout
        context.coordinator.progress = progress
        context.coordinator.mode = mode
        if context.coordinator.backgroundID != backgroundID {
            context.coordinator.backgroundID = backgroundID
            context.coordinator.backgroundData = backgroundData
            context.coordinator.preparedSize = .zero
        }
        if context.coordinator.renderID != renderID {
            context.coordinator.renderID = renderID
            context.coordinator.preparedSize = .zero
        }
        view.setNeedsDisplay(view.bounds)
    }

    func makeCoordinator() -> Renderer { Renderer(shaderURL: shaderURL, mode: mode, onError: onError) }

    final class Renderer: NSObject, MTKViewDelegate {
        struct Setup {
            let device: MTLDevice
            let queue: MTLCommandQueue
            let glassPipeline: MTLRenderPipelineState?
            let backgroundPipeline: MTLRenderPipelineState
            let depthPipeline: MTLRenderPipelineState
            let vertices: MTLBuffer
            let shaderError: String?

            init(shaderURL: URL?) throws {
                guard let device = MTLCreateSystemDefaultDevice() else { throw Failure("Metal is unavailable on this Mac.") }
                guard let queue = device.makeCommandQueue() else { throw Failure("Metal could not create a command queue.") }
                guard let library = device.makeDefaultLibrary() else { throw Failure("The app's Metal shaders could not be loaded.") }
                func pipeline(vertex: String, fragment: String) throws -> MTLRenderPipelineState {
                    guard let vertexFunction = library.makeFunction(name: vertex),
                          let fragmentFunction = library.makeFunction(name: fragment) else {
                        throw Failure("The app's \(fragment) shader is missing.")
                    }
                    let descriptor = MTLRenderPipelineDescriptor()
                    descriptor.vertexFunction = vertexFunction
                    descriptor.fragmentFunction = fragmentFunction
                    descriptor.colorAttachments[0].pixelFormat = .bgra8Unorm
                    if fragment == "depthFragment" {
                        descriptor.colorAttachments[0].isBlendingEnabled = true
                        descriptor.colorAttachments[0].sourceRGBBlendFactor = .sourceAlpha
                        descriptor.colorAttachments[0].destinationRGBBlendFactor = .oneMinusSourceAlpha
                        descriptor.colorAttachments[0].sourceAlphaBlendFactor = .one
                        descriptor.colorAttachments[0].destinationAlphaBlendFactor = .oneMinusSourceAlpha
                    }
                    return try device.makeRenderPipelineState(descriptor: descriptor)
                }
                self.device = device
                self.queue = queue
                backgroundPipeline = try pipeline(vertex: "depthVertex", fragment: "toothpasteBackgroundFragment")
                depthPipeline = try pipeline(vertex: "depthVertex", fragment: "depthFragment")
                let vertexValues: [Float] = [-1, -1, 1, -1, -1, 1, 1, 1]
                guard let vertices = vertexValues.withUnsafeBytes({ device.makeBuffer(bytes: $0.baseAddress!, length: $0.count) }) else {
                    throw Failure("Metal could not allocate the drawing buffer.")
                }
                self.vertices = vertices
                if let shaderURL {
                    do {
                        let scoped = shaderURL.startAccessingSecurityScopedResource()
                        defer { if scoped { shaderURL.stopAccessingSecurityScopedResource() } }
                        let library = try device.makeLibrary(URL: shaderURL)
                        let constants = MTLFunctionConstantValues()
                        var antialias = false
                        constants.setConstantValue(&antialias, type: .bool, withName: "renderAntialiased")
                        guard let vertex = library.makeFunction(name: "textVertex"),
                              let fragment = try? library.makeFunction(name: "textFragment", constantValues: constants) else {
                            throw Failure("The installed text shader is missing a required function.")
                        }
                        let descriptor = MTLRenderPipelineDescriptor()
                        descriptor.vertexFunction = vertex
                        descriptor.fragmentFunction = fragment
                        descriptor.colorAttachments[0].pixelFormat = .bgra8Unorm
                        descriptor.colorAttachments[0].isBlendingEnabled = true
                        descriptor.colorAttachments[0].sourceRGBBlendFactor = .sourceAlpha
                        descriptor.colorAttachments[0].destinationRGBBlendFactor = .oneMinusSourceAlpha
                        descriptor.colorAttachments[0].sourceAlphaBlendFactor = .sourceAlpha
                        descriptor.colorAttachments[0].destinationAlphaBlendFactor = .oneMinusSourceAlpha
                        glassPipeline = try device.makeRenderPipelineState(descriptor: descriptor)
                        shaderError = nil
                    } catch {
                        glassPipeline = nil
                        shaderError = "The Toothpaste shader could not start: \(error.localizedDescription) Showing Depth."
                    }
                } else {
                    glassPipeline = nil
                    shaderError = nil
                }
            }
        }

        private struct Failure: LocalizedError {
            let errorDescription: String?
            init(_ message: String) { errorDescription = message }
        }

        private(set) var setup: Setup?
        private let onError: @MainActor @Sendable (String) -> Void
        private var reportedErrors = Set<String>()
        var layout: ToothpasteLayout?
        var progress = 0.0
        var mode: ToothpasteRenderMode {
            didSet { if oldValue != mode { reportedErrors.removeAll() } }
        }
        var renderID = -1
        var backgroundID = -1
        var backgroundData: Data?
        var preparedSize = CGSize.zero
        var glassReady: Bool {
            setup?.glassPipeline != nil && neighbor != nil && background != nil
        }
        var backgroundReady: Bool { backgroundData == nil || background != nil }
        private var segments: MTLBuffer?
        private var grid: MTLBuffer?
        private var neighbor: MTLBuffer?
        private var background: MTLTexture?
        private var fallbackReason: String?
        private var segmentCount = 0
        private var uniforms = ToothpasteShaderUniforms()

        init(shaderURL: URL?, mode: ToothpasteRenderMode,
             onError: @escaping @MainActor @Sendable (String) -> Void) {
            self.mode = mode
            self.onError = onError
            super.init()
            guard MemoryLayout<ToothpasteShaderUniforms>.stride == 192,
                  MemoryLayout<ToothpasteShaderSegment>.stride == 96 else {
                report("The Metal shader interface does not match this app.")
                return
            }
            do { setup = try Setup(shaderURL: shaderURL) }
            catch { report("Metal setup failed: \(error.localizedDescription)") }
        }

        private func report(_ message: String) {
            guard reportedErrors.insert(message).inserted else { return }
            let onError = onError
            Task { @MainActor in onError(message) }
        }

        func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {
            preparedSize = .zero
        }

        func draw(in view: MTKView) {
            guard let drawable = view.currentDrawable else { return }
            guard let pass = view.currentRenderPassDescriptor else {
                report("Metal could not create a drawing pass for this window.")
                return
            }
            guard let command = render(pass: pass, size: view.drawableSize) else { return }
            command.present(drawable)
            watch(command)
            command.commit()
        }

        func render(pass: MTLRenderPassDescriptor, size: CGSize) -> MTLCommandBuffer? {
            guard let setup else { return nil }
            guard let layout else {
                guard let command = setup.queue.makeCommandBuffer() else {
                    report("Metal could not create a drawing command.")
                    return nil
                }
                guard let encoder = command.makeRenderCommandEncoder(descriptor: pass) else {
                    report("Metal could not start a drawing pass.")
                    return nil
                }
                if backgroundData != nil || (mode == .glass && setup.glassPipeline != nil) {
                    encodeBackground(in: encoder, setup: setup, size: size)
                }
                encoder.endEncoding()
                return command
            }
            guard size.width > 0, size.height > 0 else { return nil }
            if preparedSize != size { prepare(layout: layout, size: size) }
            guard segmentCount > 0, let segments, let grid else { return nil }

            var shaderUniforms = uniforms
            shaderUniforms.animation.y = Float(min(1, max(0, progress)))
            guard let command = setup.queue.makeCommandBuffer() else {
                report("Metal could not create a drawing command.")
                return nil
            }
            guard let encoder = command.makeRenderCommandEncoder(descriptor: pass) else {
                report("Metal could not start a drawing pass.")
                return nil
            }
            let textPipeline = mode == .glass && neighbor != nil && background != nil
                ? setup.glassPipeline : nil
            let useGlass = textPipeline != nil
            if mode == .glass && !useGlass {
                report(fallbackReason ?? setup.shaderError ?? "The Toothpaste shader could not draw. Showing Depth.")
            }
            if backgroundData != nil || useGlass { encodeBackground(in: encoder, setup: setup, size: size) }
            encoder.setRenderPipelineState(textPipeline ?? setup.depthPipeline)
            encoder.setVertexBuffer(setup.vertices, offset: 0, index: 0)
            encoder.setFragmentBuffer(segments, offset: 0, index: 1)
            encoder.setFragmentBuffer(grid, offset: 0, index: 2)
            encoder.setFragmentBytes(&shaderUniforms, length: MemoryLayout<ToothpasteShaderUniforms>.stride, index: 0)
            if useGlass, let neighbor, let background {
                encoder.setVertexBytes(&shaderUniforms, length: MemoryLayout<ToothpasteShaderUniforms>.stride, index: 1)
                encoder.setFragmentTexture(background, index: 0)
                encoder.setFragmentTexture(background, index: 1)
                encoder.setFragmentBuffer(neighbor, offset: 0, index: 3)
                var backgroundUniforms: [Float] = [1, 0, 0]
                encoder.setFragmentBytes(&backgroundUniforms, length: 12, index: 4)
            }
            encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
            encoder.endEncoding()
            return command
        }

        private func encodeBackground(in encoder: MTLRenderCommandEncoder, setup: Setup, size: CGSize) {
            guard let background else { return }
            encoder.setRenderPipelineState(setup.backgroundPipeline)
            encoder.setVertexBuffer(setup.vertices, offset: 0, index: 0)
            let fill = backgroundData == nil ? 1 : max(Float(size.width) / Float(background.width),
                                                       Float(size.height) / Float(background.height))
            assert(fill.isFinite && fill > 0)
            var backgroundSize: [Float] = [Float(size.width), Float(size.height),
                                           Float(size.width) / (Float(background.width) * fill),
                                           Float(size.height) / (Float(background.height) * fill)]
            encoder.setFragmentBytes(&backgroundSize, length: 16, index: 0)
            encoder.setFragmentTexture(background, index: 0)
            encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
        }

        private func watch(_ command: MTLCommandBuffer) {
            let onError = onError
            command.addCompletedHandler { completed in
                if completed.status == .error {
                    let message = "Metal drawing failed: \(completed.error?.localizedDescription ?? "Unknown GPU error.")"
                    Task { @MainActor in onError(message) }
                }
            }
        }

        private func prepare(layout: ToothpasteLayout, size: CGSize) {
            guard let setup else { return }
            let device = setup.device
            preparedSize = size
            segments = nil
            grid = nil
            neighbor = nil
            background = nil
            fallbackReason = nil
            segmentCount = 0
            let width = Float(size.width), height = Float(size.height)
            let worldWidth = Float(layout.bounds.width), worldHeight = Float(layout.bounds.height)
            let verticalFill = min(0.8, 0.3 * Float(layout.lineCount))
            let unitsPerPixel = max(worldWidth / (width * 0.8), worldHeight / (height * verticalFill))
            let xMin = Float(layout.bounds.minX), xMax = Float(layout.bounds.maxX)
            let yMin = -Float(layout.bounds.maxY), yMax = -Float(layout.bounds.minY)
            let xOffset = (xMin + xMax - width * unitsPerPixel) / 2
            let yOffset = (yMin + yMax - height * unitsPerPixel) / 2

            var segmentValues: [ToothpasteShaderSegment] = []
            var geometry: [(startX: Float, startY: Float, endX: Float, endY: Float, radius: Float)] = []
            var lengths: [Float] = [0]
            var lowX = Float.infinity, lowY = Float.infinity
            var highX = -Float.infinity, highY = -Float.infinity
            var lowZ = Float.infinity, highZ = -Float.infinity
            func add(_ start: ToothpastePoint, _ end: ToothpastePoint, first: Bool, last: Bool) {
                let startX = Float(start.position.x), startY = -Float(start.position.y)
                let endX = Float(end.position.x), endY = -Float(end.position.y)
                let deltaX = endX - startX, deltaY = endY - startY
                let squared = deltaX * deltaX + deltaY * deltaY
                let startRadius = Float(start.width)
                let endRadius = Float(end.width)
                let radius = max(startRadius, endRadius)
                let inverse = squared > 0.000001 ? 1 / squared : 0
                segmentValues.append(ToothpasteShaderSegment(
                    start: .init(startX, startY, 0, startRadius),
                    end: .init(endX, endY, 0, endRadius),
                    rangeOfT: .init(0, 0, Float(start.depth), Float(end.depth)),
                    startTangent: .init(deltaX, deltaY, 0, inverse),
                    endTangent: .init(deltaX, deltaY, 0, inverse),
                    extremity: .init(first ? 1 : 0, last ? 1 : 0, 0, 0)))
                geometry.append((startX, startY, endX, endY, radius))
                let deltaZ = Float(end.depth - start.depth)
                lengths.append(lengths.last! + max(sqrt(squared + deltaZ * deltaZ), 1))
                lowX = min(lowX, startX - radius, endX - radius)
                lowY = min(lowY, startY - radius, endY - radius)
                highX = max(highX, startX + radius, endX + radius)
                highY = max(highY, startY + radius, endY + radius)
                lowZ = min(lowZ, Float(start.depth), Float(end.depth))
                highZ = max(highZ, Float(start.depth), Float(end.depth))
            }
            for stroke in layout.strokes {
                let firstIndex = geometry.count
                if stroke.count == 1, let point = stroke.first {
                    add(point, point, first: true, last: true)
                }
                for (start, end) in zip(stroke, stroke.dropFirst()) {
                    add(start, end, first: geometry.count == firstIndex, last: false)
                }
                if geometry.count > firstIndex { segmentValues[segmentValues.count - 1].extremity.y = 1 }
            }
            segmentCount = segmentValues.count
            guard segmentCount > 0 else {
                report("No drawable strokes were produced for this text.")
                return
            }
            guard segmentCount <= Int32.max,
                  [lowX, lowY, highX, highY, lowZ, highZ, unitsPerPixel, xOffset, yOffset].allSatisfy(\.isFinite),
                  lengths.last?.isFinite == true else {
                report("The stroke geometry is too large or contains invalid numbers.")
                return
            }
            let total = max(lengths.last!, 1)
            for index in 0..<segmentCount {
                segmentValues[index].rangeOfT.x = lengths[index] / total
                segmentValues[index].rangeOfT.y = lengths[index + 1] / total
            }
            segments = segmentValues.withUnsafeBytes { device.makeBuffer(bytes: $0.baseAddress!, length: $0.count) }
            guard segments != nil else {
                report("Metal could not allocate the stroke buffer.")
                return
            }

            let cellSize: Float = 64
            let originX = floor((lowX - cellSize) / cellSize) * cellSize
            let originY = floor((lowY - cellSize) / cellSize) * cellSize
            let columnCount = ceil((highX - originX) / cellSize) + 1
            let rowCount = ceil((highY - originY) / cellSize) + 1
            guard columnCount.isFinite, rowCount.isFinite,
                  columnCount > 0, rowCount > 0,
                  columnCount <= 1_000_000, rowCount <= 1_000_000,
                  columnCount * rowCount <= 1_000_000 else {
                report("The stroke grid is too large to draw.")
                return
            }
            let columns = Int(columnCount)
            let rows = Int(rowCount)
            var cells = [Set<Int32>](repeating: [], count: columns * rows)
            for (index, segment) in geometry.enumerated() {
                let (startX, startY, endX, endY, rawRadius) = segment
                let radius = rawRadius * 1.25
                let firstColumn = max(0, Int(floor((min(startX, endX) - radius - originX) / cellSize)))
                let lastColumn = min(columns - 1, Int(floor((max(startX, endX) + radius - originX) / cellSize)))
                let firstRow = max(0, Int(floor((min(startY, endY) - radius - originY) / cellSize)))
                let lastRow = min(rows - 1, Int(floor((max(startY, endY) + radius - originY) / cellSize)))
                for row in firstRow...lastRow {
                    for column in firstColumn...lastColumn {
                        let left = originX + Float(column) * cellSize
                        let top = originY + Float(row) * cellSize
                        let overlaps = (0...8).contains { step in
                            let fraction = Float(step) / 8
                            let pointX = startX + (endX - startX) * fraction
                            let pointY = startY + (endY - startY) * fraction
                            let distanceX = max(left - pointX, 0, pointX - left - cellSize)
                            let distanceY = max(top - pointY, 0, pointY - top - cellSize)
                            return distanceX * distanceX + distanceY * distanceY <= radius * radius
                        }
                        if overlaps { cells[row * columns + column].insert(Int32(index)) }
                    }
                }
            }
            var neighbors = [Set<Int32>](repeating: [], count: cells.count)
            for row in 0..<rows {
                for column in 0..<columns {
                    let index = row * columns + column
                    for rowOffset in -1...1 {
                        for columnOffset in -1...1 {
                            let neighborRow = row + rowOffset
                            let neighborColumn = column + columnOffset
                            if neighborRow >= 0 && neighborRow < rows &&
                               neighborColumn >= 0 && neighborColumn < columns {
                                neighbors[index].formUnion(cells[neighborRow * columns + neighborColumn])
                            }
                        }
                    }
                    neighbors[index].subtract(cells[index])
                }
            }
            func packed(_ sets: [Set<Int32>]) -> MTLBuffer? {
                var indices = [Int32(columns), Int32(rows)] + [Int32](repeating: 0, count: sets.count)
                for (index, cell) in sets.enumerated() {
                    guard indices.count + cell.count + 1 <= Int32.max else { return nil }
                    indices[index + 2] = Int32(indices.count)
                    indices.append(Int32(cell.count))
                    indices.append(contentsOf: cell.sorted())
                }
                return indices.withUnsafeBytes { device.makeBuffer(bytes: $0.baseAddress!, length: $0.count) }
            }
            grid = packed(cells)
            neighbor = packed(neighbors)
            guard grid != nil else {
                report("Metal could not prepare the stroke grid.")
                return
            }
            if mode == .glass && neighbor == nil {
                fallbackReason = "Metal could not prepare the shader grid. Showing Depth."
            }
            uniforms = ToothpasteShaderUniforms()
            uniforms.drawableSize = .init(width, height, 1 / width, 1 / height)
            uniforms.textRect = layout.lineCount == 1
                ? .init(width * 0.05, height * 0.706, width * 0.9, -height * 0.35)
                : .init(width * 0.05, height * (0.5 + verticalFill / 2), width * 0.9, -height * verticalFill)
            uniforms.animation = .init(0, 0, lowZ, highZ)
            uniforms.transform = .init(unitsPerPixel, unitsPerPixel, xOffset, yOffset)
            uniforms.alignedGridBounds = .init(originX, originY, originX + Float(columns + 2) * cellSize,
                                               originY + Float(rows + 2) * cellSize)
            uniforms.pointGridBounds = .init(lowX, lowY, highX, highY)
            uniforms.pointGridZBounds = .init(lowZ - 64, highZ + 64, 0, 0)
            uniforms.keyLight = .init(0.59598225, -0.710264, 0.3746066, 1)
            uniforms.gridSize = .init(cellSize, 1 / cellSize, 1, 1)
            uniforms.pathLengthUnit = .init(1 / total, 0, 1, 1)
            uniforms.zoomScale = .init(1.5, 0, 1, 1)
            if let backgroundData {
                do {
                    background = try MTKTextureLoader(device: device).newTexture(data: backgroundData, options: nil)
                } catch {
                    report("Background image failed: \(error.localizedDescription)")
                }
            } else if setup.glassPipeline != nil {
                makeBackground()
            }
        }

        private func makeBackground() {
            guard let device = setup?.device else { return }
            let textureSize = 256
            let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm,
                                                                         width: textureSize, height: textureSize,
                                                                         mipmapped: false)
            descriptor.usage = [.shaderRead]
            guard let texture = device.makeTexture(descriptor: descriptor) else {
                fallbackReason = "Metal could not make the shader background. Showing Depth."
                return
            }
            var pixels = [UInt8](repeating: 0, count: textureSize * textureSize * 4)
            for row in 0..<textureSize { for column in 0..<textureSize {
                let offset = (row * textureSize + column) * 4
                pixels[offset] = UInt8(65 + 20 * column / textureSize)
                pixels[offset + 1] = UInt8(36 + 18 * row / textureSize)
                pixels[offset + 2] = UInt8(32 + 18 * column / textureSize)
                pixels[offset + 3] = 255
            }}
            pixels.withUnsafeBytes {
                texture.replace(region: MTLRegionMake2D(0, 0, textureSize, textureSize), mipmapLevel: 0,
                                withBytes: $0.baseAddress!, bytesPerRow: textureSize * 4)
            }
            background = texture
        }
    }
}
