import ChirpUI
import SwiftUI

@main
struct iChirpApp: App {
    @State private var launchState = AppEnvironment.make()

    var body: some Scene {
        WindowGroup {
            switch launchState {
            case .ready(let environment):
                RootTabView()
                    .environment(environment)
                    .task {
                        await environment.launch()
                        #if DEBUG
                        if SmokeTestRunner.isRequested(in: ProcessInfo.processInfo.arguments) {
                            environment.smoke.start(environment: environment, reason: .launchArgument)
                        }
                        #endif
                    }
            case .failed(let message):
                LaunchErrorView(message: message)
            }
        }
    }
}
