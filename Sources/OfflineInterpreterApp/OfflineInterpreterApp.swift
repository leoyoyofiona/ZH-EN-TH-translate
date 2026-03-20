import SwiftUI
#if canImport(OfflineInterpreterKit)
import OfflineInterpreterKit
#endif

@main
struct OfflineInterpreterApp: App {
    @StateObject private var viewModel: AppViewModel

    init() {
        let arguments = ProcessInfo.processInfo.arguments
        let demoMode = arguments.contains("--demo-snapshot")
        let source = demoMode ? Self.parseLanguageArgument(named: "--demo-source", from: arguments) : nil
        let target = demoMode ? Self.parseLanguageArgument(named: "--demo-target", from: arguments) : nil
        let model = AppViewModel(launchDemoSnapshot: demoMode)
        if demoMode {
            model.loadDemoSnapshot(sourceLanguage: source, targetLanguage: target)
        }
        _viewModel = StateObject(wrappedValue: model)
    }

    var body: some Scene {
        WindowGroup {
            ContentView(viewModel: viewModel)
                .frame(minWidth: 760, minHeight: 340)
        }
    }

    private static func parseLanguageArgument(named flag: String, from arguments: [String]) -> SupportedLanguage? {
        guard let index = arguments.firstIndex(of: flag), arguments.indices.contains(index + 1) else {
            return nil
        }
        return SupportedLanguage(rawValue: arguments[index + 1])
    }
}
