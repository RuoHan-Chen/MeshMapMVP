import Foundation
import SwiftUI

/// Configuration for customizable event types
public struct EventTypesConfig: Codable {
    public var hazard: EventTypeConfig
    public var help: EventTypeConfig
    public var other: EventTypeConfig
    
    public static let `default` = EventTypesConfig(
        hazard: EventTypeConfig(name: String(localized: "Hazard"), description: String(localized: "Danger or risk indicators")),
        help: EventTypeConfig(name: String(localized: "Help"), description: String(localized: "Assistance or support requests")),
        other: EventTypeConfig(name: String(localized: "Other"), description: String(localized: "Miscellaneous event categories"))
    )
    
    public init(hazard: EventTypeConfig, help: EventTypeConfig, other: EventTypeConfig) {
        self.hazard = hazard
        self.help = help
        self.other = other
    }
}

/// Configuration for a single event type
public struct EventTypeConfig: Codable {
    public var name: String
    public var description: String
    
    public init(name: String, description: String) {
        self.name = name
        self.description = description
    }
}

/// Manager for event types configuration
public class EventTypesManager: ObservableObject {
    @Published public var config: EventTypesConfig
    
    private let configURL: URL
    
    public init() {
        let documentsPath = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("MeshChatMVP", isDirectory: true)
        self.configURL = documentsPath.appendingPathComponent("event_types_config.json")
        
        // Create directory if it doesn't exist
        try? FileManager.default.createDirectory(at: documentsPath, withIntermediateDirectories: true)
        
        // Load configuration or use default
        if let data = try? Data(contentsOf: configURL),
           let loadedConfig = try? JSONDecoder().decode(EventTypesConfig.self, from: data) {
            self.config = loadedConfig
        } else {
            self.config = .default
            saveConfig()
        }
    }
    
    public func saveConfig() {
        if let data = try? JSONEncoder().encode(config) {
            try? data.write(to: configURL)
        }
    }
    
    public func updateConfig(_ newConfig: EventTypesConfig) {
        config = newConfig
        saveConfig()
    }
}
