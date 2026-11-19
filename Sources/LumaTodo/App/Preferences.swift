import Foundation
import Observation

enum AppLanguage: String, Codable, CaseIterable, Identifiable {
    case chinese, english
    var id: Self { self }
}

struct Words {
    var language: AppLanguage
    func callAsFunction(_ chinese: String, _ english: String) -> String {
        language == .chinese ? chinese : english
    }
    var locale: Locale { Locale(identifier: language == .chinese ? "zh-Hans" : "en") }
}

enum AppearanceChoice: String, Codable, CaseIterable, Identifiable {
    case system, light, dark
    var id: Self { self }
}

enum TaskOrder: String, Codable, CaseIterable, Identifiable {
    case date, priority
    var id: Self { self }
}

struct Shortcut: Codable, Equatable {
    var key: UInt32 = 17
    var modifiers: UInt32 = (1 << 8) | (1 << 11)
    var label: String = "T"
}

struct PreferencesValues: Codable, Equatable {
    var language: AppLanguage = .chinese
    var appearance: AppearanceChoice = .system
    var glass = true
    var opaque = false
    var compact = false
    var animations = true
    var alwaysOnTop = true
    var allSpaces = false
    var snapToEdge = true
    var autoHide = false
    var rememberPosition = true
    var windowWidth = 364.0
    var windowHeight = 580.0
    var defaultLead = 10
    var sound = true
    var defaultSnooze = 5
    var menuBar = true
    var shortcut: Shortcut? = Shortcut()
    var sort: TaskOrder = .date
}

@MainActor @Observable
final class Preferences {
    var values: PreferencesValues {
        didSet {
            guard values != oldValue else { return }
            if let data = try? JSONEncoder().encode(values) { defaults.set(data, forKey: "preferences.v1") }
            onChange?(oldValue)
        }
    }
    @ObservationIgnored var onChange: ((PreferencesValues) -> Void)?
    @ObservationIgnored let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        var loaded = defaults.data(forKey: "preferences.v1")
            .flatMap { try? JSONDecoder().decode(PreferencesValues.self, from: $0) } ?? PreferencesValues()
        if !defaults.bool(forKey: "preferences.fit-height.v2") {
            let current = PreferencesValues()
            if loaded.windowWidth == 350 { loaded.windowWidth = current.windowWidth }
            if loaded.windowHeight == 460 { loaded.windowHeight = current.windowHeight }
            if let data = try? JSONEncoder().encode(loaded) { defaults.set(data, forKey: "preferences.v1") }
            defaults.set(true, forKey: "preferences.fit-height.v2")
        }
        values = loaded
    }

    var words: Words { Words(language: values.language) }
}
