import ChirpUI
import SwiftUI

@main
struct iChirpApp: App {
    @State private var launchState = AppEnvironment.shared

    var body: some Scene {
        WindowGroup {
            switch launchState {
            case .ready(let environment):
                RootTabView()
                    .environment(environment)
                    .task {
                        await environment.launch()
                        #if DEBUG
                        if NetworkDiagnostics.isRequested(in: ProcessInfo.processInfo.arguments) {
                            await NetworkDiagnostics.runAndWrite()
                        }
                        if SmokeTestRunner.isRequested(in: ProcessInfo.processInfo.arguments) {
                            environment.smoke.start(environment: environment, reason: .launchArgument)
                        }
                        let arguments = ProcessInfo.processInfo.arguments
                        if let model = LLMSmokeRunner.requestedModel(in: arguments) {
                            LLMSmokeRunner.shared.start(
                                environment: environment, requested: model, runID: LLMSmokeRunner.runID(in: arguments))
                        }
                        // `-ChirpBenchmarkDevice …` (scripts/device_benchmark.sh).
                        DeviceBenchmarkLaunch.startIfRequested(environment: environment, arguments: arguments)
                        #endif
                    }
            case .failed(let message):
                LaunchErrorView(message: message)
            }
        }
    }
}
