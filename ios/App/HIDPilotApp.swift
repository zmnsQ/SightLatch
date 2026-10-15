import SwiftUI

@main
struct HIDPilotApp: App {
    @StateObject private var model = PilotViewModel()
    var body: some Scene {
        WindowGroup { HomeView().environmentObject(model).preferredColorScheme(model.colorScheme) }
    }
}
