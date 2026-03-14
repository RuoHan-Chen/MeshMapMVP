import SwiftUI
 
struct OnboardingFlow: View {
    @EnvironmentObject var mesh: BluetoothMeshService
    @ObservedObject var lockManager: AppLockManager
    var onFinish: () -> Void
 
    @State private var page = 0
    @State private var callsign = ""
    @State private var shareLocation = true
    @State private var showPINSetup = false
 
    var body: some View {
        ZStack {
            Color(hex: "#060809").ignoresSafeArea()
 
            if showPINSetup {
                PINSetupView(lockManager: lockManager) {
                    finalise()
                }
                .transition(.move(edge: .trailing))
            } else {
                TabView(selection: $page) {
                    welcomePage.tag(0)
                    callsignPage.tag(1)
                    locationPage.tag(2)
                    trustPage.tag(3)
                }
                .tabViewStyle(.page(indexDisplayMode: .never))
                .animation(.easeInOut, value: page)
 
                // Page dots + next button
                VStack {
                    Spacer()
                    HStack {
                        pageDots
                        Spacer()
                        nextButton
                    }
                    .padding(.horizontal, 32)
                    .padding(.bottom, 48)
                }
            }
        }
    }
 
    // MARK: - Pages
 
    private var welcomePage: some View {
        VStack(spacing: 0) {
            Spacer()
            ZStack {
                ForEach(0..<4, id: \.self) { i in
                    Circle()
                        .stroke(Color(hex: "#00e5a0").opacity(0.2 - Double(i) * 0.04), lineWidth: 0.8)
                        .frame(width: CGFloat(40 + i * 30), height: CGFloat(40 + i * 30))
                        .scaleEffect(1)
                }
                Circle()
                    .fill(Color(hex: "#00e5a0"))
                    .frame(width: 16, height: 16)
                    .shadow(color: Color(hex: "#00e5a0").opacity(0.6), radius: 10)
            }
            .frame(height: 160)
 
            Spacer().frame(height: 40)
 
            Text("MESHNET")
                .font(.custom("IBMPlexMono-SemiBold", size: 30))
                .foregroundColor(Color(hex: "#00e5a0"))
                .kerning(3)
 
            Spacer().frame(height: 12)
 
            Text("Communicate without\ntowers, servers, or internet.")
                .font(.custom("IBMPlexSans-Regular", size: 17))
                .foregroundColor(Color(hex: "#a8c4d8"))
                .multilineTextAlignment(.center)
                .lineSpacing(4)
 
            Spacer().frame(height: 32)
 
            VStack(spacing: 12) {
                featurePill("bubble.left.and.bubble.right", "Group, direct & public messaging")
                featurePill("exclamationmark.triangle",     "Signed alerts with local trust scores")
                featurePill("map",                          "Live mesh map with fog of war")
                featurePill("lock.shield",                  "PIN or biometric app lock")
            }
            .padding(.horizontal, 32)
 
            Spacer()
        }
    }
 
    private var callsignPage: some View {
        VStack(spacing: 0) {
            Spacer()
 
            Image(systemName: "person.crop.circle.badge.plus")
                .font(.system(size: 52))
                .foregroundColor(Color(hex: "#00e5a0"))
 
            Spacer().frame(height: 28)
 
            Text("YOUR CALLSIGN")
                .font(.custom("IBMPlexMono-SemiBold", size: 14))
                .foregroundColor(Color(hex: "#d4eaf5"))
                .kerning(2)
 
            Spacer().frame(height: 8)
 
            Text("This is how others see you on the mesh.\nYou can change it anytime in Profile.")
                .font(.custom("IBMPlexSans-Regular", size: 14))
                .foregroundColor(Color(hex: "#4a6580"))
                .multilineTextAlignment(.center)
                .lineSpacing(3)
                .padding(.horizontal, 32)
 
            Spacer().frame(height: 32)
 
            TextField("", text: $callsign)
                .font(.custom("IBMPlexMono-Regular", size: 18))
                .foregroundColor(Color(hex: "#d4eaf5"))
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)
                .multilineTextAlignment(.center)
                .padding(.vertical, 14)
                .background(Color(hex: "#111820"))
                .cornerRadius(10)
                .overlay(RoundedRectangle(cornerRadius: 10)
                    .stroke(callsign.isEmpty ? Color(hex: "#1e2d3d") : Color(hex: "#00e5a0").opacity(0.5), lineWidth: 0.8))
                .padding(.horizontal, 40)
                .placeholder(when: callsign.isEmpty) {
                    Text("e.g. sparrow_7")
                        .font(.custom("IBMPlexMono-Regular", size: 18))
                        .foregroundColor(Color(hex: "#2a3f52"))
                }
 
            Spacer().frame(height: 16)
 
            // Auto-generated key preview
            HStack(spacing: 6) {
                Image(systemName: "key.fill")
                    .font(.system(size: 10))
                Text("KEY·ID: \(String(mesh.identity.deviceID.prefix(16)))···")
                    .font(.custom("IBMPlexMono-Regular", size: 10))
            }
            .foregroundColor(Color(hex: "#2a3f52"))
 
            Spacer()
        }
    }
 
    private var locationPage: some View {
        VStack(spacing: 0) {
            Spacer()
 
            Image(systemName: shareLocation ? "location.fill" : "location.slash")
                .font(.system(size: 52))
                .foregroundColor(shareLocation ? Color(hex: "#00e5a0") : Color(hex: "#4a6580"))
                .animation(.easeInOut, value: shareLocation)
 
            Spacer().frame(height: 28)
 
            Text("LOCATION SHARING")
                .font(.custom("IBMPlexMono-SemiBold", size: 14))
                .foregroundColor(Color(hex: "#d4eaf5"))
                .kerning(2)
 
            Spacer().frame(height: 8)
 
            Text("When on, your approximate location is included in messages so peers can see distance. You control this — it can be toggled anytime.")
                .font(.custom("IBMPlexSans-Regular", size: 14))
                .foregroundColor(Color(hex: "#4a6580"))
                .multilineTextAlignment(.center)
                .lineSpacing(3)
                .padding(.horizontal, 32)
 
            Spacer().frame(height: 36)
 
            Toggle("Share my location", isOn: $shareLocation)
                .font(.custom("IBMPlexSans-Regular", size: 15))
                .foregroundColor(Color(hex: "#a8c4d8"))
                .tint(Color(hex: "#00e5a0"))
                .padding(.horizontal, 40)
 
            Spacer()
        }
    }
 
    private var trustPage: some View {
        VStack(spacing: 0) {
            Spacer()
 
            Image(systemName: "person.2.fill")
                .font(.system(size: 52))
                .foregroundColor(Color(hex: "#00e5a0"))
 
            Spacer().frame(height: 28)
 
            Text("HOW TRUST WORKS")
                .font(.custom("IBMPlexMono-SemiBold", size: 14))
                .foregroundColor(Color(hex: "#d4eaf5"))
                .kerning(2)
 
            Spacer().frame(height: 8)
 
            Text("Trust is based on proximity — people you've physically met and added as contacts score highest.")
                .font(.custom("IBMPlexSans-Regular", size: 14))
                .foregroundColor(Color(hex: "#4a6580"))
                .multilineTextAlignment(.center)
                .lineSpacing(3)
                .padding(.horizontal, 32)
 
            Spacer().frame(height: 32)
 
            VStack(spacing: 10) {
                trustRow("Direct contact (you added)", score: 1.0, color: "#00e5a0")
                trustRow("Seen directly via BLE", score: 0.6, color: "#00b87a")
                trustRow("Friend of a friend", score: 0.35, color: "#f5a623")
                trustRow("Unknown / never seen", score: 0.1, color: "#e53e3e")
            }
            .padding(.horizontal, 32)
 
            Spacer()
        }
    }
 
    // MARK: - Sub-components
 
    private func featurePill(_ icon: String, _ label: String) -> some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 15))
                .foregroundColor(Color(hex: "#00e5a0"))
                .frame(width: 28)
            Text(label)
                .font(.custom("IBMPlexSans-Regular", size: 14))
                .foregroundColor(Color(hex: "#a8c4d8"))
            Spacer()
        }
        .padding(.vertical, 10)
        .padding(.horizontal, 16)
        .background(Color(hex: "#0c1014"))
        .cornerRadius(8)
        .overlay(RoundedRectangle(cornerRadius: 8)
            .stroke(Color(hex: "#1e2d3d"), lineWidth: 0.5))
    }
 
    private func trustRow(_ label: String, score: Double, color: String) -> some View {
        HStack(spacing: 10) {
            Text(label)
                .font(.custom("IBMPlexMono-Regular", size: 11))
                .foregroundColor(Color(hex: "#a8c4d8"))
            Spacer()
            // Mini bar
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: 2)
                    .fill(Color(hex: "#1e2d3d"))
                    .frame(width: 60, height: 4)
                RoundedRectangle(cornerRadius: 2)
                    .fill(Color(hex: color))
                    .frame(width: 60 * score, height: 4)
            }
            Text(String(format: "%.0f%%", score * 100))
                .font(.custom("IBMPlexMono-Regular", size: 10))
                .foregroundColor(Color(hex: color))
                .frame(width: 32, alignment: .trailing)
        }
    }
 
    private var pageDots: some View {
        HStack(spacing: 6) {
            ForEach(0..<4, id: \.self) { i in
                Circle()
                    .fill(i == page ? Color(hex: "#00e5a0") : Color(hex: "#2a3f52"))
                    .frame(width: i == page ? 8 : 6, height: i == page ? 8 : 6)
                    .animation(.easeInOut, value: page)
            }
        }
    }
 
    private var nextButton: some View {
        Button {
            if page < 3 {
                withAnimation { page += 1 }
            } else {
                applySettings()
                withAnimation { showPINSetup = true }
            }
        } label: {
            HStack(spacing: 6) {
                Text(page == 3 ? "SECURE →" : "NEXT →")
                    .font(.custom("IBMPlexMono-Medium", size: 12))
                    .kerning(1)
            }
            .foregroundColor(Color(hex: "#060809"))
            .padding(.horizontal, 24)
            .padding(.vertical, 12)
            .background(
                (page == 1 && callsign.isEmpty)
                ? Color(hex: "#2a3f52")
                : Color(hex: "#00e5a0")
            )
            .cornerRadius(20)
        }
        .disabled(page == 1 && callsign.isEmpty)
    }
 
    private func applySettings() {
        var id = mesh.identity
        if !callsign.isEmpty { id.nickname = callsign }
        id.shareLocation = shareLocation
        mesh.updateIdentity(id)
    }
 
    private func finalise() {
        UserDefaults.standard.set(true, forKey: "onboarding.complete")
        onFinish()
    }
}
 
extension View {
    func placeholder<C: View>(when show: Bool, @ViewBuilder placeholder: () -> C) -> some View {
        ZStack(alignment: .center) {
            if show { placeholder() }
            self
        }
    }
}