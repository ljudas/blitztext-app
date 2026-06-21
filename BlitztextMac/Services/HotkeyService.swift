import Cocoa
import Observation

enum HotkeyMode: String, Codable, CaseIterable, Identifiable {
    case hold    // Tasten halten = aufnehmen, loslassen = stoppen
    case toggle  // Einmal drücken = starten, nochmal/Escape = stoppen

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .hold: return "Halten"
        case .toggle: return "Drücken"
        }
    }

    var description: String {
        switch self {
        case .hold: return "Tasten halten zum Aufnehmen, loslassen zum Stoppen"
        case .toggle: return "Einmal drücken zum Starten, nochmal oder Escape zum Stoppen"
        }
    }
}

enum HotkeyEvent {
    case down(WorkflowType)  // Keys pressed
    case up(WorkflowType)    // Keys released (for hold mode)
    case cancel              // Escape pressed
}

// MARK: - Configurable Hotkey Combo

enum HotkeyModifier: String, Codable, CaseIterable, Identifiable {
    case function, control, option, shift, command   // Reihenfolge = Label-Reihenfolge

    var id: String { rawValue }

    var symbol: String {
        switch self {
        case .function: return "fn"
        case .control: return "\u{2303}"   // ⌃
        case .option: return "\u{2325}"    // ⌥
        case .shift: return "\u{21E7}"     // ⇧
        case .command: return "\u{2318}"   // ⌘
        }
    }

    var eventFlag: NSEvent.ModifierFlags {
        switch self {
        case .function: return .function
        case .control: return .control
        case .option: return .option
        case .shift: return .shift
        case .command: return .command
        }
    }
}

struct HotkeyCombo: Codable, Equatable {
    var modifiers: Set<HotkeyModifier>

    /// Union der Modifier-Flags, gegen die `.flagsChanged` exakt verglichen wird.
    var eventFlags: NSEvent.ModifierFlags {
        modifiers.reduce(into: NSEvent.ModifierFlags()) { $0.insert($1.eventFlag) }
    }

    /// Symbole in `HotkeyModifier.allCases`-Reihenfolge, verbunden mit " + ".
    var label: String {
        HotkeyModifier.allCases
            .filter { modifiers.contains($0) }
            .map(\.symbol)
            .joined(separator: " + ")
    }

    /// >= 2 Modifier, sonst zu leicht versehentlich auszulösen.
    var isValid: Bool { modifiers.count >= 2 }

    static func from(_ flags: NSEvent.ModifierFlags) -> HotkeyCombo {
        let mods = HotkeyModifier.allCases.filter { flags.contains($0.eventFlag) }
        return HotkeyCombo(modifiers: Set(mods))
    }
}

@Observable
@MainActor
final class HotkeyService {
    private var globalMonitor: Any?
    private var localMonitor: Any?
    private var keyMonitor: Any?
    private var activeCombo: WorkflowType?  // Which combo is currently held

    /// Konfigurierte Belegung, von AppState gesetzt.
    var bindings: [WorkflowType: HotkeyCombo] = [:]

    var onHotkeyEvent: ((HotkeyEvent) -> Void)?

    func start() {
        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: .flagsChanged) { [weak self] event in
            Task { @MainActor in
                self?.handleFlags(event)
            }
        }
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: .flagsChanged) { [weak self] event in
            Task { @MainActor in
                self?.handleFlags(event)
            }
            return event
        }
        // Escape key monitor for toggle mode
        keyMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] event in
            Task { @MainActor in
                if event.keyCode == 53 { // Escape
                    self?.handleEscape()
                }
            }
        }
    }

    func stop() {
        if let globalMonitor { NSEvent.removeMonitor(globalMonitor) }
        if let localMonitor { NSEvent.removeMonitor(localMonitor) }
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        globalMonitor = nil
        localMonitor = nil
        keyMonitor = nil
    }

    private func handleFlags(_ event: NSEvent) {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)

        // No combo held yet -- start one if the flags match a configured, valid binding.
        if activeCombo == nil {
            if let match = bindings.first(where: { $0.value.isValid && $0.value.eventFlags == flags }) {
                activeCombo = match.key
                onHotkeyEvent?(.down(match.key))
            }
            return
        }

        // A combo is held -- once the flags diverge from its exact set, fire the release.
        if let combo = activeCombo, flags != bindings[combo]?.eventFlags {
            activeCombo = nil
            onHotkeyEvent?(.up(combo))
        }
    }

    private func handleEscape() {
        activeCombo = nil
        onHotkeyEvent?(.cancel)
    }
}
