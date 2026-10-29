import AppKit
import Combine
import GameController
import SwiftUI

struct ControllersView: View {
    @ObservedObject private var appLanguage = AppLanguage.shared
    @EnvironmentObject var experience: GameExperience
    @State private var controllers: [GCController] = []
    @State private var testing = false
    @State private var readings: [String: String] = [:]
    private let clock = Timer.publish(every: 0.1, on: .main, in: .common).autoconnect()
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                Text(L10n.text("Controller")).font(.largeTitle.bold())
                Text(L10n.text("Collega il controller via Bluetooth o USB. Il rilevamento usa il supporto nativo di macOS.")).foregroundStyle(.secondary)
                HStack {
                    Button(L10n.text("Cerca controller wireless")) { GCController.startWirelessControllerDiscovery(completionHandler: nil) }
                    Button(L10n.text("Impostazioni controller")) { NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.Game-Controllers-Settings.extension")!) }
                    Toggle(L10n.text("Test pulsanti e levette"), isOn: $testing)
                }
                Toggle(L10n.text("Inverti Conferma e Indietro nell’interfaccia"), isOn: Binding(get: { experience.preferences.swapControllerConfirmBack == true }, set: { value in experience.settings { $0.swapControllerConfirmBack = value } }))
                if controllers.isEmpty { Label(L10n.text("Nessun controller compatibile rilevato"), systemImage: "gamecontroller") }
                ForEach(controllers, id: \.self) { controller in
                    GroupBox(L10n.text(controller.vendorName ?? "Controller")) {
                        VStack(alignment: .leading, spacing: 8) {
                            Text(L10n.text(controller.productCategory))
                            Text(L10n.text(controller.extendedGamepad == nil ? "Profilo senza gamepad esteso" : "Gamepad esteso disponibile"))
                            if let battery = controller.battery, battery.batteryLevel >= 0 { Text(L10n.text("Batteria: \(Int(battery.batteryLevel * 100))%")) }
                            if testing { Text(L10n.text(readings[String(describing: ObjectIdentifier(controller))] ?? "Premi un pulsante…")).font(.caption.monospaced()) }
                        }.frame(maxWidth: .infinity, alignment: .leading).padding(8)
                    }
                }
                Text(L10n.text("La rimappatura di sistema si configura nelle impostazioni di macOS. Il passaggio degli input ai giochi Windows dipende dal runtime Wine e dal gioco; questa pagina non crea un controller virtuale né sostituisce Steam Input.")).font(.callout).foregroundStyle(.secondary)
            }
        }
        .onAppear { controllers = GCController.controllers() }
        .onDisappear { GCController.stopWirelessControllerDiscovery() }
        .onReceive(clock) { _ in
            controllers = GCController.controllers()
            guard testing else { return }
            for c in controllers {
                guard let g = c.extendedGamepad else { continue }
                let buttons = [("A", g.buttonA), ("B", g.buttonB), ("X", g.buttonX), ("Y", g.buttonY), ("L1", g.leftShoulder), ("R1", g.rightShoulder), ("L2", g.leftTrigger), ("R2", g.rightTrigger)].filter { $0.1.isPressed }.map { $0.0 }.joined(separator: " ")
                readings[String(describing: ObjectIdentifier(c))] = String(format: "%@ · L %.2f/%.2f · R %.2f/%.2f · D %.0f/%.0f", buttons, g.leftThumbstick.xAxis.value, g.leftThumbstick.yAxis.value, g.rightThumbstick.xAxis.value, g.rightThumbstick.yAxis.value, g.dpad.xAxis.value, g.dpad.yAxis.value)
            }
        }
    }
}
