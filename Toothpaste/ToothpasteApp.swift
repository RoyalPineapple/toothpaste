import SwiftUI

struct ToothpasteCommands {
    let canExport: Bool
    let selectBackgroundImage: () -> Void
    let canClearBackgroundImage: Bool
    let clearBackgroundImage: () -> Void
    let image: () -> Void
    let video: () -> Void
    let shader: Binding<ToothpasteRenderMode>
    let toothpasteAvailable: Bool
}

extension FocusedValues {
    @Entry var toothpasteCommands: ToothpasteCommands?
}

struct ToothpasteMenus: Commands {
    @FocusedValue(\.toothpasteCommands) private var commands: ToothpasteCommands?

    var body: some Commands {
        CommandGroup(after: .newItem) {
            Button("Select Background Image…") { commands?.selectBackgroundImage() }
                .disabled(commands == nil)
            Button("Clear Background Image") { commands?.clearBackgroundImage() }
                .disabled(commands?.canClearBackgroundImage != true)
        }
        CommandMenu("Export") {
            Button("Image…") { commands?.image() }
                .disabled(commands?.canExport != true)
            Button("Video…") { commands?.video() }
                .disabled(commands?.canExport != true)
        }
        CommandMenu("Shader") {
            Picker("Shader", selection: commands?.shader ?? .constant(.depth)) {
                Text("Toothpaste").tag(ToothpasteRenderMode.glass)
                    .disabled(commands?.toothpasteAvailable != true)
                Text("Depth").tag(ToothpasteRenderMode.depth)
            }
            .pickerStyle(.inline)
            .labelsHidden()
            .disabled(commands == nil)
        }
    }
}

@main
struct ToothpasteApp: App {
    var body: some Scene {
        WindowGroup {
            ContentView()
        }
        .commands {
            ToothpasteMenus()
        }
    }
}
