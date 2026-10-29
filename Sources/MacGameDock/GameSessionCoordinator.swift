import AppKit
import ApplicationServices
import Combine
import SwiftUI

// Window coordinates use a top-left origin; AppKit screens use a bottom-left origin.
enum GameWindowPlacement {
    static func isGameSurface(layer: Int, width: Double, height: Double) -> Bool { layer >= 0 && width > 100 && height > 80 }
    static func frame(size: CGSize, visible: CGRect, primaryTop: CGFloat) -> CGRect {
        let scale = min(1, visible.width / max(1, size.width), visible.height / max(1, size.height))
        let width = max(1, size.width) * scale, height = max(1, size.height) * scale
        return CGRect(x: visible.midX - width / 2, y: primaryTop - visible.midY - height / 2, width: width, height: height)
    }
    static func descendants(of known: Set<Int32>, parents: [Int32: Int32]) -> Set<Int32> {
        var result = known; var changed = true
        while changed {
            changed = false
            for (pid, parent) in parents where pid > 1 && result.contains(parent) && !result.contains(pid) { result.insert(pid); changed = true }
        }
        return result
    }
}

@MainActor
final class GameSessionCoordinator: ObservableObject {
    @Published private(set) var menuVisible = false
    @Published private(set) var handoffPending = false
    @Published private(set) var currentGame: Game?
    @Published private(set) var status = ""
    @Published private(set) var accessibilityAllowed = AXIsProcessTrusted()
    private weak var library: Library?
    private struct Session {
        var game: Game
        var rootPID: Int32
        var pids: Set<Int32>
        var display: CGDirectDisplayID?
        var started: Date
        var uptime: TimeInterval
        var windowPID: Int32?
        var executable: String
        var winePrefix: String?
    }
    private var sessions: [UUID: Session] = [:]
    private var targets: [UUID: CGDirectDisplayID] = [:]
    private var focusTask: Task<Void, Never>?
    private var focusGeneration = UUID()
    private var panel: NSPanel?
    private var controller: DeckControllerInput?
    private var hiddenForGame = false
    init(library: Library) { self.library = library }
    func connect(_ controller: DeckControllerInput) { self.controller = controller }
    func captureDisplay(for game: Game, overwrite: Bool = false) {
        guard NSApp != nil else { return }
        guard overwrite || targets[game.id] == nil else { return }
        // Query only. Never interrupt game launch with a system permission dialog.
        // An explicit action in the session menu owns the permission request.
        accessibilityAllowed = AXIsProcessTrusted()
        let screen = NSApp.keyWindow?.screen ?? NSApp.mainWindow?.screen ?? NSScreen.main
        if let id = screen?.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber { targets[game.id] = id.uint32Value }
    }
    func forgetTarget(_ game: Game) { targets.removeValue(forKey: game.id) }
    func started(_ game: Game, pid: Int32, executable: String? = nil) {
        let display = targets.removeValue(forKey: game.id)
        sessions[game.id] = Session(game: game, rootPID: pid, pids: [pid], display: display, started: Date(), uptime: ProcessInfo.processInfo.systemUptime, executable: executable ?? game.executablePath, winePrefix: game.isNative ? nil : (game.managedLaunch?.prefix ?? library?.prefix(for: game).path))
        currentGame = game
        focus(game, moveToDisplay: true)
    }
    func stopped(_ game: Game) {
        sessions.removeValue(forKey: game.id); targets.removeValue(forKey: game.id)
        guard currentGame?.id == game.id else { return }
        focusGeneration = UUID(); focusTask?.cancel(); handoffPending = false; hidePanel()
        currentGame = sessions.values.sorted { $0.started > $1.started }.first?.game
        guard NSApp != nil else { return }
        restoreLauncher()
        NSApp.activate(ignoringOtherApps: true)
        NSApp.windows.first { $0.canBecomeMain && $0.isVisible && $0 !== panel }?.makeKeyAndOrderFront(nil)
    }
    func elapsed(_ game: Game) -> TimeInterval { sessions[game.id].map { max(0, ProcessInfo.processInfo.systemUptime - $0.uptime) } ?? 0 }
    var canShowMenu: Bool { !sessions.isEmpty }
    func toggleMenu() {
        guard NSApp != nil else { return }
        if menuVisible { resume(); return }
        guard let library, let controller, let game = currentGame ?? sessions.values.sorted(by: { $0.started > $1.started }).first?.game else { return }
        restoreLauncher()
        currentGame = game; focusGeneration = UUID(); focusTask?.cancel(); handoffPending = false; accessibilityAllowed = AXIsProcessTrusted(); status = ""
        if panel == nil {
            let value = SessionPanel(contentRect: .zero, styleMask: [.titled, .fullSizeContentView, .nonactivatingPanel], backing: .buffered, defer: false)
            value.title = "Menu di gioco · MacGameDeck"; value.titleVisibility = .hidden; value.titlebarAppearsTransparent = true
            value.isReleasedWhenClosed = false; value.level = .floating; value.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
            panel = value
        }
        let screen = targetScreen(game) ?? NSScreen.main ?? NSScreen.screens.first
        let visible = screen?.visibleFrame ?? CGRect(x: 0, y: 0, width: 1000, height: 800)
        let size = CGSize(width: min(760, visible.width - 32), height: min(780, visible.height - 32))
        panel?.setFrame(CGRect(x: visible.midX - size.width / 2, y: visible.midY - size.height / 2, width: size.width, height: size.height), display: true)
        panel?.contentView = NSHostingView(rootView: GameSessionMenu(session: self, library: library, activity: library.activity, achievements: library.achievements, controller: controller, game: game).preferredColorScheme(.dark))
        menuVisible = true; controller.sessionMenuVisible = true; controller.synchronizeNavigation()
        panel?.makeKeyAndOrderFront(nil)
    }
    private func hidePanel() { menuVisible = false; controller?.sessionMenuVisible = false; panel?.orderOut(nil); panel?.contentView = nil }
    func resume() { guard let game = currentGame else { return }; hidePanel(); focus(game, moveToDisplay: false) }
    func openControllerSettings() {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.Game-Controllers-Settings.extension")!)
        status = "Rimappa il controller nelle impostazioni di macOS, poi torna qui e scegli Riprendi. I giochi Wine possono applicare proprie mappature."
    }
    func requestAccessibility() {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        accessibilityAllowed = AXIsProcessTrustedWithOptions(options)
        if !accessibilityAllowed { NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!) }
    }
    func requestExit(force: Bool = false) {
        guard let game = currentGame, let session = sessions[game.id] else { return }
        if force {
            if let pid = session.windowPID, let app = NSRunningApplication(processIdentifier: pid), !app.isTerminated { _ = app.forceTerminate() }
            else { library?.terminateGameProcess(game) }
            status = "Terminazione richiesta. Attendo la chiusura…"; return }
        let pid = session.windowPID ?? session.rootPID
        if let app = NSRunningApplication(processIdentifier: pid) {
            let element = AXUIElementCreateApplication(pid)
            var windows: CFTypeRef?
            if AXIsProcessTrusted(), AXUIElementCopyAttributeValue(element, kAXWindowsAttribute as CFString, &windows) == .success, let list = windows as? [AXUIElement] {
                var requested = false
                for window in list {
                    var close: CFTypeRef?
                    if AXUIElementCopyAttributeValue(window, kAXCloseButtonAttribute as CFString, &close) == .success, let close { requested = AXUIElementPerformAction(close as! AXUIElement, kAXPressAction as CFString) == .success || requested }
                }
                if !requested { _ = app.terminate() }
            } else { _ = app.terminate() }
        }
        status = "Chiusura richiesta. Se il gioco chiede conferma, scegli Riprendi per salvarlo e uscire."
    }
    func focus(_ game: Game, moveToDisplay: Bool = false) {
        guard NSApp != nil, sessions[game.id] != nil else { return }
        focusTask?.cancel(); let generation = UUID(); focusGeneration = generation; currentGame = game; handoffPending = true
        focusTask = Task { [weak self] in
            guard let self else { return }; defer { if self.focusGeneration == generation { self.handoffPending = false } }
            let deadline = ProcessInfo.processInfo.systemUptime + 45
            var stability = GameFocusStability()
            var placed: Set<Int> = []
            var identified = false
            var inspectedWine = 0
            while ProcessInfo.processInfo.systemUptime < deadline {
                guard !Task.isCancelled, focusGeneration == generation, !menuVisible, var session = sessions[game.id] else { return }
                // Include other Spaces: an exclusive fullscreen game may not yet
                // be visible while the launcher owns the foreground Space.
                let entries = CGWindowListCopyWindowInfo([.optionAll, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
                let owners = Set(entries.compactMap { ($0[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value })
                let prefix = session.winePrefix, executable = session.executable
                let snapshot = await Task.detached(priority: .userInitiated) { GameProcessDiscovery.snapshot(windowOwners: owners, prefix: prefix, executable: executable) }.value
                guard !Task.isCancelled, focusGeneration == generation, sessions[game.id] != nil else { return }
                inspectedWine = max(inspectedWine, snapshot.inspected)
                session.pids = GameWindowPlacement.descendants(of: session.pids, parents: snapshot.parents).union(snapshot.matchingWine)
                sessions[game.id] = session
                let candidates = entries.filter { item in
                    guard let pid = (item[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value, session.pids.contains(pid), let layer = item[kCGWindowLayer as String] as? Int,
                          let bounds = item[kCGWindowBounds as String] as? [String: Any], let width = bounds["Width"] as? Double, let height = bounds["Height"] as? Double else { return false }
                    return GameWindowPlacement.isGameSurface(layer: layer, width: width, height: height)
                }
                // Larger windows usually replace launch splash screens; prefer
                // an on-screen window when the game has several peers.
                let window = candidates.sorted { area($0) > area($1) }.first
                if let window, let pid = (window[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value {
                    sessions[game.id]?.windowPID = pid
                    if !identified {
                        identified = true
                        library?.diagnostics.write("Focus", "Finestra individuata · PID \(pid) · origine \(snapshot.matchingWine.contains(pid) ? "container Wine" : "processo avviato")", game: game)
                    }
                    let number = window[kCGWindowNumber as String] as? Int ?? 0
                    if moveToDisplay && !placed.contains(number) { moveWindows(pid: pid, game: game); placed.insert(number) }
                    _ = activatePID(pid); raiseWindow(pid)
                    try? await Task.sleep(nanoseconds: 250_000_000)
                    guard !Task.isCancelled, focusGeneration == generation, !menuVisible else { return }
                    let foreground = NSWorkspace.shared.frontmostApplication?.processIdentifier
                    let isFront = foreground.map { session.pids.contains($0) } ?? false
                    if isFront && !hiddenForGame {
                        // A fullscreen launcher must relinquish its Space as well
                        // as its key window, otherwise it can cover a Wine window.
                        hiddenForGame = true; NSApp.hide(nil)
                    }
                    if stability.observe(window: number, isFront: isFront, now: ProcessInfo.processInfo.systemUptime) {
                        library?.diagnostics.write("Focus", "Gioco in primo piano confermato · PID \(pid) · finestra \(number)", game: game)
                        return
                    }
                    // If the user deliberately switches to a third app after
                    // handoff, don't pull them back into the game.
                    if hiddenForGame, let foreground, foreground != ProcessInfo.processInfo.processIdentifier, !session.pids.contains(foreground) { return }
                } else {
                    _ = stability.observe(window: 0, isFront: false, now: ProcessInfo.processInfo.systemUptime)
                    // Activating the original process can make a window on
                    // another Space discoverable even before Wine is identified.
                    _ = activatePID(session.rootPID)
                }
                try? await Task.sleep(nanoseconds: 400_000_000)
            }
            if !Task.isCancelled, focusGeneration == generation {
                restoreLauncher()
                status = identified ? "Il gioco non ha confermato il primo piano. Abilita Accessibilità e riprova con Torna al gioco." : "Finestra del gioco non identificata. Apri i log Focus per la diagnosi."
                library?.diagnostics.write("Focus", status + " · processi Wine verificati: \(inspectedWine) · Accessibilità: \(AXIsProcessTrusted() ? "sì" : "no")", game: game)
            }
        }
    }
    private func area(_ window: [String: Any]) -> Double {
        guard let bounds = window[kCGWindowBounds as String] as? [String: Any], let width = bounds["Width"] as? Double, let height = bounds["Height"] as? Double else { return 0 }
        return width * height
    }
    private func restoreLauncher() {
        if hiddenForGame { hiddenForGame = false; NSApp.unhideWithoutActivation() }
    }
    private func targetScreen(_ game: Game) -> NSScreen? {
        guard let id = sessions[game.id]?.display else { return nil }
        return NSScreen.screens.first { ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value == id }
    }
    private func moveWindows(pid: Int32, game: Game) {
        guard NSScreen.screens.count > 1, let screen = targetScreen(game) else { return }
        accessibilityAllowed = AXIsProcessTrusted()
        guard accessibilityAllowed else { library?.diagnostics.write("Schermi", "Per spostare la finestra sullo schermo di MacGameDeck abilita Accessibilità dal menu Home.", game: game); return }
        let app = AXUIElementCreateApplication(pid); var windows: CFTypeRef?
        guard AXUIElementCopyAttributeValue(app, kAXWindowsAttribute as CFString, &windows) == .success, let list = windows as? [AXUIElement] else { return }
        for window in list {
            var value: CFTypeRef?; var size = CGSize.zero
            guard AXUIElementCopyAttributeValue(window, kAXSizeAttribute as CFString, &value) == .success, let value, CFGetTypeID(value) == AXValueGetTypeID(), AXValueGetValue(value as! AXValue, .cgSize, &size) else { continue }
            let rect = GameWindowPlacement.frame(size: size, visible: screen.visibleFrame, primaryTop: NSScreen.screens.first?.frame.maxY ?? 0)
            if size.width > rect.width || size.height > rect.height {
                var fitted = rect.size
                if let value = AXValueCreate(.cgSize, &fitted) { _ = AXUIElementSetAttributeValue(window, kAXSizeAttribute as CFString, value) }
            }
            var point = rect.origin
            if let position = AXValueCreate(.cgPoint, &point) {
                let result = AXUIElementSetAttributeValue(window, kAXPositionAttribute as CFString, position)
                library?.diagnostics.write("Schermi", result == .success ? "Finestra spostata sullo schermo di MacGameDeck" : "Il gioco non consente di spostare questa finestra (\(result.rawValue)).", game: game)
            }
        }
    }
    private func activatePID(_ pid: Int32) -> Bool {
        let activated = NSRunningApplication(processIdentifier: pid)?.activate(options: [.activateAllWindows, .activateIgnoringOtherApps]) ?? false
        guard AXIsProcessTrusted() else { return activated }
        let result = AXUIElementSetAttributeValue(AXUIElementCreateApplication(pid), kAXFrontmostAttribute as CFString, kCFBooleanTrue)
        return activated || result == .success
    }
    private func raiseWindow(_ pid: Int32) {
        guard AXIsProcessTrusted() else { return }
        var windows: CFTypeRef?
        if AXUIElementCopyAttributeValue(AXUIElementCreateApplication(pid), kAXWindowsAttribute as CFString, &windows) == .success, let list = windows as? [AXUIElement], let first = list.first {
            let app = AXUIElementCreateApplication(pid)
            _ = AXUIElementSetAttributeValue(app, kAXFocusedWindowAttribute as CFString, first)
            _ = AXUIElementSetAttributeValue(first, kAXMainAttribute as CFString, kCFBooleanTrue)
            _ = AXUIElementSetAttributeValue(first, kAXFocusedAttribute as CFString, kCFBooleanTrue)
            _ = AXUIElementPerformAction(first, kAXRaiseAction as CFString)
        }
    }
}
private final class SessionPanel: NSPanel { override var canBecomeKey: Bool { true }; override var canBecomeMain: Bool { false } }
