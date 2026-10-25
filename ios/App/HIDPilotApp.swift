import SwiftUI

@main
struct HIDPilotApp: App {
    @StateObject private var model = PilotViewModel()
    var body: some Scene {
        WindowGroup {
            HomeView()
                .modifier(PilotAppearanceStyle())
                .environmentObject(model)
                .tint(PilotPalette.accent)
        }
    }
}

/// Presentations own their color-scheme preference, so open sheets update with the app theme.
struct PilotAppearanceStyle: ViewModifier {
    @EnvironmentObject private var model: PilotViewModel

    func body(content: Content) -> some View {
        content.preferredColorScheme(model.colorScheme)
    }
}
