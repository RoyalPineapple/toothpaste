import AppKit
import ImageIO
import SwiftUI
import UniformTypeIdentifiers

struct ContentView: View {
    @State private var text = "hello"
    @State private var layout: ToothpasteLayout?
    @State private var progress = 0.0
    @State private var renderID = 0
    @State private var isAnimating = false
    @State private var isExporting = false
    @State private var error: String?
    @State private var shaderURL: URL?
    @State private var shaderError: String?
    @State private var renderMode: ToothpasteRenderMode = .depth
    @State private var backgroundData = NSDataAsset(name: "DefaultBackground")?.data
    @State private var backgroundID = 0
    @State private var font: Toothpaste.Font?
    @State private var fontError: String?
    @State private var choosingFont = false
    @State private var choosingShader = false
    @State private var choosingBackground = false
    @State private var usingDepthWithoutShader = false

    var body: some View {
        Group {
            if font != nil && (shaderURL != nil || usingDepthWithoutShader) {
                renderer()
            } else if font != nil {
                shaderChooser()
            } else {
                VStack(spacing: 16) {
                    Text("The system stroke font is required")
                        .font(.title2.weight(.semibold))
                    Text(fontError ?? "Looking for the system font…")
                        .foregroundStyle(.secondary)
                    Button("Quit") { NSApplication.shared.terminate(nil) }
                        .buttonStyle(.borderedProminent)
                }
                .padding(24)
                .multilineTextAlignment(.center)
            }
        }
        .frame(minWidth: 760, minHeight: 420)
        .background(Color.black.ignoresSafeArea())
        .preferredColorScheme(.dark)
        .focusedSceneValue(\.toothpasteCommands, ToothpasteCommands(
            canExport: layout != nil && !isAnimating && !isExporting,
            selectBackgroundImage: { choosingBackground = true },
            canClearBackgroundImage: backgroundData != nil,
            clearBackgroundImage: {
                backgroundData = nil
                backgroundID += 1
                error = nil
            },
            image: exportImage,
            video: exportVideo,
            shader: $renderMode,
            toothpasteAvailable: shaderURL != nil))
        .fileImporter(isPresented: $choosingFont, allowedContentTypes: [.font]) { result in
            switch result {
            case .success(let url):
                _ = useFont(at: url)
            case .failure(let failure):
                fontError = failure.localizedDescription
            }
        }
        .fileImporter(isPresented: $choosingShader, allowedContentTypes: [.data]) { result in
            switch result {
            case .success(let url):
                if Toothpaste.loadShader(at: url) {
                    shaderURL = url
                    shaderError = nil
                    renderMode = .glass
                } else {
                    shaderError = "This file is not a compatible Toothpaste shader."
                }
            case .failure(let failure):
                shaderError = failure.localizedDescription
            }
        }
        .fileImporter(isPresented: $choosingBackground, allowedContentTypes: [.image]) { result in
            switch result {
            case .success(let url): useBackgroundImage(at: url)
            case .failure(let failure): error = "Background image failed: \(failure.localizedDescription)"
            }
        }
        .task {
            guard font == nil else { return }
            if !useFont(at: Toothpaste.systemFontURL) { choosingFont = true }
        }
    }

    private func shaderChooser() -> some View {
        VStack(spacing: 16) {
            Text("Toothpaste shader not found")
                .font(.title2.weight(.semibold))
            Text(shaderError ?? "Choose a compatible default.metallib, or continue with Depth.")
                .foregroundStyle(.secondary)
            HStack {
                Button("Choose Shader…") { choosingShader = true }
                Button("Use Depth") { usingDepthWithoutShader = true }
                    .buttonStyle(.borderedProminent)
            }
        }
        .padding(24)
        .multilineTextAlignment(.center)
    }

    private func renderer() -> some View {
        VStack(spacing: 24) {
            AnimatedToothpasteView(layout: layout, progress: progress, shaderURL: shaderURL,
                            mode: renderMode, renderID: renderID, backgroundData: backgroundData,
                            backgroundID: backgroundID, onError: { error = $0 })
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .clipShape(RoundedRectangle(cornerRadius: 20))
                .background {
                    RoundedRectangle(cornerRadius: 20).fill(.white.opacity(0.06))
                }
                .accessibilityLabel("Animated cursive rendering of \(text)")

            if let message = error ?? shaderError {
                Text(message)
                    .font(.footnote)
                    .foregroundStyle(.orange)
            }
            if shaderURL == nil {
                HStack {
                    Text("Using Depth. Toothpaste shader not loaded.")
                        .foregroundStyle(.secondary)
                    Button("Choose Shader…") { choosingShader = true }
                }
                .font(.footnote)
            }

            HStack {
                TextField("Text to draw", text: $text, axis: .vertical)
                    .lineLimit(1...5)
                    .onKeyPress(keys: [.return]) { press in
                        guard !press.modifiers.contains(.option) else { return .ignored }
                        if !isAnimating && !isExporting { draw() }
                        return .handled
                    }
                    .accessibilityLabel("Text to draw")
                    .accessibilityHint("Press Return to draw or Option-Return for a new line")

                Button("Draw", action: draw)
                    .buttonStyle(.borderedProminent)
                    .disabled(isAnimating || isExporting)
            }
        }
        .padding(24)
        .task(id: renderID) {
            guard let layout else { return }
            try? await Task.sleep(nanoseconds: UInt64(ToothpasteLayout.leadIn * 1_000_000_000))
            guard !Task.isCancelled else { return }
            withAnimation(.linear(duration: layout.duration)) { progress = 1 }
            try? await Task.sleep(nanoseconds: UInt64((layout.duration + ToothpasteLayout.pause) * 1_000_000_000))
            if !Task.isCancelled { isAnimating = false }
        }
        .onChange(of: renderMode) { error = nil }
    }

    private func useFont(at url: URL) -> Bool {
        do {
            let loadedFont = try Toothpaste.Font(url: url)
            let layout = try loadedFont.layout(text)
            font = loadedFont
            shaderURL = Toothpaste.systemShaderURL(beside: url)
            renderMode = shaderURL == nil ? .depth : .glass
            usingDepthWithoutShader = false
            shaderError = nil
            fontError = nil
            error = nil
            startDrawing(layout)
            return true
        } catch {
            font = nil
            layout = nil
            isAnimating = false
            fontError = error.localizedDescription
            return false
        }
    }

    private func draw() {
        guard let font else { return }
        do {
            let layout = try font.layout(text)
            error = nil
            startDrawing(layout)
        } catch {
            layout = nil
            self.error = error.localizedDescription
        }
    }

    private func startDrawing(_ layout: ToothpasteLayout) {
        self.layout = layout
        progress = 0
        isAnimating = true
        renderID += 1
    }

    private func useBackgroundImage(at url: URL) {
        do {
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            let maximumFileSize = 32 * 1024 * 1024
            guard let fileSize = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize,
                  fileSize <= maximumFileSize else {
                throw ImageError("Choose a background image of 32 MB or less.")
            }
            guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
                  CGImageSourceGetCount(source) > 0,
                  let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
                  let width = properties[kCGImagePropertyPixelWidth] as? Int,
                  let height = properties[kCGImagePropertyPixelHeight] as? Int else {
                throw ImageError("Choose an image file for the background.")
            }
            let maximumDimension = 4096
            guard max(width, height) <= maximumDimension else {
                throw ImageError("Choose a background image no larger than 4096 pixels on either side.")
            }
            backgroundData = try Data(contentsOf: url)
            backgroundID += 1
            error = nil
        } catch {
            self.error = "Background image failed: \(error.localizedDescription)"
        }
    }

    private struct ImageError: LocalizedError {
        let errorDescription: String?
        init(_ message: String) { errorDescription = message }
    }

    private func exportVideo() {
        guard let layout, !isAnimating, !isExporting else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.mpeg4Movie]
        panel.nameFieldStringValue = "Transparent Toothpaste.mp4"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let shaderURL = shaderURL
        let mode = renderMode
        let backgroundData = backgroundData
        error = nil
        isExporting = true
        Task.detached(priority: .userInitiated) {
            do {
                try ToothpasteExporter.video(layout, shaderURL: shaderURL, mode: mode,
                                              backgroundData: backgroundData, to: url)
                await MainActor.run { isExporting = false }
            } catch {
                await MainActor.run {
                    self.error = "Video export failed: \(error.localizedDescription)"
                    isExporting = false
                }
            }
        }
    }

    private func exportImage() {
        guard let layout, !isAnimating, !isExporting else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.png]
        panel.nameFieldStringValue = "Transparent Toothpaste.png"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let shaderURL = shaderURL
        let mode = renderMode
        let backgroundData = backgroundData
        error = nil
        isExporting = true
        Task.detached(priority: .userInitiated) {
            do {
                try ToothpasteExporter.image(layout, shaderURL: shaderURL, mode: mode,
                                              backgroundData: backgroundData, to: url)
                await MainActor.run { isExporting = false }
            } catch {
                await MainActor.run {
                    self.error = "Image export failed: \(error.localizedDescription)"
                    isExporting = false
                }
            }
        }
    }
}

private struct AnimatedToothpasteView: View, Animatable {
    let layout: ToothpasteLayout?
    var progress: Double
    let shaderURL: URL?
    let mode: ToothpasteRenderMode
    let renderID: Int
    let backgroundData: Data?
    let backgroundID: Int
    let onError: @MainActor @Sendable (String) -> Void

    nonisolated var animatableData: Double {
        get { progress }
        set { progress = newValue }
    }

    var body: some View {
        MetalToothpasteView(layout: layout, progress: progress, shaderURL: shaderURL,
                     mode: mode, renderID: renderID, backgroundData: backgroundData,
                     backgroundID: backgroundID, onError: onError)
            .id(shaderURL)
    }
}
