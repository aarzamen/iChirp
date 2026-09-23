import ChirpFeatures
import SwiftUI

/// DEBUG-only launch arguments for checking the M7 speech-engine screens in the Simulator without tapping
/// (screenshots, QA). Release builds ignore them. Nothing is downloaded.
///
/// - `-ChirpSpeechEngines`: opens Settings → Speech engines (`-ChirpSpeechEngines bottom` scrolls to its end).
/// - `-ChirpBenchmark`: opens Settings → Speech engines → Benchmark; `-ChirpBenchmark run` also starts a run with
///   every engine whose model is on disk, `-ChirpBenchmark bottom` scrolls to the results.
enum SpeechEnginesPreviewLaunch {
    static let speechEnginesArgument = "-ChirpSpeechEngines"
    static let benchmarkArgument = "-ChirpBenchmark"

    enum Screen: String, Identifiable {
        case speechEngines, benchmark
        var id: String { rawValue }
    }
}

extension View {
    /// Applies the DEBUG launch arguments above. A no-op in Release builds.
    func speechEnginesPreviewLaunch(environment: AppEnvironment) -> some View {
        #if DEBUG
        modifier(SpeechEnginesPreviewLaunchModifier(environment: environment))
        #else
        self
        #endif
    }
}

#if DEBUG
private struct SpeechEnginesPreviewLaunchModifier: ViewModifier {
    let environment: AppEnvironment
    @State private var screen: SpeechEnginesPreviewLaunch.Screen?

    func body(content: Content) -> some View {
        content
            .sheet(item: $screen) { screen in
                NavigationStack {
                    switch screen {
                    case .speechEngines: SpeechEnginesScreen()
                    case .benchmark: ASRBenchmarkScreen()
                    }
                }
                .defaultScrollAnchor(Self.startsAtBottom ? .bottom : .top)
                .environment(environment)
            }
            .task { await apply() }
    }

    private static var startsAtBottom: Bool {
        IngestPreviewLaunch.value(after: SpeechEnginesPreviewLaunch.speechEnginesArgument) == "bottom"
            || IngestPreviewLaunch.value(after: SpeechEnginesPreviewLaunch.benchmarkArgument) == "bottom"
    }

    private func apply() async {
        let arguments = ProcessInfo.processInfo.arguments
        if arguments.contains(SpeechEnginesPreviewLaunch.benchmarkArgument) {
            await environment.launch()
            screen = .benchmark
            if IngestPreviewLaunch.value(after: SpeechEnginesPreviewLaunch.benchmarkArgument) == "run" {
                await environment.benchmark.refresh()
                environment.benchmark.run()
            }
        } else if arguments.contains(SpeechEnginesPreviewLaunch.speechEnginesArgument) {
            await environment.launch()
            screen = .speechEngines
        }
    }
}
#endif
