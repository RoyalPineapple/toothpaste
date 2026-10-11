import CoreText
import Foundation
import Metal

struct ToothpasteCubic {
    var p0: ToothpastePoint
    var p1: ToothpastePoint
    var p2: ToothpastePoint
    var p3: ToothpastePoint

    func point(at progress: CGFloat) -> ToothpastePoint {
        let first = p0.interpolated(to: p1, at: progress)
        let middle = p1.interpolated(to: p2, at: progress)
        let last = p2.interpolated(to: p3, at: progress)
        return first.interpolated(to: middle, at: progress)
            .interpolated(to: middle.interpolated(to: last, at: progress), at: progress)
    }
}

struct ToothpastePoint {
    let position: CGPoint
    let depth: CGFloat
    let width: CGFloat

    func interpolated(to other: ToothpastePoint, at fraction: CGFloat) -> ToothpastePoint {
        ToothpastePoint(position: CGPoint(x: position.x + (other.position.x - position.x) * fraction,
                                   y: position.y + (other.position.y - position.y) * fraction),
                 depth: depth + (other.depth - depth) * fraction,
                 width: width + (other.width - width) * fraction)
    }
}

struct ToothpasteLayout {
    let strokes: [[ToothpastePoint]]
    let bounds: CGRect
    let totalLength: CGFloat
    let duration: Double
    let lineCount: Int

    static let leadIn = 0.05
    static let pause = 0.3
}

enum Toothpaste {
    static let systemFontURL = URL(fileURLWithPath: "/System/Library/PrivateFrameworks/SetupAssistantSupportUI.framework/Resources/MacintoshSkeletal.otf")

    struct Font {
        private let resources: Resources

        init(url: URL) throws {
            resources = try Resources(url: url)
        }

        func layout(_ text: String) throws -> ToothpasteLayout {
            guard text.count <= 1_000 else { throw ToothpasteError.textTooLong }
            let lines = text.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline)
            let drawable = lines.enumerated().filter {
                !$0.element.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            }
            guard let first = drawable.first, let last = drawable.last else { throw ToothpasteError.emptyText }
            if drawable.count == 1 { return try Toothpaste.layout(String(first.element), resources: resources) }

            let lineHeight = CTFontGetAscent(resources.font) + CTFontGetDescent(resources.font)
                + CTFontGetLeading(resources.font)
            var strokes: [[ToothpastePoint]] = []
            var bounds = CGRect.null
            var totalLength = CGFloat.zero
            for (index, line) in drawable {
                let layout = try Toothpaste.layout(String(line), resources: resources)
                let offset = CGFloat(index - first.offset) * lineHeight
                strokes += layout.strokes.map { stroke in
                    stroke.map { point in
                        ToothpastePoint(position: CGPoint(x: point.position.x, y: point.position.y + offset),
                                 depth: point.depth, width: point.width)
                    }
                }
                bounds = bounds.union(layout.bounds.offsetBy(dx: 0, dy: offset))
                totalLength += layout.totalLength
            }
            return ToothpasteLayout(strokes: strokes, bounds: bounds, totalLength: totalLength,
                             duration: min(14, max(0.8, Double(totalLength) / 2200)),
                             lineCount: last.offset - first.offset + 1)
        }
    }

    static func systemShaderURL(beside fontURL: URL) -> URL? {
        let candidates = [fontURL, systemFontURL].map {
            $0.deletingLastPathComponent().appendingPathComponent("default.metallib")
        }
        return candidates.first { loadShader(at: $0) }
    }

    static func loadShader(at url: URL) -> Bool {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        guard FileManager.default.isReadableFile(atPath: url.path),
              let device = MTLCreateSystemDefaultDevice(),
              let library = try? device.makeLibrary(URL: url) else { return false }
        let constants = MTLFunctionConstantValues()
        var antialias = false
        constants.setConstantValue(&antialias, type: .bool, withName: "renderAntialiased")
        guard let vertex = library.makeFunction(name: "textVertex"),
              let fragment = try? library.makeFunction(name: "textFragment", constantValues: constants) else {
            return false
        }
        let descriptor = MTLRenderPipelineDescriptor()
        descriptor.vertexFunction = vertex
        descriptor.fragmentFunction = fragment
        descriptor.colorAttachments[0].pixelFormat = .bgra8Unorm
        var reflection: MTLRenderPipelineReflection?
        guard (try? device.makeRenderPipelineState(descriptor: descriptor,
                                                   options: [.bindingInfo, .bufferTypeInfo],
                                                   reflection: &reflection)) != nil,
              let bindings = reflection?.fragmentBindings,
              let uniforms = bindings.first(where: { $0.name == "uniforms" }) as? MTLBufferBinding,
              let segments = bindings.first(where: { $0.name == "segments" }) as? MTLBufferBinding else {
            return false
        }
        // The installed shader must match the buffers supplied by MetalToothpasteView.
        return uniforms.bufferDataSize == 192 && segments.bufferDataSize == 96 &&
            segments.bufferStructType?.members.map(\.offset) == [0, 16, 32, 48, 64, 80]
    }

    // MARK: Font data

    private struct RawStroke {
        var points: [ToothpastePoint]
        let type: String
        let word: Int
        let deferred: Bool
        var startSnap: Int?
        var endSnap: Int?
        let startTangency: CGFloat
        let endTangency: CGFloat
        let endInjector: Bool
        let injectorTargetsPrecedingExit: Bool
        let startOncurve: Bool
        let endOncurve: Bool
    }

    private struct StrokeData: Decodable {
        let type: String
        let points: [[Double]]
        let info: StrokeInfo?
    }

    private struct StrokeInfo: Decodable {
        let deferred: String?
        let start: EndpointInfo?
        let end: EndpointInfo?
    }

    private struct EndpointInfo: Decodable {
        let snappingTarget: Int?
        let tangency: Double?
        let injector: Bool?
        let oncurve: Bool?
    }

    private struct GlyphData: Decodable {
        let info: GlyphInfo
        let strokes: [StrokeData]
    }

    private struct GlyphInfo: Decodable {
        let deferJoining: Bool
        let joinsForward: Int?
        let joinsBackward: Int?
    }

    private struct FontData: Decodable {
        let glyphOrder: [String]
        let glyphs: [String: GlyphData]
    }

    private struct Resources {
        let font: CTFont
        let coverage: CharacterSet
        let data: FontData

        init(url: URL) throws {
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            guard FileManager.default.isReadableFile(atPath: url.path),
                  let provider = CGDataProvider(url: url as CFURL),
                  let cgFont = CGFont(provider) else { throw ToothpasteError.missingFont(url.path) }
            font = CTFontCreateWithGraphicsFont(cgFont, 1000, nil, nil)
            coverage = CTFontCopyCharacterSet(font) as CharacterSet
            let bytes = try Data(contentsOf: url)
            guard let table = Self.strokeTable(in: bytes) else { throw ToothpasteError.invalidFont }
            do { data = try JSONDecoder().decode(FontData.self, from: table) }
            catch { throw ToothpasteError.unreadableStrokeData(error.localizedDescription) }
        }

        private static func strokeTable(in bytes: Data) -> Data? {
            func number(_ offset: Int, _ count: Int) -> Int? {
                guard offset >= 0, offset + count <= bytes.count else { return nil }
                return (0..<count).reduce(0) { ($0 << 8) | Int(bytes[offset + $1]) }
            }
            guard let count = number(4, 2) else { return nil }
            for index in 0..<count {
                let record = 12 + 16 * index
                guard record + 16 <= bytes.count else { return nil }
                if String(data: bytes[record..<(record + 4)], encoding: .ascii) == "strk",
                   let offset = number(record + 8, 4),
                   let length = number(record + 12, 4),
                   offset <= bytes.count, length <= bytes.count - offset {
                    return bytes.subdata(in: offset..<(offset + length))
                }
            }
            return nil
        }
    }

    private enum ToothpasteError: LocalizedError {
        case missingFont(String), invalidFont, unreadableStrokeData(String), unsupportedText, emptyText, textTooLong

        var errorDescription: String? {
            switch self {
            case .missingFont(let path): "No readable stroke font at \(path)."
            case .invalidFont: "This font has no readable stroke data."
            case .unreadableStrokeData(let reason): "The font's stroke data could not be read: \(reason)"
            case .unsupportedText: "Some characters are not covered by the stroke font."
            case .emptyText: "Enter some text to draw."
            case .textTooLong: "Enter 1,000 characters or fewer."
            }
        }
    }

    // MARK: Layout

    private static func layout(_ text: String, resources: Resources) throws -> ToothpasteLayout {
        let (raw, joins) = try positionedStrokes(text, resources: resources)
        var (curves, sampled, curveOfSample) = fittedStrokes(raw)
        applyLocalAttachments(raw, curves: &curves, sampled: &sampled, curveOfSample: &curveOfSample)
        let joined = join(curves, sampled: sampled, curveOfSample: curveOfSample,
                          raw: raw, joins: joins)
        return try finishLayout(joined, raw: raw, sampled: sampled)
    }

    private static func positionedStrokes(_ text: String, resources: Resources) throws
        -> (raw: [RawStroke], joins: [Int: Int]) {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw ToothpasteError.emptyText
        }
        let supportedText = text.unicodeScalars.map { scalar -> String in
            if resources.coverage.contains(scalar) { return String(scalar) }
            let decomposed = String(scalar).decomposedStringWithCanonicalMapping
            return decomposed.unicodeScalars.allSatisfy(resources.coverage.contains) ? decomposed : String(scalar)
        }.joined()
        let attributed = NSAttributedString(string: supportedText,
                                            attributes: [NSAttributedString.Key(kCTFontAttributeName as String): resources.font])
        let line = CTLineCreateWithAttributedString(attributed)
        // shortcut: Whitespace releases "Next Break" strokes; the font does not specify a release event.
        var breakOffsets: [Int] = []
        var offset = 0
        for scalar in supportedText.unicodeScalars {
            offset += scalar.utf16.count
            if CharacterSet.whitespacesAndNewlines.contains(scalar) { breakOffsets.append(offset) }
        }
        var raw: [RawStroke] = []
        var joins: [Int: Int] = [:]
        var outgoing: Int?
        var xCorrection: CGFloat = 0

        for run in CTLineGetGlyphRuns(line) as! [CTRun] {
            outgoing = nil
            let attributes = CTRunGetAttributes(run) as NSDictionary
            let usedFont = attributes[kCTFontAttributeName] as! CTFont
            guard CTFontCopyPostScriptName(usedFont) == CTFontCopyPostScriptName(resources.font) else {
                throw ToothpasteError.unsupportedText
            }
            let count = CTRunGetGlyphCount(run)
            var glyphs = [CGGlyph](repeating: 0, count: count)
            var positions = [CGPoint](repeating: .zero, count: count)
            var stringIndices = [CFIndex](repeating: 0, count: count)
            CTRunGetGlyphs(run, CFRange(location: 0, length: 0), &glyphs)
            CTRunGetPositions(run, CFRange(location: 0, length: 0), &positions)
            CTRunGetStringIndices(run, CFRange(location: 0, length: 0), &stringIndices)

            for index in 0..<count {
                let id = Int(glyphs[index])
                guard id < resources.data.glyphOrder.count,
                      let shapedGlyph = resources.data.glyphs[resources.data.glyphOrder[id]] else {
                    throw ToothpasteError.unsupportedText
                }
                let name = resources.data.glyphOrder[id]
                var glyph = shapedGlyph
                var advanceChange: CGFloat = 0
                // shortcut: Choose an authored connected form whenever the next glyph has an incoming join.
                if shapedGlyph.info.joinsForward != nil,
                   index + 1 < count,
                   Int(glyphs[index + 1]) < resources.data.glyphOrder.count,
                   let next = resources.data.glyphs[resources.data.glyphOrder[Int(glyphs[index + 1])]],
                   next.info.joinsBackward != nil {
                    var connectedNames = [name + ".connected"]
                    if let suffix = name.lastIndex(of: ".") {
                        connectedNames.append(String(name[..<suffix]) + ".connected" + name[suffix...])
                    }
                    if let connectedName = connectedNames.first(where: { resources.data.glyphs[$0] != nil }),
                       let connected = resources.data.glyphs[connectedName] {
                        let connectedID = CTFontGetGlyphWithName(resources.font, connectedName as CFString)
                        if connectedID != 0 {
                            var base = glyphs[index], replacement = connectedID
                            var baseAdvance = CGSize.zero, replacementAdvance = CGSize.zero
                            CTFontGetAdvancesForGlyphs(resources.font, .horizontal, &base, &baseAdvance, 1)
                            CTFontGetAdvancesForGlyphs(resources.font, .horizontal,
                                                       &replacement, &replacementAdvance, 1)
                            advanceChange = replacementAdvance.width - baseAdvance.width
                            glyph = connected
                        }
                    }
                }
                let firstStroke = raw.count
                let word = breakOffsets.prefix { $0 <= stringIndices[index] }.count
                var drawableIndices: [Int: Int] = [:]
                var strokeOrder = glyph.strokes.indices.filter { glyph.strokes[$0].type != "Final Attachment Anchor" }
                for source in glyph.strokes.indices {
                    guard glyph.strokes[source].info?.end?.injector == true,
                          let target = glyph.strokes[source].info?.end?.snappingTarget,
                          let from = strokeOrder.firstIndex(of: source),
                          let to = strokeOrder.firstIndex(of: target), from > to else { continue }
                    strokeOrder.remove(at: from)
                    strokeOrder.insert(source, at: to)
                }
                for strokeIndex in strokeOrder {
                    let stroke = glyph.strokes[strokeIndex]
                    let points = try stroke.points.map { point -> ToothpastePoint in
                        guard point.count == 4,
                              point.allSatisfy({ $0.isFinite && abs($0) <= 16 }) else {
                            throw ToothpasteError.unreadableStrokeData("A stroke contains an invalid point.")
                        }
                        return ToothpastePoint(position: CGPoint(x: positions[index].x + xCorrection + point[0] * 1000,
                                                           y: -positions[index].y - point[1] * 1000),
                                        depth: point[2] * 1000,
                                        width: point[3] * 1000)
                    }
                    guard !points.isEmpty else { continue }
                    drawableIndices[strokeIndex] = raw.count
                    raw.append(RawStroke(points: points, type: stroke.type,
                                         word: word, deferred: stroke.info?.deferred == "Next Break",
                                         startSnap: stroke.info?.start?.snappingTarget,
                                         endSnap: stroke.info?.end?.snappingTarget,
                                         startTangency: stroke.info?.start?.tangency ?? 0,
                                         endTangency: stroke.info?.end?.tangency ?? 0,
                                         endInjector: stroke.info?.end?.injector ?? false,
                                         injectorTargetsPrecedingExit: stroke.info?.end?.snappingTarget.map {
                                             glyph.info.joinsForward == $0 + 1
                                         } ?? false,
                                         startOncurve: stroke.info?.start?.oncurve ?? false,
                                         endOncurve: stroke.info?.end?.oncurve ?? false))
                }
                for rawIndex in firstStroke..<raw.count {
                    raw[rawIndex].startSnap = raw[rawIndex].startSnap.flatMap { drawableIndices[$0] }
                    raw[rawIndex].endSnap = raw[rawIndex].endSnap.flatMap { drawableIndices[$0] }
                }
                let incoming = glyph.info.joinsBackward.flatMap { drawableIndices[$0] }
                if let outgoing, let incoming,
                   raw[outgoing].type == "Open", raw[incoming].type == "Open" {
                    joins[outgoing] = incoming
                }
                if !glyph.info.deferJoining {
                    outgoing = glyph.info.joinsForward.flatMap { drawableIndices[$0] }
                }
                xCorrection += advanceChange
            }
        }
        return (raw, joins)
    }

    private static func fittedStrokes(_ raw: [RawStroke])
        -> (curves: [[ToothpasteCubic]], sampled: [[ToothpastePoint]], curveOfSample: [[Int]]) {
        var curves: [[ToothpasteCubic]] = []
        var curveOfSample: [[Int]] = []
        let sampled = raw.map { stroke in
            var cubics: [ToothpasteCubic] = []
            var indices: [Int] = []
            let samples = sample(stroke.points, closed: stroke.type == "Closed",
                                 startOncurve: stroke.startOncurve, endOncurve: stroke.endOncurve,
                                 cubics: &cubics, curveOfSample: &indices)
            curves.append(cubics)
            curveOfSample.append(indices)
            return samples
        }
        return (curves, sampled, curveOfSample)
    }

    // MARK: Attachments

    private static func applyLocalAttachments(_ raw: [RawStroke], curves: inout [[ToothpasteCubic]],
                                              sampled: inout [[ToothpastePoint]],
                                              curveOfSample: inout [[Int]]) {
        var injectors: [(source: Int, target: Int, curve: Int, fraction: CGFloat)] = []
        var snapOrder: [Int] = []
        var seen = Set<Int>()
        // shortcut: A snap cycle keeps the first stroke visited.
        func visit(_ index: Int) {
            guard seen.insert(index).inserted else { return }
            if let target = raw[index].startSnap { visit(target) }
            if let target = raw[index].endSnap { visit(target) }
            snapOrder.append(index)
        }
        for index in raw.indices { visit(index) }
        for index in snapOrder {
            var points = raw[index].points
            if let target = raw[index].startSnap, points.count > 1 {
                let (contact, tangent, _, _) = snapped(points[0], to: curves[target])
                applySnap(to: &points, authored: raw[index].points, atStart: true,
                          contact: contact, tangent: tangent, strength: raw[index].startTangency,
                          oppositeOncurve: raw[index].endOncurve || raw[index].endSnap != nil)
            }
            if let target = raw[index].endSnap, points.count > 1 {
                let injecting = raw[index].endInjector && target > index && !curves[target].isEmpty
                let (contact, tangent, curve, fraction) = snapped(raw[index].points.last!, to: curves[target])
                applySnap(to: &points, authored: raw[index].points, atStart: false,
                          contact: contact, tangent: tangent, strength: raw[index].endTangency,
                          oppositeOncurve: raw[index].startOncurve || raw[index].startSnap != nil)
                if injecting { injectors.append((index, target, curve, fraction)) }
            }
            if raw[index].startSnap != nil || raw[index].endSnap != nil {
                curves[index].removeAll()
                curveOfSample[index].removeAll()
                sampled[index] = sample(points, closed: raw[index].type == "Closed",
                                        startOncurve: raw[index].startOncurve || raw[index].startSnap != nil,
                                        endOncurve: raw[index].endOncurve || raw[index].endSnap != nil,
                                        cubics: &curves[index], curveOfSample: &curveOfSample[index])
            }
        }
        let snappedCurves = curves
        for operation in injectors {
            let target = snappedCurves[operation.target]
            var prefix = Array(target[..<operation.curve])
            if operation.fraction > 0 {
                let cubic = target[operation.curve]
                let first = cubic.p0.interpolated(to: cubic.p1, at: operation.fraction)
                let middle = cubic.p1.interpolated(to: cubic.p2, at: operation.fraction)
                let last = cubic.p2.interpolated(to: cubic.p3, at: operation.fraction)
                let firstMidpoint = first.interpolated(to: middle, at: operation.fraction)
                let lastMidpoint = middle.interpolated(to: last, at: operation.fraction)
                prefix.append(ToothpasteCubic(p0: cubic.p0, p1: first, p2: firstMidpoint,
                                       p3: firstMidpoint.interpolated(to: lastMidpoint, at: operation.fraction)))
            }
            func narrowed(_ point: ToothpastePoint) -> ToothpastePoint {
                ToothpastePoint(position: point.position, depth: point.depth, width: point.width * 0.99)
            }
            curves[operation.source] += prefix.reversed().map {
                ToothpasteCubic(p0: narrowed($0.p3), p1: narrowed($0.p2),
                         p2: narrowed($0.p1), p3: narrowed($0.p0))
            }
        }
        for operation in injectors {
            let index = operation.source
            guard !curves[index].isEmpty else { continue }
            var rebuilt = [curves[index][0].p0]
            var indices = [0]
            for (curveIndex, cubic) in curves[index].enumerated() {
                let distance = hypot(cubic.p3.position.x - cubic.p0.position.x,
                                     cubic.p3.position.y - cubic.p0.position.y)
                let steps = max(4, Int(ceil(distance / 8)))
                for step in 1...steps {
                    rebuilt.append(cubic.point(at: CGFloat(step) / CGFloat(steps)))
                    indices.append(curveIndex)
                }
            }
            assert(rebuilt.count == indices.count &&
                   rebuilt.last!.position == curves[index].last!.p3.position)
            sampled[index] = rebuilt
            curveOfSample[index] = indices
        }
    }

    private static func finishLayout(_ joinedCurves: [(Int, [ToothpasteCubic])], raw: [RawStroke],
                                     sampled: [[ToothpastePoint]]) throws -> ToothpasteLayout {
        var orderedCurves: [(Int, [ToothpasteCubic])] = []
        var deferredCurves: [(Int, [ToothpasteCubic])] = []
        var currentWord: Int?
        for item in joinedCurves {
            let word = raw[item.0].word
            if currentWord != nil && word != currentWord {
                orderedCurves += deferredCurves
                deferredCurves.removeAll()
            }
            if raw[item.0].deferred { deferredCurves.append(item) }
            else { orderedCurves.append(item) }
            currentWord = word
        }
        orderedCurves += deferredCurves
        var strokes: [[ToothpastePoint]] = []
        var totalLength = CGFloat.zero
        var bounds = CGRect.null
        for (origin, cubics) in orderedCurves {
            let samples = cubics.isEmpty ? sampled[origin] : cubics.flatMap { cubic -> [ToothpastePoint] in
                let distance = hypot(cubic.p3.position.x - cubic.p0.position.x,
                                     cubic.p3.position.y - cubic.p0.position.y)
                let steps = max(4, Int(ceil(distance / 8)))
                return (0..<steps).map { step in
                    cubic.point(at: CGFloat(step) / CGFloat(steps))
                }
            } + [cubics.last!.p3]
            let length = max(1, zip(samples, samples.dropFirst()).reduce(CGFloat.zero) {
                $0 + hypot(hypot($1.0.position.x - $1.1.position.x,
                                  $1.0.position.y - $1.1.position.y), $1.0.depth - $1.1.depth)
            })
            strokes.append(samples)
            totalLength += length
            for point in samples {
                let radius = point.width
                bounds = bounds.union(CGRect(x: point.position.x - radius,
                                             y: point.position.y - radius,
                                             width: radius * 2, height: radius * 2))
            }
        }
        guard !strokes.isEmpty, !bounds.isNull else { throw ToothpasteError.unsupportedText }
        return ToothpasteLayout(strokes: strokes, bounds: bounds, totalLength: totalLength,
                         duration: min(3, max(0.8, Double(totalLength) / 2200)), lineCount: 1)
    }

    // MARK: Letter joins

    private static func join(_ curves: [[ToothpasteCubic]], sampled: [[ToothpastePoint]],
                             curveOfSample: [[Int]], raw: [RawStroke],
                             joins: [Int: Int]) -> [(Int, [ToothpasteCubic])] {
        var keptStart = [Int](repeating: 0, count: curves.count)
        var keptEnd = curves.map(\.count)
        var predecessors: [Int: Int] = [:]
        var successors: [Int: Int] = [:]
        var fittedBridges: [Int: [ToothpastePoint]] = [:]
        for (outgoingIndex, incomingIndex) in joins {
            let outgoingSamples = sampled[outgoingIndex]
            let incomingSamples = sampled[incomingIndex]
            guard !curves[outgoingIndex].isEmpty, !curves[incomingIndex].isEmpty,
                  outgoingSamples.count > 1, incomingSamples.count > 1 else { continue }
            if let points = fittedJoinPoints(outgoing: raw[outgoingIndex], incoming: raw[incomingIndex],
                                             incomingCurves: curves[incomingIndex]) {
                fittedBridges[outgoingIndex] = points
                keptEnd[outgoingIndex] = max(1, curves[outgoingIndex].count - 3)
                keptStart[incomingIndex] = min(3, curves[incomingIndex].count - 1)
                predecessors[incomingIndex] = outgoingIndex
                successors[outgoingIndex] = incomingIndex
                continue
            }
            if let trim = trimAtContact(outgoing: outgoingSamples, incoming: incomingSamples,
                                        outgoingCurveForSample: curveOfSample[outgoingIndex],
                                        incomingCurveForSample: curveOfSample[incomingIndex],
                                        outgoingCurveCount: curves[outgoingIndex].count,
                                        incomingCurveCount: curves[incomingIndex].count) {
                keptEnd[outgoingIndex] = trim.tail
                keptStart[incomingIndex] = trim.head
            }
            predecessors[incomingIndex] = outgoingIndex
            successors[outgoingIndex] = incomingIndex
        }
        for index in curves.indices where keptStart[index] >= keptEnd[index] && !curves[index].isEmpty {
            // Keep the stroke if trimming both of its joins would remove it.
            keptStart[index] = 0
            keptEnd[index] = curves[index].count
        }
        var result: [(Int, [ToothpasteCubic])] = []
        var visited = Set<Int>()
        for root in curves.indices where predecessors[root] == nil {
            var chain: [ToothpasteCubic] = []
            var index = root
            while visited.insert(index).inserted {
                var glyphCurves = Array(curves[index][keptStart[index]..<keptEnd[index]])
                if let previousCurve = chain.last, let nextCurve = glyphCurves.first {
                    if let previousIndex = predecessors[index],
                       let bridgePoints = fittedBridges[previousIndex],
                       keptEnd[previousIndex] == max(1, curves[previousIndex].count - 3),
                       keptStart[index] == min(3, curves[index].count - 1) {
                        var bridge = (0..<(bridgePoints.count - 1)).map { segmentIndex in
                            ToothpasteCubic(p0: bridgePoints[segmentIndex],
                                     p1: bridgePoints[segmentIndex].interpolated(
                                        to: bridgePoints[segmentIndex + 1], at: 0.333),
                                     p2: bridgePoints[segmentIndex].interpolated(
                                        to: bridgePoints[segmentIndex + 1], at: 0.666),
                                     p3: bridgePoints[segmentIndex + 1])
                        }
                        let start = previousCurve.p2.interpolated(to: bridge[0].p1, at: 0.5)
                        chain[chain.count - 1].p3 = start
                        bridge[0].p0 = start
                        for segmentIndex in 0..<(bridge.count - 1) {
                            let seam = bridge[segmentIndex].p2.interpolated(
                                to: bridge[segmentIndex + 1].p1, at: 0.5)
                            bridge[segmentIndex].p3 = seam
                            bridge[segmentIndex + 1].p0 = seam
                        }
                        let lastBridgeIndex = bridge.count - 1
                        let end = bridge[lastBridgeIndex].p2.interpolated(to: nextCurve.p1, at: 0.5)
                        bridge[lastBridgeIndex].p3 = end
                        glyphCurves[0].p0 = end
                        chain += bridge
                    } else {
                        // Continue the font's rounded-third B-spline through both existing end controls.
                        let outgoingControl = previousCurve.p2.interpolated(to: previousCurve.p1, at: -1)
                        let incomingControl = nextCurve.p1.interpolated(to: nextCurve.p2, at: -1)
                        let firstControl = outgoingControl.interpolated(to: incomingControl, at: 0.333)
                        let secondControl = outgoingControl.interpolated(to: incomingControl, at: 0.666)
                        let start = previousCurve.p2.interpolated(to: firstControl, at: 0.5)
                        let end = secondControl.interpolated(to: nextCurve.p1, at: 0.5)
                        chain[chain.count - 1].p3 = start
                        chain.append(ToothpasteCubic(p0: start, p1: firstControl,
                                                    p2: secondControl, p3: end))
                        glyphCurves[0].p0 = end
                    }
                }
                chain += glyphCurves
                guard let next = successors[index] else { break }
                index = next
            }
            result.append((root, chain))
        }
        assert(visited.count == curves.count)
        return result
    }

    private static func trimAtContact(outgoing: [ToothpastePoint], incoming: [ToothpastePoint],
                                      outgoingCurveForSample: [Int], incomingCurveForSample: [Int],
                                      outgoingCurveCount: Int, incomingCurveCount: Int)
        -> (tail: Int, head: Int)? {
        // shortcut: Estimate cross-letter contact from sampled curves; the font supplies no finished bridge.
        var crossing: (removedFraction: CGFloat, outgoingSample: Int, incomingSample: Int)?
        for outgoingIndex in 0..<(outgoing.count - 1) {
            let outgoingStart = outgoing[outgoingIndex].position
            let outgoingEnd = outgoing[outgoingIndex + 1].position
            let outgoingDX = outgoingEnd.x - outgoingStart.x
            let outgoingDY = outgoingEnd.y - outgoingStart.y
            for incomingIndex in 0..<(incoming.count - 1) {
                let incomingStart = incoming[incomingIndex].position
                let incomingEnd = incoming[incomingIndex + 1].position
                let incomingDX = incomingEnd.x - incomingStart.x
                let incomingDY = incomingEnd.y - incomingStart.y
                let denominator = outgoingDX * incomingDY - outgoingDY * incomingDX
                if abs(denominator) < 0.000001 { continue }
                let offsetX = incomingStart.x - outgoingStart.x
                let offsetY = incomingStart.y - outgoingStart.y
                let outgoingFraction = (offsetX * incomingDY - offsetY * incomingDX) / denominator
                let incomingFraction = (offsetX * outgoingDY - offsetY * outgoingDX) / denominator
                if (0...1).contains(outgoingFraction), (0...1).contains(incomingFraction),
                   incomingCurveForSample[incomingIndex + 1] <= 1 {
                    let removedFraction =
                        (CGFloat(outgoing.count - 1 - outgoingIndex) - outgoingFraction) /
                            CGFloat(outgoing.count - 1) +
                        (CGFloat(incomingIndex) + incomingFraction) / CGFloat(incoming.count - 1)
                    if crossing == nil || removedFraction < crossing!.removedFraction {
                        crossing = (removedFraction, outgoingIndex, incomingIndex)
                    }
                }
            }
        }
        if let crossing {
            return (min(max(1, outgoingCurveForSample[crossing.outgoingSample + 1]), outgoingCurveCount),
                    min(incomingCurveForSample[crossing.incomingSample + 1] + 1, incomingCurveCount - 1))
        }

        var distanceFromEnd = [CGFloat](repeating: 0, count: outgoing.count)
        var distanceFromStart = [CGFloat](repeating: 0, count: incoming.count)
        for index in stride(from: outgoing.count - 2, through: 0, by: -1) {
            let deltaX = outgoing[index + 1].position.x - outgoing[index].position.x
            let deltaY = outgoing[index + 1].position.y - outgoing[index].position.y
            let deltaZ = outgoing[index + 1].depth - outgoing[index].depth
            distanceFromEnd[index] = distanceFromEnd[index + 1] +
                sqrt(deltaX * deltaX + deltaY * deltaY + deltaZ * deltaZ)
        }
        for index in 1..<incoming.count {
            let deltaX = incoming[index].position.x - incoming[index - 1].position.x
            let deltaY = incoming[index].position.y - incoming[index - 1].position.y
            let deltaZ = incoming[index].depth - incoming[index - 1].depth
            distanceFromStart[index] = distanceFromStart[index - 1] +
                sqrt(deltaX * deltaX + deltaY * deltaY + deltaZ * deltaZ)
        }
        var bestOverlap = (removedLength: CGFloat.infinity, distance: CGFloat.infinity,
                           outgoingSample: 0, incomingSample: 0)
        var nearest = (distance: CGFloat.infinity, outgoingSample: 0, incomingSample: 0)
        for outgoingIndex in outgoing.indices {
            for incomingIndex in incoming.indices {
                let deltaX = outgoing[outgoingIndex].position.x - incoming[incomingIndex].position.x
                let deltaY = outgoing[outgoingIndex].position.y - incoming[incomingIndex].position.y
                let distance = deltaX * deltaX + deltaY * deltaY
                if distance < nearest.distance,
                   outgoingCurveForSample[outgoingIndex] >= max(0, outgoingCurveCount - 4),
                   incomingCurveForSample[incomingIndex] <= 3 {
                    nearest = (distance, outgoingIndex, incomingIndex)
                }
                let radius = outgoing[outgoingIndex].width + incoming[incomingIndex].width
                if distance <= radius * radius {
                    let removedLength = distanceFromEnd[outgoingIndex] + distanceFromStart[incomingIndex]
                    if removedLength < bestOverlap.removedLength ||
                       (removedLength == bestOverlap.removedLength && distance < bestOverlap.distance) {
                        bestOverlap = (removedLength, distance, outgoingIndex, incomingIndex)
                    }
                }
            }
        }
        let nearestIsOnDifferentCurves =
            abs(outgoingCurveForSample[nearest.outgoingSample] -
                outgoingCurveForSample[bestOverlap.outgoingSample]) > 1 ||
            abs(incomingCurveForSample[nearest.incomingSample] -
                incomingCurveForSample[bestOverlap.incomingSample]) > 1
        let useOverlap = bestOverlap.removedLength.isFinite && nearestIsOnDifferentCurves
        let outgoingSample = min(useOverlap ? bestOverlap.outgoingSample : nearest.outgoingSample,
                                 outgoing.count - 2)
        let incomingSample = min(useOverlap ? bestOverlap.incomingSample : nearest.incomingSample,
                                 incoming.count - 2)
        guard bestOverlap.removedLength.isFinite ||
              incomingCurveForSample[incomingSample + 1] == incomingCurveForSample[0] else { return nil }
        return (min(max(1, outgoingCurveForSample[outgoingSample + 1]), outgoingCurveCount),
                min(incomingCurveForSample[incomingSample + 1] + 1, incomingCurveCount - 1))
    }

    private static func fittedJoinPoints(outgoing: RawStroke, incoming: RawStroke,
                                         incomingCurves: [ToothpasteCubic]) -> [ToothpastePoint]? {
        let sourceCount = outgoing.points.count
        let entryCount = incoming.points.count
        let injectorFromPrecedingStroke = incoming.endInjector &&
            incoming.injectorTargetsPrecedingExit &&
            ((sourceCount > 5 && entryCount == 5) || (sourceCount <= 5 && entryCount == 4))
        let shortTangentialSnap = sourceCount <= 5 && entryCount == 4 &&
            incoming.endTangency > 0 && !incoming.endInjector
        guard sourceCount >= 3, entryCount >= 3,
              outgoing.startSnap == nil, outgoing.endSnap == nil,
              incoming.startSnap == nil,
              (incoming.endSnap == nil || injectorFromPrecedingStroke || shortTangentialSnap),
              var points = minimumJerkJoin(outgoing.points, incoming.points) else { return nil }

        if sourceCount == 5, entryCount == 4, incoming.endSnap == nil,
           incoming.points[1].position.y < outgoing.points[sourceCount - 2].position.y {
            points = [outgoing.points[1], outgoing.points[2],
                      outgoing.points[3], incoming.points[2]]
        }
        if sourceCount <= 5, entryCount == 4, incoming.endInjector {
            points.append(incomingCurves[min(3, incomingCurves.count - 1)].p0)
        }
        return points
    }

    private static func minimumJerkJoin(_ outgoing: [ToothpastePoint], _ incoming: [ToothpastePoint]) -> [ToothpastePoint]? {
        guard outgoing.count >= 3, incoming.count >= 3 else { return nil }
        func vector(_ point: ToothpastePoint) -> SIMD4<Double> {
            SIMD4(
                Double(point.position.x), Double(point.position.y),
                Double(point.depth), Double(point.width))
        }
        func point(_ value: SIMD4<Double>) -> ToothpastePoint {
            ToothpastePoint(position: CGPoint(x: value.x, y: value.y), depth: value.z, width: value.w)
        }
        func dot(_ left: SIMD4<Double>, _ right: SIMD4<Double>) -> Double {
            left.x * right.x + left.y * right.y + left.z * right.z + left.w * right.w
        }
        func length(_ value: SIMD4<Double>) -> Double { sqrt(dot(value, value)) }

        let outgoingStart = max(1, outgoing.count - 4)
        let incomingEnd = min(3, incoming.count - 2)
        let start = vector(outgoing[outgoingStart])
        let end = vector(incoming[incomingEnd])
        let outgoingDirection = vector(outgoing[outgoingStart + 1]) - start
        let incomingDirection = end - vector(incoming[incomingEnd - 1])
        let span = end - start
        let denominator = 192 * (dot(outgoingDirection, outgoingDirection) +
                                 dot(incomingDirection, incomingDirection)) +
                          336 * dot(outgoingDirection, incomingDirection)
        guard denominator > 0 else { return nil }
        // This scale minimizes the integrated squared third derivative of the four-component join.
        let scale = 360 * dot(span, outgoingDirection + incomingDirection) / denominator
        guard scale.isFinite, scale > 0 else { return nil }
        let startVelocity = outgoingDirection * scale
        let endVelocity = incomingDirection * scale
        let remainingSpan = span - startVelocity
        let velocityChange = endVelocity - startVelocity
        let cubicCoefficient = remainingSpan * 10 - velocityChange * 4
        let quarticCoefficient = velocityChange * 7 - remainingSpan * 15
        let quinticCoefficient = remainingSpan * 6 - velocityChange * 3
        func at(_ progress: Double) -> SIMD4<Double> {
            start + startVelocity * progress + cubicCoefficient * (progress * progress * progress) +
                quarticCoefficient * (progress * progress * progress * progress) +
                quinticCoefficient * (progress * progress * progress * progress * progress)
        }
        let center = at(0.5)
        func equalChord(_ lower: Double, _ upper: Double, firstHalf: Bool) -> SIMD4<Double> {
            var lower = lower, upper = upper
            for _ in 0..<40 {
                let midpoint = (lower + upper) / 2
                let value = at(midpoint)
                let difference =
                    firstHalf
                    ? length(value - start) - length(center - value) : length(value - center) - length(end - value)
                if difference < 0 { lower = midpoint } else { upper = midpoint }
            }
            return at((lower + upper) / 2)
        }
        let result = [
            point(start), point(equalChord(0, 0.5, firstHalf: true)), point(center),
            point(equalChord(0.5, 1, firstHalf: false)), point(end),
        ]
        guard
            result.allSatisfy({
                $0.position.x.isFinite && $0.position.y.isFinite && $0.depth.isFinite && $0.width.isFinite
                    && $0.width > 0
            })
        else {
            return nil
        }
        return result
    }

    private static func snapped(_ point: ToothpastePoint, to curves: [ToothpasteCubic]) -> (
        contact: ToothpastePoint, tangent: CGPoint, curveIndex: Int, fraction: CGFloat
    ) {
        var nearestPoint = point
        var tangent = CGPoint.zero
        var targetWidth = point.width
        var selected = (curveIndex: 0, fraction: CGFloat.zero)
        var bestDistance = CGFloat.infinity
        for (curveIndex, curve) in curves.enumerated() {
            for step in 0...50 {
                let fraction = CGFloat(step) / 50
                let contact = curve.point(at: fraction)
                let deltaX = point.position.x - contact.position.x
                let deltaY = point.position.y - contact.position.y
                let distance = deltaX * deltaX + deltaY * deltaY
                if distance < bestDistance {
                    bestDistance = distance
                    nearestPoint = ToothpastePoint(position: contact.position, depth: contact.depth, width: point.width)
                    targetWidth = contact.width
                    selected = (curveIndex, fraction)
                    let remaining = 1 - fraction
                    tangent = CGPoint(
                        x: remaining * remaining * (curve.p1.position.x - curve.p0.position.x) + 2 * remaining
                            * fraction * (curve.p2.position.x - curve.p1.position.x) + fraction * fraction
                            * (curve.p3.position.x - curve.p2.position.x),
                        y: remaining * remaining * (curve.p1.position.y - curve.p0.position.y) + 2 * remaining
                            * fraction * (curve.p2.position.y - curve.p1.position.y) + fraction * fraction
                            * (curve.p3.position.y - curve.p2.position.y))
                }
            }
        }
        let length = hypot(tangent.x, tangent.y)
        if length > 0 {
            let deltaX = point.position.x - nearestPoint.position.x
            let deltaY = point.position.y - nearestPoint.position.y
            let side: CGFloat = tangent.x * deltaY - tangent.y * deltaX >= 0 ? 1 : -1
            let gap = side * (targetWidth - point.width) / length
            nearestPoint = ToothpastePoint(
                position: CGPoint(
                    x: nearestPoint.position.x - tangent.y * gap,
                    y: nearestPoint.position.y + tangent.x * gap),
                depth: nearestPoint.depth, width: nearestPoint.width)
        }
        return (nearestPoint, tangent, selected.curveIndex, selected.fraction)
    }

    private static func applySnap(
        to points: inout [ToothpastePoint], authored: [ToothpastePoint], atStart: Bool,
        contact: ToothpastePoint, tangent: CGPoint, strength: CGFloat,
        oppositeOncurve: Bool
    ) {
        let ordered = atStart ? authored : Array(authored.reversed())
        let first = ordered[0], second = ordered[1]
        let deltaX = second.position.x - first.position.x
        let deltaY = second.position.y - first.position.y
        let deltaZ = second.depth - first.depth
        let deltaWidth = second.width - first.width
        let fullLength = sqrt(deltaX * deltaX + deltaY * deltaY + deltaZ * deltaZ + deltaWidth * deltaWidth)
        let planarLength = hypot(deltaX, deltaY)
        let tangentLength = hypot(tangent.x, tangent.y)
        guard fullLength > 0, planarLength > 0, tangentLength > 0 else {
            points[atStart ? 0 : points.count - 1] = contact
            return
        }

        let sourceUnitX = deltaX / fullLength, sourceUnitY = deltaY / fullLength
        let planarScale = planarLength / fullLength
        var tangentUnitX = tangent.x / tangentLength, tangentUnitY = tangent.y / tangentLength
        if sourceUnitX * tangentUnitX + sourceUnitY * tangentUnitY < 0 {
            tangentUnitX = -tangentUnitX
            tangentUnitY = -tangentUnitY
        }
        let amount = min(max(strength, 0), 1)
        let blendedX = (1 - amount) * deltaX / planarLength + amount * tangentUnitX
        let blendedY = (1 - amount) * deltaY / planarLength + amount * tangentUnitY
        let blendLength = hypot(blendedX, blendedY)
        guard blendLength > 0 else {
            points[atStart ? 0 : points.count - 1] = contact
            return
        }
        let adjustedX = planarScale * blendedX / blendLength
        let adjustedY = planarScale * blendedY / blendLength
        let rotationScaleCos = sourceUnitX * adjustedX + sourceUnitY * adjustedY
        let rotationScaleSin = sourceUnitX * adjustedY - sourceUnitY * adjustedX
        let lastSpan = max(1, ordered.count - (oppositeOncurve ? 2 : 1))
        // shortcut: Taper snapping through the first backward bend; the font gives no taper length.
        let span =
            (1..<(ordered.count - 1)).first {
                deltaX * (ordered[$0 + 1].position.x - ordered[$0].position.x) + deltaY
                    * (ordered[$0 + 1].position.y - ordered[$0].position.y) < 0
            }.map { min($0, lastSpan) } ?? lastSpan
        for pointIndex in ordered.indices {
            let weight = max(0, 1 - CGFloat(max(0, pointIndex - 1)) / CGFloat(span))
            if weight == 0 { continue }
            let source = ordered[pointIndex]
            let relativeX = source.position.x - first.position.x
            let relativeY = source.position.y - first.position.y
            let transformed = ToothpastePoint(
                position: CGPoint(
                    x: contact.position.x + rotationScaleCos * relativeX - rotationScaleSin * relativeY,
                    y: contact.position.y + rotationScaleSin * relativeX + rotationScaleCos * relativeY),
                depth: source.depth + contact.depth - first.depth,
                width: source.width + contact.width - first.width)
            let index = atStart ? pointIndex : authored.count - 1 - pointIndex
            let current = points[index]
            points[index] = ToothpastePoint(
                position: CGPoint(
                    x: current.position.x + weight * (transformed.position.x - source.position.x),
                    y: current.position.y + weight * (transformed.position.y - source.position.y)),
                depth: current.depth + weight * (transformed.depth - source.depth),
                width: current.width + weight * (transformed.width - source.width))
        }
    }

    // MARK: Cubic fitting

    private static func sample(
        _ points: [ToothpastePoint], closed: Bool,
        startOncurve: Bool, endOncurve: Bool,
        cubics: inout [ToothpasteCubic], curveOfSample: inout [Int]
    ) -> [ToothpastePoint] {
        guard points.count > 1 else { return points }
        func extrapolate(
            _ start: ToothpastePoint, _ middle: ToothpastePoint,
                         _ end: ToothpastePoint) -> ToothpastePoint {
            let firstStep = [middle.position.x - start.position.x, middle.position.y - start.position.y,
                             middle.depth - start.depth, middle.width - start.width]
            let secondStep = [end.position.x - middle.position.x, end.position.y - middle.position.y,
                              end.depth - middle.depth, end.width - middle.width]
            let firstLength = sqrt(firstStep.reduce(0) { $0 + $1 * $1 })
            let secondLength = sqrt(secondStep.reduce(0) { $0 + $1 * $1 })
            guard firstLength > 0, secondLength > 0 else { return start }
            let direction = zip(firstStep, secondStep).map {
                2 * $0 / firstLength - $1 / secondLength
            }
            let length = sqrt(direction.reduce(0) { $0 + $1 * $1 })
            guard length > 0 else { return start }
            let offset = direction.map { firstLength * $0 / length }
            return ToothpastePoint(position: CGPoint(x: start.position.x - offset[0],
                                              y: start.position.y - offset[1]),
                            depth: start.depth - offset[2], width: start.width - offset[3])
        }

        let count = closed ? points.count : points.count - 1
        let first = (0..<count).map { index in
            points[index].interpolated(to: points[(index + 1) % points.count], at: 0.333)
        }
        let second = (0..<count).map { index in
            points[index].interpolated(to: points[(index + 1) % points.count], at: 0.666)
        }
        let start: ToothpastePoint
        if closed {
            start = second[count - 1].interpolated(to: first[0], at: 0.5)
        } else if points.count == 2 || startOncurve {
            start = points[0]
        } else {
            let ghost = extrapolate(points[0], points[1], points[2])
            start = ghost.interpolated(to: points[0], at: 0.666)
                .interpolated(to: first[0], at: 0.5)
        }
        var samples = [start]
        curveOfSample = [0]
        for index in 0..<count {
            let end: ToothpastePoint
            if closed {
                end = second[index].interpolated(to: first[(index + 1) % count], at: 0.5)
            } else if index == count - 1 {
                if points.count == 2 || endOncurve {
                    end = points[points.count - 1]
                } else {
                    let last = points.count - 1
                    let ghost = extrapolate(points[last], points[last - 1], points[last - 2])
                    end = second[index].interpolated(
                        to: points[last].interpolated(to: ghost, at: 0.333), at: 0.5)
                }
            } else {
                end = second[index].interpolated(to: first[index + 1], at: 0.5)
            }
            let cubic = ToothpasteCubic(p0: samples.last!, p1: first[index], p2: second[index], p3: end)
            cubics.append(cubic)
            let distance = hypot(end.position.x - cubic.p0.position.x,
                                 end.position.y - cubic.p0.position.y)
            let steps = max(4, Int(ceil(distance / 8)))
            for step in 1...steps {
                samples.append(cubic.point(at: CGFloat(step) / CGFloat(steps)))
                curveOfSample.append(index)
            }
        }
        assert(!closed || (samples[0].position == samples.last!.position &&
                           samples[0].depth == samples.last!.depth &&
                           samples[0].width == samples.last!.width))
        return samples
    }
}
