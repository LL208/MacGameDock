import AppKit
import Combine
import GameController

// All controller and keyboard input enters the same semantic command stream.
enum DeckCommand: String, CaseIterable, Hashable {
    case up, down, left, right, confirm, back, search, favorite, previousSection, nextSection, previousPage, nextPage, menu, home, erase, interfaceMode
}
enum DeckButtonMapping {
    static func face(_ command: DeckCommand, swapped: Bool) -> DeckCommand {
        guard swapped else { return command }
        switch command { case .confirm: return .back; case .back: return .confirm; default: return command }
    }
}
struct DeckInputRepeater {
    private var held: Set<DeckCommand> = []
    private var repeats: [DeckCommand: TimeInterval] = [:]
    private let directions: Set<DeckCommand> = [.up, .down, .left, .right]
    mutating func reset(_ pressed: Set<DeckCommand> = []) { held = pressed; repeats = [:] }
    mutating func poll(_ pressed: Set<DeckCommand>, now: TimeInterval) -> [DeckCommand] {
        var result: [DeckCommand] = []
        // Fixed order and one direction per sample make diagonals deterministic.
        let direction = [DeckCommand.up, .down, .left, .right].first { pressed.contains($0) }
        let normalized = pressed.subtracting(directions).union(direction.map { [$0] } ?? [])
        for command in DeckCommand.allCases where normalized.contains(command) {
            if !held.contains(command) { result.append(command); if directions.contains(command) { repeats[command] = now + 0.38 } }
            else if directions.contains(command), now >= (repeats[command] ?? .infinity) { result.append(command); repeats[command] = now + 0.11 }
        }
        for command in held.subtracting(normalized) { repeats.removeValue(forKey: command) }
        held = normalized
        return result
    }
}
enum DeckFocusNavigation {
    // Visual rows may have different widths: tabs, filters, covers and pagination.
    static func moveSections(_ command: DeckCommand, current: Int, counts: [Int], columns: [Int]) -> Int {
        var rows: [[Int]] = []; var offset = 0
        for (section, count) in counts.enumerated() {
            let width = section < columns.count ? max(1, columns[section]) : 1
            for start in stride(from: 0, to: max(0, count), by: width) {
                rows.append(Array((offset + start)..<(offset + min(start + width, count))))
            }
            offset += max(0, count)
        }
        guard offset > 0 else { return 0 }
        let index = min(max(0, current), offset - 1)
        guard let row = rows.firstIndex(where: { $0.contains(index) }), let column = rows[row].firstIndex(of: index) else { return index }
        switch command {
        case .left: return max(0, index - 1)
        case .right: return min(offset - 1, index + 1)
        case .up, .down:
            let target = row + (command == .up ? -1 : 1)
            guard rows.indices.contains(target) else { return index }
            return rows[target][min(column, rows[target].count - 1)]
        default: return index
        }
    }
    static func move(_ command: DeckCommand, current: Int, count: Int, columns: Int) -> Int {
        guard count > 0 else { return 0 }
        let index = min(max(current, 0), count - 1), width = max(1, columns)
        switch command {
        case .left: return max(0, index - 1)
        case .right: return min(count - 1, index + 1)
        case .up: return max(0, index - width)
        case .down: return min(count - 1, index + width)
        default: return index
        }
    }
}
struct DeckHomeGesture {
    private var homeHeld = false
    private var menuStart: TimeInterval?
    private var menuFired = false
    mutating func poll(home: Bool, menu: Bool, eligible: Bool, now: TimeInterval) -> Bool {
        let homePressed = home && !homeHeld; homeHeld = home
        if !eligible || !menu || homePressed { menuStart = nil; menuFired = false }
        else {
            if menuStart == nil { menuStart = now }
            if !menuFired, now - (menuStart ?? now) >= 1.2 { menuFired = true; return true }
        }
        return homePressed
    }
}
struct DeckControllerGlyph: Equatable {
    var symbol: String
    var label: String
}
@MainActor
final class DeckControllerInput: ObservableObject {
    let commands = PassthroughSubject<DeckCommand, Never>()
    @Published private(set) var controllerName = "Nessun controller collegato"
    @Published private(set) var battery: Int?
    @Published private(set) var connected = false
    @Published private(set) var readings = "Premi un pulsante o muovi una levetta"
    @Published private(set) var glyphs: [DeckCommand: DeckControllerGlyph] = [:]
    var swapConfirmBack = false { didSet { if oldValue != swapConfirmBack { repeatInput.reset(); device = nil } } }
    var bigPicture = false
    var gameRunning = false
    var sessionMenuVisible = false
    var navigationSuspended = false
    private var requiresNeutral = false
    func synchronizeNavigation() { requiresNeutral = true }
    func glyph(_ command: DeckCommand) -> DeckControllerGlyph {
        glyphs[command] ?? DeckControllerGlyph(symbol: "gamecontroller", label: command == .confirm ? "A" : command == .back ? "B" : command == .search ? "X" : command == .favorite ? "Y" : "Menu")
    }
    func label(_ command: DeckCommand) -> String { glyph(command).label }
    private var timer: Timer?
    private var keyboard: Any?
    private var repeatInput = DeckInputRepeater()
    private var device: ObjectIdentifier?
    private var homeGesture = DeckHomeGesture()
    func start() {
        guard timer == nil else { return }
        GCController.shouldMonitorBackgroundEvents = true
        let value = Timer(timeInterval: 1.0 / 60, repeats: true) { [weak self] _ in Task { @MainActor in self?.poll() } }
        RunLoop.main.add(value, forMode: .common); timer = value
        keyboard = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            let consumed = MainActor.assumeIsolated {
                guard let self, (self.bigPicture || self.sessionMenuVisible), !self.navigationSuspended, !event.modifierFlags.contains(.command), !event.modifierFlags.contains(.control) else { return false }
                let command: DeckCommand?
                switch event.keyCode {
                case 123: command = .left
                case 124: command = .right
                case 125: command = .down
                case 126: command = .up
                case 36, 76, 49: command = .confirm
                case 53: command = .back
                case 7: command = .search
                case 16: command = .favorite
                case 48: command = event.modifierFlags.contains(.shift) ? .previousSection : .nextSection
                case 116: command = .previousPage
                case 121: command = .nextPage
                case 46: command = .menu
                case 51: command = .erase
                default: command = nil
                }
                if let command { self.commands.send(command); return true }
                return false
            }
            return consumed ? nil : event
        }
    }
    func stop() {
        timer?.invalidate(); timer = nil
        if let keyboard { NSEvent.removeMonitor(keyboard) }; keyboard = nil
        for controller in GCController.controllers() { controller.extendedGamepad?.buttonHome?.preferredSystemGestureState = .enabled }
        GCController.shouldMonitorBackgroundEvents = false
    }
    private func updateGlyphs(_ controller: GCController) {
        let playstation = (controller.productCategory + " " + (controller.vendorName ?? "")).lowercased().contains("dual") || controller.extendedGamepad is GCDualShockGamepad || controller.extendedGamepad is GCDualSenseGamepad
        func glyph(_ input: GCControllerButtonInput?, _ fallback: String, _ label: String) -> DeckControllerGlyph {
            DeckControllerGlyph(symbol: input?.sfSymbolsName ?? fallback, label: playstation ? label : (input?.localizedName?.replacingOccurrences(of: " Button", with: "") ?? label))
        }
        if let g = controller.extendedGamepad {
            let a = glyph(g.buttonA, "a.circle", playstation ? "✕" : "A"), b = glyph(g.buttonB, "b.circle", playstation ? "○" : "B")
            glyphs = [.confirm: swapConfirmBack ? b : a, .back: swapConfirmBack ? a : b,
                      .search: glyph(g.buttonX, "x.circle", playstation ? "□" : "X"), .favorite: glyph(g.buttonY, "y.circle", playstation ? "△" : "Y"),
                      .previousSection: glyph(g.leftShoulder, "l1.rectangle.roundedbottom", "L1"), .nextSection: glyph(g.rightShoulder, "r1.rectangle.roundedbottom", "R1"),
                      .previousPage: glyph(g.leftTrigger, "l2.rectangle.roundedtop", "L2"), .nextPage: glyph(g.rightTrigger, "r2.rectangle.roundedtop", "R2"),
                      .home: glyph(g.buttonHome, "house.circle", playstation ? "PS" : "Home"), .menu: glyph(g.buttonMenu, "line.3.horizontal.circle", "Menu"), .interfaceMode: glyph(g.buttonOptions, "rectangle.on.rectangle", playstation ? "Share" : "View")]
        } else if let g = controller.microGamepad {
            let a = glyph(g.buttonA, "a.circle", "A"), b = glyph(g.buttonX, "x.circle", "X")
            glyphs = [.confirm: swapConfirmBack ? b : a, .back: swapConfirmBack ? a : b, .menu: glyph(g.buttonMenu, "line.3.horizontal.circle", "Menu")]
        }
    }
    private func poll() {
        // Keep the selected controller while connected; don't steal focus when a second one appears.
        let devices = GCController.controllers().filter { $0.extendedGamepad != nil || $0.microGamepad != nil }
        let current = devices.first(where: { ObjectIdentifier($0) == device })
        let active = devices.first { candidate in
            candidate.physicalInputProfile.buttons.values.contains { $0.isPressed } || candidate.physicalInputProfile.axes.values.contains { abs($0.value) > 0.55 }
        }
        guard let controller = (current.map { c in c.physicalInputProfile.buttons.values.contains { $0.isPressed } ? c : nil } ?? nil) ?? active ?? current ?? devices.first else {
            if connected { connected = false; controllerName = "Controller scollegato · ricollegalo per continuare"; battery = nil }
            device = nil; repeatInput.reset(); homeGesture = DeckHomeGesture(); return
        }
        let identifier = ObjectIdentifier(controller)
        var pressed: Set<DeckCommand> = []
        func button(_ value: GCControllerButtonInput?, _ command: DeckCommand) { if value?.isPressed == true { pressed.insert(command) } }
        if let g = controller.extendedGamepad {
            let x = abs(g.dpad.xAxis.value) > 0.5 ? g.dpad.xAxis.value : g.leftThumbstick.xAxis.value
            let y = abs(g.dpad.yAxis.value) > 0.5 ? g.dpad.yAxis.value : g.leftThumbstick.yAxis.value
            if abs(y) >= abs(x), abs(y) > 0.55 { pressed.insert(y > 0 ? .up : .down) }
            else if abs(x) > 0.55 { pressed.insert(x > 0 ? .right : .left) }
            button(g.buttonA, DeckButtonMapping.face(.confirm, swapped: swapConfirmBack)); button(g.buttonB, DeckButtonMapping.face(.back, swapped: swapConfirmBack)); button(g.buttonX, .search); button(g.buttonY, .favorite)
            button(g.leftShoulder, .previousSection); button(g.rightShoulder, .nextSection)
            button(g.leftTrigger, .previousPage); button(g.rightTrigger, .nextPage)
            button(g.buttonMenu, .menu); button(g.buttonOptions, .interfaceMode)
            let names = [(g.buttonA, ".confirm"), (g.buttonB, ".back"), (g.buttonX, ".search"), (g.buttonY, ".favorite")].filter { $0.0.isPressed }.map { $0.0.localizedName ?? $0.1 }.joined(separator: " · ")
            let value = String(format: "%@ · L %.1f/%.1f · R %.1f/%.1f · D %.0f/%.0f", names, g.leftThumbstick.xAxis.value, g.leftThumbstick.yAxis.value, g.rightThumbstick.xAxis.value, g.rightThumbstick.yAxis.value, g.dpad.xAxis.value, g.dpad.yAxis.value)
            if value != readings { readings = value }
        } else if let g = controller.microGamepad {
            if g.dpad.yAxis.value > 0.55 { pressed.insert(.up) }; if g.dpad.yAxis.value < -0.55 { pressed.insert(.down) }
            if g.dpad.xAxis.value > 0.55 { pressed.insert(.right) }; if g.dpad.xAxis.value < -0.55 { pressed.insert(.left) }
            button(g.buttonA, DeckButtonMapping.face(.confirm, swapped: swapConfirmBack)); button(g.buttonX, DeckButtonMapping.face(.back, swapped: swapConfirmBack)); button(g.buttonMenu, .menu)
        }
        if identifier != device { device = identifier; repeatInput.reset(pressed); updateGlyphs(controller) }
        if !connected { connected = true }; let name = controller.vendorName ?? controller.productCategory
        if controllerName != name { controllerName = name }
        let level = controller.battery.map { $0.batteryLevel >= 0 ? Int($0.batteryLevel * 100) : nil } ?? nil
        if battery != level { battery = level }
        let now = ProcessInfo.processInfo.systemUptime
        let home = controller.extendedGamepad?.buttonHome
        home?.preferredSystemGestureState = gameRunning ? .disabled : .enabled
        if homeGesture.poll(home: home?.isPressed == true, menu: pressed.contains(.menu), eligible: gameRunning || (!NSApplication.shared.isActive && bigPicture), now: now) { commands.send(.home) }
        guard (NSApplication.shared.isActive || sessionMenuVisible), !navigationSuspended else {
            repeatInput.reset(pressed)
            return
        }

        if requiresNeutral {
            repeatInput.reset(pressed)
            if pressed.isEmpty { requiresNeutral = false }
            return
        }
        for command in repeatInput.poll(pressed, now: now) { commands.send(command) }
    }
}
