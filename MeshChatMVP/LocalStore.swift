import Foundation
import Combine
 
/// Lightweight local persistence using JSON files per collection.
/// In production, swap backing store to SQLite/GRDB without changing the API.
final class LocalStore: ObservableObject {
 
    static let shared = LocalStore()
 
    @Published private(set) var channels:  [Channel]        = []
    @Published private(set) var messages:  [StoredMessage]  = []
    @Published private(set) var alerts:    [MeshAlertItem]  = []
    @Published private(set) var contacts:  [Contact]        = []
 
    private let fm = FileManager.default
    private lazy var storeURL: URL = {
        let docs = fm.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let dir = docs.appendingPathComponent("MeshStore", isDirectory: true)
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()
 
    private init() { load() }
 
    // MARK: - Load all
 
    private func load() {
        channels = decode([Channel].self,  from: "channels.json")  ?? defaultChannels()
        messages = decode([StoredMessage].self, from: "messages.json") ?? []
        alerts   = decode([MeshAlertItem].self, from: "alerts.json")  ?? []
        contacts = decode([Contact].self,  from: "contacts.json") ?? []
    }
 
    private func defaultChannels() -> [Channel] {
        [Channel.broadcast]
    }
 
    // MARK: - Channels
 
    func saveChannel(_ channel: Channel) {
        if let idx = channels.firstIndex(where: { $0.id == channel.id }) {
            channels[idx] = channel
        } else {
            channels.append(channel)
        }
        persist(channels, to: "channels.json")
    }
 
    func markRead(channelID: String) {
        if let idx = channels.firstIndex(where: { $0.id == channelID }) {
            channels[idx].unreadCount = 0
            persist(channels, to: "channels.json")
        }
    }
 
    func incrementUnread(channelID: String) {
        if let idx = channels.firstIndex(where: { $0.id == channelID }) {
            channels[idx].unreadCount += 1
            channels[idx].lastMessageAt = Date()
            persist(channels, to: "channels.json")
        }
    }
 
    // MARK: - Messages
 
    func saveMessage(_ msg: StoredMessage) {
        guard !messages.contains(where: { $0.envelopeID == msg.envelopeID }) else { return }
        messages.append(msg)
        // Cap at 2000 messages total; prune oldest
        if messages.count > 2000 {
            messages = Array(messages.suffix(1800))
        }
        persist(messages, to: "messages.json")
    }
 
    func messages(for channelID: String) -> [StoredMessage] {
        messages.filter { $0.channelID == channelID }
                .sorted { $0.timestamp < $1.timestamp }
    }
 
    func deleteMessage(id: UUID) {
        messages.removeAll { $0.id == id }
        persist(messages, to: "messages.json")
    }
 
    func addReaction(emoji: String, to messageID: UUID, by senderID: String) {
        guard let idx = messages.firstIndex(where: { $0.id == messageID }) else { return }
        var existing = messages[idx].reactions[emoji] ?? []
        if existing.contains(senderID) {
            existing.removeAll { $0 == senderID }  // toggle off
        } else {
            existing.append(senderID)
        }
        messages[idx].reactions[emoji] = existing.isEmpty ? nil : existing
        persist(messages, to: "messages.json")
    }
 
    // MARK: - Alerts
 
    func saveAlert(_ alert: MeshAlertItem) {
        if let idx = alerts.firstIndex(where: { $0.id == alert.id }) {
            alerts[idx] = alert
        } else {
            alerts.append(alert)
        }
        persist(alerts, to: "alerts.json")
    }
 
    func addComment(_ comment: AlertComment, to alertID: UUID) {
        guard let idx = alerts.firstIndex(where: { $0.id == alertID }) else { return }
        alerts[idx].comments.append(comment)
        persist(alerts, to: "alerts.json")
    }
 
    func confirmAlert(id: UUID, byContact contactID: String) {
        guard let idx = alerts.firstIndex(where: { $0.id == id }) else { return }
        if !alerts[idx].confirmedByContacts.contains(contactID) {
            alerts[idx].confirmedByContacts.append(contactID)
        }
        persist(alerts, to: "alerts.json")
    }
 
    func expireAlert(id: UUID) {
        guard let idx = alerts.firstIndex(where: { $0.id == id }) else { return }
        alerts[idx].isExpired = true
        persist(alerts, to: "alerts.json")
    }
 
    var activeAlerts: [MeshAlertItem] {
        alerts.filter { !$0.isExpired }
              .sorted { $0.timestamp > $1.timestamp }
    }
 
    // MARK: - Contacts
 
    func upsertContact(_ contact: Contact) {
        if let idx = contacts.firstIndex(where: { $0.id == contact.id }) {
            contacts[idx] = contact
        } else {
            contacts.append(contact)
        }
        persist(contacts, to: "contacts.json")
    }
 
    func addFriend(deviceID: String) {
        guard let idx = contacts.firstIndex(where: { $0.id == deviceID }) else { return }
        contacts[idx].isFriend = true
        persist(contacts, to: "contacts.json")
    }
 
    func setLocalName(_ name: String, for deviceID: String) {
        guard let idx = contacts.firstIndex(where: { $0.id == deviceID }) else { return }
        contacts[idx].localName = name.isEmpty ? nil : name
        persist(contacts, to: "contacts.json")
    }
 
    func recordSeen(deviceID: String, nickname: String, rssi: Int) {
        if let idx = contacts.firstIndex(where: { $0.id == deviceID }) {
            contacts[idx].lastSeenAt = Date()
            contacts[idx].rssiHistory.append(rssi)
            if contacts[idx].rssiHistory.count > 20 {
                contacts[idx].rssiHistory.removeFirst()
            }
            persist(contacts, to: "contacts.json")
        } else {
            let c = Contact(id: deviceID, nickname: nickname, localName: nil,
                            firstSeenAt: Date(), lastSeenAt: Date(),
                            rssiHistory: [rssi], isFriend: false, mutualFriendIDs: [])
            contacts.append(c)
            persist(contacts, to: "contacts.json")
        }
    }
 
    func trustScore(for deviceID: String) -> Double {
        guard let contact = contacts.first(where: { $0.id == deviceID }) else { return 0.10 }
        return contact.trustScore(myContacts: contacts)
    }
 
    // MARK: - Panic wipe
 
    func wipeAll() {
        channels = [Channel.broadcast]
        messages = []
        alerts   = []
        contacts = []
        for file in ["channels.json","messages.json","alerts.json","contacts.json"] {
            try? fm.removeItem(at: storeURL.appendingPathComponent(file))
        }
    }
 
    // MARK: - Persistence helpers
 
    private func persist<T: Encodable>(_ value: T, to filename: String) {
        DispatchQueue.global(qos: .utility).async { [weak self] in
            guard let self else { return }
            guard let data = try? JSONEncoder().encode(value) else { return }
            try? data.write(to: self.storeURL.appendingPathComponent(filename), options: .atomic)
        }
    }
 
    private func decode<T: Decodable>(_ type: T.Type, from filename: String) -> T? {
        let url = storeURL.appendingPathComponent(filename)
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(type, from: data)
    }
}