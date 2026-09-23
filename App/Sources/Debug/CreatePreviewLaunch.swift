import Foundation

/// DEBUG-only launch argument for the plan 022 simulator tour: `-ChirpCreateFile <path>` preselects a synthetic file as
/// Create's File answer (a UI test cannot drive the Files picker). Release builds ignore it.
enum CreatePreviewLaunch {
    static let fileArgument = "-ChirpCreateFile"

    static func file(arguments: [String] = ProcessInfo.processInfo.arguments) -> URL? {
        #if DEBUG
        guard let index = arguments.firstIndex(of: fileArgument), index + 1 < arguments.count else { return nil }
        return URL(fileURLWithPath: arguments[index + 1])
        #else
        return nil
        #endif
    }
}
