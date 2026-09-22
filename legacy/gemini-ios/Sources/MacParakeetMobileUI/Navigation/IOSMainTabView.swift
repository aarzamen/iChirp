import SwiftUI
import MacParakeetCore

/// Root navigation view for Parakeet on iOS, managing the bottom 5-tab structure.
public struct IOSMainTabView: View {
    public enum Tab: Int, CaseIterable, Identifiable {
        case record = 0
        case library = 1
        case transcribe = 2
        case transforms = 3
        case settings = 4

        public var id: Int { rawValue }

        public var title: String {
            switch self {
            case .record: return "Record"
            case .library: return "Library"
            case .transcribe: return "Transcribe"
            case .transforms: return "AI & Rewrites"
            case .settings: return "Settings"
            }
        }

        public var iconName: String {
            switch self {
            case .record: return "waveform.circle.fill"
            case .library: return "folder.fill"
            case .transcribe: return "arrow.down.doc.fill"
            case .transforms: return "wand.and.stars"
            case .settings: return "gearshape.fill"
            }
        }
    }

    @State private var selectedTab: Tab = .record

    public init() {}

    public var body: some View {
        TabView(selection: $selectedTab) {
            IOSRecordView()
                .tabItem {
                    Label(Tab.record.title, systemImage: Tab.record.iconName)
                }
                .tag(Tab.record)

            IOSLibraryView()
                .tabItem {
                    Label(Tab.library.title, systemImage: Tab.library.iconName)
                }
                .tag(Tab.library)

            IOSTranscribeView()
                .tabItem {
                    Label(Tab.transcribe.title, systemImage: Tab.transcribe.iconName)
                }
                .tag(Tab.transcribe)

            IOSTransformsView()
                .tabItem {
                    Label(Tab.transforms.title, systemImage: Tab.transforms.iconName)
                }
                .tag(Tab.transforms)

            IOSSettingsView()
                .tabItem {
                    Label(Tab.settings.title, systemImage: Tab.settings.iconName)
                }
                .tag(Tab.settings)
        }
        .tint(MobileDesignSystem.Colors.accent)
        .onChange(of: selectedTab) { _, _ in
            MobileDesignSystem.Haptics.light()
        }
    }
}
