import AppKit
import SwiftUI

struct DeckRootView: View {
    @EnvironmentObject var library: Library
    @EnvironmentObject var experience: GameExperience
    @EnvironmentObject var social: SteamSocial
    @StateObject private var controller = DeckControllerInput()
    @StateObject private var big = BigPictureModel()
    private var enabled: Bool { experience.preferences.bigPicture != false }
    var body: some View {
        Group {
            if enabled { BigPictureView(model: big).environmentObject(controller).preferredColorScheme(.dark) }
            else { DockView() }
        }
        .task {
            controller.bigPicture = enabled; controller.swapConfirmBack = experience.preferences.swapControllerConfirmBack == true; controller.start()
            big.onCancelSteam = { library.managedSteam.cancel() }
            await library.startAutomaticServices()
            try? await Task.sleep(nanoseconds: 300_000_000)
            fullScreen(enabled)
        }
        .onChange(of: experience.preferences.swapControllerConfirmBack) { controller.swapConfirmBack = $0 == true }
        .onChange(of: enabled) { value in controller.bigPicture = value; big.cancelLoading(); fullScreen(value) }
        .onReceive(controller.commands) { command in
            if command == .interfaceMode { experience.settings { $0.bigPicture = !enabled } }
            else if command == .home {
                NSApplication.shared.activate(ignoringOtherApps: true)
                NSApplication.shared.windows.first(where: { $0.canBecomeMain && $0.isVisible })?.makeKeyAndOrderFront(nil)
            } else if command == .menu && !enabled { experience.settings { $0.bigPicture = true } }
        }
        .onReceive(social.$profile) { value in if value != nil { library.achievements.flush() } }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in fullScreen(enabled); Task { await library.scanInstalledGames() } }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.willTerminateNotification)) { _ in library.activity.checkpoint(); library.social.stop(); big.cancelLoading(); controller.stop() }
    }
    private func fullScreen(_ value: Bool) {
        guard let window = NSApplication.shared.keyWindow ?? NSApplication.shared.mainWindow ?? NSApplication.shared.windows.first(where: { $0.canBecomeMain && $0.isVisible }) else { return }
        if window.styleMask.contains(.fullScreen) != value { window.toggleFullScreen(nil) }
    }
}
