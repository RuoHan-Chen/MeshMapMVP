import SwiftUI

@main
struct MeshChatApp: App {
    @StateObject private var mesh     = BluetoothMeshService()
    @StateObject private var store    = LocalStore.shared
    @StateObject private var lockMgr  = AppLockManager()

    private var isOnboarded: Bool {
        UserDefaults.standard.bool(forKey: "onboarding.complete")
    }
    @State private var onboardingDone = UserDefaults.standard.bool(forKey: "onboarding.complete")

    var body: some Scene {
        WindowGroup {
            Group {
                if !onboardingDone {
                    OnboardingFlow(lockManager: lockMgr) {
                        onboardingDone = true
                    }
                    .environmentObject(mesh)
                } else if !lockMgr.isUnlocked && (lockMgr.hasPIN || lockMgr.useBiometrics) {
                    LockScreenView(lockManager: lockMgr)
                } else {
                    MainTabView()
                        .environmentObject(mesh)
                        .environmentObject(store)
                        .environmentObject(lockMgr)
                }
            }
            .preferredColorScheme(.dark)
            .onAppear {
                mesh.start()
                // Bridge incoming BLE messages → local store
                setupMessageBridge()
            }
        }
    }

    /// Bridges BluetoothMeshService.chatMessages → LocalStore so they persist.
    private func setupMessageBridge() {
        // Poll for new messages not yet in store.
        // In production, use Combine .sink on mesh.$chatMessages.
        Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { _ in
            for msg in mesh.chatMessages {
                let stored = StoredMessage(from: msg, channelID: "broadcast",
                                          myID: mesh.identity.deviceID)
                store.saveMessage(stored)
                // Record seen contact
                if !msg.isLocal {
                    store.recordSeen(deviceID: msg.senderID, nickname: msg.senderName, rssi: -70)
                }
            }
        }
    }
}

// MARK: - Main tab container

struct MainTabView: View {
    @EnvironmentObject var mesh: BluetoothMeshService
    @EnvironmentObject var lockMgr: AppLockManager
    @State private var selectedTab = 0

    var body: some View {
        ZStack(alignment: .bottom) {
            Color(hex: "#060809").ignoresSafeArea()

            TabView(selection: $selectedTab) {
                ChannelListView()
                    .tag(0)
                AlertFeedView()
                    .tag(1)
                MapTabView()
                    .tag(2)
                ProfileTabView()
                    .tag(3)
            }
            .tabViewStyle(.page(indexDisplayMode: .never))

            // Custom tab bar
            customTabBar
        }
        .ignoresSafeArea(edges: .bottom)
    }

    private var customTabBar: some View {
        HStack(spacing: 0) {
            tabItem(0, icon: "bubble.left.and.bubble.right", label: "Chats",
                    badge: LocalStore.shared.channels.reduce(0) { $0 + $1.unreadCount })
            tabItem(1, icon: "exclamationmark.triangle", label: "Alerts",
                    badge: LocalStore.shared.activeAlerts.count)
            tabItem(2, icon: "map", label: "Map", badge: 0)
            tabItem(3, icon: "person.circle", label: "You", badge: 0)
        }
        .background(Color(hex: "#060809"))
        .overlay(alignment: .top) { Divider().overlay(Color(hex: "#1e2d3d")) }
    }

    private func tabItem(_ tag: Int, icon: String, label: String, badge: Int) -> some View {
        Button { selectedTab = tag } label: {
            VStack(spacing: 3) {
                ZStack(alignment: .topTrailing) {
                    Image(systemName: icon)
                        .font(.system(size: 20))
                        .foregroundColor(selectedTab == tag ? Color(hex: "#00e5a0") : Color(hex: "#4a6580"))
                    if badge > 0 {
                        Text("\(min(badge, 99))")
                            .font(.custom("IBMPlexMono-Regular", size: 7))
                            .foregroundColor(Color(hex: "#060809"))
                            .padding(.horizontal, 3).padding(.vertical, 1)
                            .background(Color(hex: "#e53e3e"))
                            .clipShape(Capsule())
                            .offset(x: 8, y: -6)
                    }
                }
                Text(label)
                    .font(.custom("IBMPlexMono-Regular", size: 8))
                    .kerning(0.5)
                    .foregroundColor(selectedTab == tag ? Color(hex: "#00e5a0") : Color(hex: "#4a6580"))
            }
            .frame(maxWidth: .infinity)
            .padding(.top, 10).padding(.bottom, 20)
            .overlay(alignment: .top) {
                if selectedTab == tag {
                    Rectangle().fill(Color(hex: "#00e5a0")).frame(height: 1)
                        .padding(.horizontal, 24)
                }
            }
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Profile tab (enhanced)

struct ProfileTabView: View {
    @EnvironmentObject var mesh: BluetoothMeshService
    @EnvironmentObject var lockMgr: AppLockManager
    @ObservedObject private var store = LocalStore.shared
    @State private var nicknameEditor = ""
    @State private var showPINSetup = false
    @State private var showWipeConfirm = false

    var body: some View {
        NavigationStack {
            ZStack {
                Color(hex: "#060809").ignoresSafeArea()
                List {
                    // Identity section
                    Section {
                        HStack(spacing: 14) {
                            Circle().fill(Color(hex: "#0c1a14"))
                                .frame(width: 52, height: 52)
                                .overlay(
                                    Text(String(mesh.identity.nickname.prefix(2)).uppercased())
                                        .font(.custom("IBMPlexMono-Medium", size: 18))
                                        .foregroundColor(Color(hex: "#00e5a0"))
                                )
                            VStack(alignment: .leading, spacing: 3) {
                                Text(mesh.identity.nickname)
                                    .font(.custom("IBMPlexSans-Medium", size: 16))
                                    .foregroundColor(Color(hex: "#d4eaf5"))
                                Text(mesh.identity.deviceID.prefix(16) + "···")
                                    .font(.custom("IBMPlexMono-Regular", size: 9))
                                    .foregroundColor(Color(hex: "#2a3f52"))
                            }
                        }
                        .padding(.vertical, 4)

                        TextField("Callsign", text: $nicknameEditor)
                            .font(.custom("IBMPlexMono-Regular", size: 14))
                            .onSubmit { saveNickname() }
                            .onAppear { nicknameEditor = mesh.identity.nickname }

                        Button("Save callsign") { saveNickname() }
                            .foregroundColor(Color(hex: "#00e5a0"))
                            .font(.custom("IBMPlexMono-Regular", size: 13))
                    } header: {
                        Text("IDENTITY").font(.custom("IBMPlexMono-Regular", size: 9)).kerning(1.5)
                    }

                    // Privacy
                    Section {
                        Toggle("Share location with peers", isOn: Binding(
                            get: { mesh.identity.shareLocation },
                            set: { v in var id = mesh.identity; id.shareLocation = v; mesh.updateIdentity(id) }
                        ))
                        .tint(Color(hex: "#00e5a0"))
                        Text("Your coordinates are included in messages for distance display. Toggle off anytime.")
                            .font(.custom("IBMPlexMono-Regular", size: 10))
                            .foregroundColor(Color(hex: "#2a3f52"))
                    } header: {
                        Text("PRIVACY").font(.custom("IBMPlexMono-Regular", size: 9)).kerning(1.5)
                    }

                    // Security
                    Section {
                        Button { showPINSetup = true } label: {
                            HStack {
                                Label(lockMgr.hasPIN ? "Change PIN" : "Set PIN",
                                      systemImage: "lock.fill")
                                    .foregroundColor(Color(hex: "#d4eaf5"))
                                Spacer()
                                if lockMgr.hasPIN {
                                    Image(systemName: "checkmark.circle.fill")
                                        .foregroundColor(Color(hex: "#00e5a0"))
                                }
                            }
                        }
                        Toggle("Use \(lockMgr.biometryType == .faceID ? "Face ID" : "Touch ID")",
                               isOn: $lockMgr.useBiometrics)
                            .tint(Color(hex: "#00e5a0"))

                        Button(role: .destructive) { lockMgr.lock() } label: {
                            Label("Lock app now", systemImage: "lock.rotation")
                                .foregroundColor(Color(hex: "#f5a623"))
                        }
                    } header: {
                        Text("SECURITY").font(.custom("IBMPlexMono-Regular", size: 9)).kerning(1.5)
                    }

                    // Contacts
                    Section {
                        ForEach(store.contacts) { contact in
                            HStack {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(contact.displayName)
                                        .font(.custom("IBMPlexSans-Medium", size: 13))
                                        .foregroundColor(Color(hex: "#d4eaf5"))
                                    Text(contact.id.prefix(12) + "···")
                                        .font(.custom("IBMPlexMono-Regular", size: 9))
                                        .foregroundColor(Color(hex: "#2a3f52"))
                                }
                                Spacer()
                                TrustPill(score: contact.trustScore(myContacts: store.contacts))
                                if !contact.isFriend {
                                    Button {
                                        store.addFriend(deviceID: contact.id)
                                    } label: {
                                        Image(systemName: "person.badge.plus")
                                            .foregroundColor(Color(hex: "#00e5a0"))
                                    }
                                } else {
                                    Image(systemName: "checkmark.circle.fill")
                                        .foregroundColor(Color(hex: "#00e5a0"))
                                }
                            }
                        }
                        if store.contacts.isEmpty {
                            Text("No contacts yet. Contacts appear when peers are seen via Bluetooth.")
                                .font(.custom("IBMPlexMono-Regular", size: 10))
                                .foregroundColor(Color(hex: "#2a3f52"))
                        }
                    } header: {
                        Text("CONTACTS (\(store.contacts.count))")
                            .font(.custom("IBMPlexMono-Regular", size: 9)).kerning(1.5)
                    }

                    // Danger zone
                    Section {
                        Button(role: .destructive) { showWipeConfirm = true } label: {
                            Label("Panic wipe — erase all data", systemImage: "exclamationmark.triangle.fill")
                                .foregroundColor(Color(hex: "#e53e3e"))
                                .font(.custom("IBMPlexMono-Regular", size: 13))
                        }
                    } header: {
                        Text("DANGER").font(.custom("IBMPlexMono-Regular", size: 9))
                            .foregroundColor(Color(hex: "#e53e3e")).kerning(1.5)
                    }
                }
                .scrollContentBackground(.hidden)
                .background(Color(hex: "#060809"))
            }
            .navigationTitle("")
            .navigationBarHidden(true)
        }
        .sheet(isPresented: $showPINSetup) {
            PINSetupView(lockManager: lockMgr) { showPINSetup = false }
        }
        .confirmationDialog("Wipe all messages, alerts, and contacts?",
                            isPresented: $showWipeConfirm, titleVisibility: .visible) {
            Button("Wipe everything", role: .destructive) {
                store.wipeAll()
                lockMgr.removePIN()
            }
            Button("Cancel", role: .cancel) {}
        }
    }

    private func saveNickname() {
        let trimmed = nicknameEditor.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        var id = mesh.identity
        id.nickname = trimmed
        mesh.updateIdentity(id)
    }
}