import SwiftUI

struct ContentView: View {
    @EnvironmentObject var mesh: BluetoothMeshService
    @AppStorage("hasCompletedOnboarding") private var hasCompletedOnboarding = false

    var body: some View {
        Group {
            if !hasCompletedOnboarding {
                OnboardingView(hasCompletedOnboarding: $hasCompletedOnboarding)
            } else {
                MainTabView()
            }
        }
        .onAppear {
            mesh.syncScanTimingFromUI()
            applyGlobalAppearance()
        }
    }

    private func applyGlobalAppearance() {
        let tabAppearance = UITabBarAppearance()
        tabAppearance.configureWithOpaqueBackground()
        tabAppearance.backgroundColor = UIColor.systemBackground
        tabAppearance.shadowColor = UIColor.separator
        UITabBar.appearance().standardAppearance = tabAppearance
        UITabBar.appearance().scrollEdgeAppearance = tabAppearance

        let navAppearance = UINavigationBarAppearance()
        navAppearance.configureWithOpaqueBackground()
        navAppearance.backgroundColor = UIColor.systemBackground
        navAppearance.shadowColor = UIColor.separator
        navAppearance.titleTextAttributes = [.foregroundColor: UIColor.label]
        navAppearance.largeTitleTextAttributes = [.foregroundColor: UIColor.label]
        UINavigationBar.appearance().standardAppearance = navAppearance
        UINavigationBar.appearance().scrollEdgeAppearance = navAppearance
    }
}

// MARK: - Onboarding

struct OnboardingView: View {
    @Binding var hasCompletedOnboarding: Bool
    @EnvironmentObject var mesh: BluetoothMeshService
    @State private var currentPage = 0
    @State private var nickname = ""

    private let pages: [OnboardingPage] = [
        OnboardingPage(
            icon: "antenna.radiowaves.left.and.right",
            title: "Mesh Communication",
            body: "MeshMap works without internet or cell service. Messages travel peer-to-peer over Bluetooth, hopping between nearby devices."
        ),
        OnboardingPage(
            icon: "map",
            title: "Alert the Network",
            body: "Place geo-tagged alerts directly on the map. Others can verify events with comments and votes, building a real-time picture of the ground situation."
        ),
        OnboardingPage(
            icon: "lock.shield",
            title: "Privacy First",
            body: "Location sharing is opt-in. Your device ID is generated locally and never leaves the mesh. No accounts, no servers, no tracking."
        )
    ]

    var body: some View {
        ZStack {
            Color(.systemBackground).ignoresSafeArea()

            VStack(spacing: 0) {
                Spacer()

                // Page content
                TabView(selection: $currentPage) {
                    ForEach(Array(pages.enumerated()), id: \.offset) { index, page in
                        pageView(page)
                            .tag(index)
                    }
                    nicknameSetupPage
                        .tag(pages.count)
                }
                .tabViewStyle(.page(indexDisplayMode: .never))
                .animation(.easeInOut, value: currentPage)

                Spacer()

                // Page dots
                HStack(spacing: 6) {
                    ForEach(0..<pages.count + 1, id: \.self) { i in
                        Capsule()
                            .fill(i == currentPage ? Color.primary : Color(.systemGray4))
                            .frame(width: i == currentPage ? 20 : 6, height: 6)
                            .animation(.spring(response: 0.3), value: currentPage)
                    }
                }
                .padding(.bottom, 32)

                // Action button
                Button {
                    if currentPage < pages.count {
                        withAnimation { currentPage += 1 }
                    } else {
                        finishOnboarding()
                    }
                } label: {
                    Text(currentPage < pages.count ? "Continue" : "Get Started")
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundStyle(.white)
                        .frame(maxWidth: .infinity)
                        .frame(height: 54)
                        .background(
                            RoundedRectangle(cornerRadius: 14, style: .continuous)
                                .fill(Color.primary)
                        )
                }
                .padding(.horizontal, 24)
                .padding(.bottom, 48)
                .disabled(currentPage == pages.count && nickname.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
    }

    private func pageView(_ page: OnboardingPage) -> some View {
        VStack(spacing: 24) {
            Image(systemName: page.icon)
                .font(.system(size: 52, weight: .light))
                .foregroundStyle(Color.primary)
                .frame(width: 96, height: 96)
                .background(
                    RoundedRectangle(cornerRadius: 22, style: .continuous)
                        .fill(Color(.systemGray6))
                )
            VStack(spacing: 12) {
                Text(page.title)
                    .font(.system(size: 26, weight: .semibold))
                    .multilineTextAlignment(.center)
                Text(page.body)
                    .font(.system(size: 16))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .lineSpacing(3)
                    .padding(.horizontal, 8)
            }
        }
        .padding(.horizontal, 32)
    }

    private var nicknameSetupPage: some View {
        VStack(spacing: 24) {
            Image(systemName: "person.circle")
                .font(.system(size: 52, weight: .light))
                .foregroundStyle(Color.primary)
                .frame(width: 96, height: 96)
                .background(
                    RoundedRectangle(cornerRadius: 22, style: .continuous)
                        .fill(Color(.systemGray6))
                )
            VStack(spacing: 12) {
                Text("Choose a Callsign")
                    .font(.system(size: 26, weight: .semibold))
                Text("This is how others on the mesh will identify you. It does not need to be your real name.")
                    .font(.system(size: 16))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .lineSpacing(3)
                    .padding(.horizontal, 8)
            }
            TextField("e.g. Delta-7 or Rania", text: $nickname)
                .font(.system(size: 17))
                .padding(14)
                .background(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(Color(.systemGray6))
                )
                .padding(.horizontal, 24)
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)
                .onAppear {
                    nickname = mesh.identity.nickname
                }
        }
        .padding(.horizontal, 32)
    }

    private func finishOnboarding() {
        let name = nickname.trimmingCharacters(in: .whitespacesAndNewlines)
        if !name.isEmpty {
            var id = mesh.identity
            id.nickname = name
            mesh.updateIdentity(id)
        }
        withAnimation { hasCompletedOnboarding = true }
    }
}

private struct OnboardingPage {
    let icon: String
    let title: String
    let body: String
}

// MARK: - Main Tab View

private struct MainTabView: View {
    @EnvironmentObject var mesh: BluetoothMeshService

    var body: some View {
        TabView {
            ChatView()
                .tabItem { Label("Chat", systemImage: "bubble.left.and.bubble.right") }
            MapTabView()
                .tabItem { Label("Map", systemImage: "map") }
            DebugDashboardView()
                .tabItem { Label("Network", systemImage: "antenna.radiowaves.left.and.right") }
            ProfileView()
                .tabItem { Label("Profile", systemImage: "person.circle") }
        }
        .tint(.primary)
    }
}

// MARK: - Profile

struct ProfileView: View {
    @EnvironmentObject var mesh: BluetoothMeshService
    @State private var nicknameEditor = ""
    @State private var isSaved = false

    var body: some View {
        NavigationStack {
            List {
                Section {
                    HStack(spacing: 14) {
                        ZStack {
                            Circle()
                                .fill(Color(.systemGray6))
                                .frame(width: 58, height: 58)
                            Text(String(mesh.identity.nickname.prefix(1)).uppercased())
                                .font(.system(size: 22, weight: .semibold))
                                .foregroundStyle(.primary)
                        }
                        VStack(alignment: .leading, spacing: 3) {
                            Text(mesh.identity.nickname)
                                .font(.headline)
                            Text("Mesh Node")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                    }
                    .padding(.vertical, 6)
                }

                Section("Identity") {
                    HStack(spacing: 12) {
                        Image(systemName: "person")
                            .foregroundStyle(.secondary)
                            .frame(width: 20)
                        TextField("Callsign", text: $nicknameEditor)
                            .autocorrectionDisabled()
                    }
                    Button {
                        guard !nicknameEditor.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
                        var id = mesh.identity
                        id.nickname = nicknameEditor.trimmingCharacters(in: .whitespacesAndNewlines)
                        mesh.updateIdentity(id)
                        isSaved = true
                        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { isSaved = false }
                    } label: {
                        HStack(spacing: 12) {
                            Image(systemName: isSaved ? "checkmark.circle" : "square.and.arrow.down")
                                .foregroundStyle(isSaved ? .green : .accentColor)
                                .frame(width: 20)
                            Text(isSaved ? "Saved" : "Save Callsign")
                                .foregroundStyle(isSaved ? .green : .accentColor)
                        }
                    }
                    HStack(spacing: 12) {
                        Image(systemName: "number")
                            .foregroundStyle(.secondary)
                            .frame(width: 20)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Device ID")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            Text(mesh.identity.deviceID)
                                .font(.system(.caption, design: .monospaced))
                                .textSelection(.enabled)
                        }
                    }
                    .padding(.vertical, 2)
                }

                Section("Privacy") {
                    HStack(spacing: 12) {
                        Image(systemName: "location")
                            .foregroundStyle(.secondary)
                            .frame(width: 20)
                        Toggle("Share Location with Peers", isOn: Binding(
                            get: { mesh.identity.shareLocation },
                            set: { v in
                                var id = mesh.identity
                                id.shareLocation = v
                                mesh.updateIdentity(id)
                            }
                        ))
                        .tint(.primary)
                    }
                    Text("When enabled, your approximate coordinates are broadcast so nearby peers can see distance. You can disable this at any time.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Section("About") {
                    HStack(spacing: 12) {
                        Image(systemName: "info.circle")
                            .foregroundStyle(.secondary)
                            .frame(width: 20)
                        Text("Messages are relayed over Bluetooth and do not require internet. Keep the app in the foreground for best results.")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 4)
                }
            }
            .navigationTitle("Profile")
            .onAppear { nicknameEditor = mesh.identity.nickname }
        }
    }
}

#Preview {
    ContentView()
        .environmentObject(BluetoothMeshService())
}
