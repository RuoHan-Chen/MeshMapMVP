
import SwiftUI
import LocalAuthentication
 
// MARK: - App lock manager
 
final class AppLockManager: ObservableObject {
    @Published var isUnlocked: Bool = false
    @Published var useBiometrics: Bool {
        didSet { UserDefaults.standard.set(useBiometrics, forKey: "lock.biometrics") }
    }
    @Published var hasPIN: Bool = false
 
    private let pinKey = "meshchat.pin.hash"
 
    init() {
        useBiometrics = UserDefaults.standard.bool(forKey: "lock.biometrics")
        hasPIN = UserDefaults.standard.string(forKey: pinKey) != nil
        // Auto-unlock if no lock set
        if !hasPIN && !useBiometrics { isUnlocked = true }
    }
 
    var biometryType: LABiometryType {
        let ctx = LAContext()
        _ = ctx.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: nil)
        return ctx.biometryType
    }
 
    func setPIN(_ pin: String) {
        guard pin.count >= 4 else { return }
        let hash = pin.data(using: .utf8)!.sha256hex
        UserDefaults.standard.set(hash, forKey: pinKey)
        hasPIN = true
    }
 
    func removePIN() {
        UserDefaults.standard.removeObject(forKey: pinKey)
        hasPIN = false
    }
 
    func checkPIN(_ pin: String) -> Bool {
        guard let stored = UserDefaults.standard.string(forKey: pinKey) else { return false }
        let hash = pin.data(using: .utf8)!.sha256hex
        return hash == stored
    }
 
    func authenticateWithBiometrics(reason: String = "Unlock MeshNet") {
        let ctx = LAContext()
        var err: NSError?
        guard ctx.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: &err) else {
            return
        }
        ctx.evaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, localizedReason: reason) { [weak self] success, _ in
            DispatchQueue.main.async {
                if success { self?.isUnlocked = true }
            }
        }
    }
 
    func lock() { isUnlocked = false }
}
 
// MARK: - SHA256 helper
 
import CryptoKit
extension Data {
    var sha256hex: String {
        SHA256.hash(data: self).compactMap { String(format: "%02x", $0) }.joined()
    }
}
 
// MARK: - Lock screen view
 
struct LockScreenView: View {
    @ObservedObject var lockManager: AppLockManager
    @State private var pin = ""
    @State private var shake = false
    @State private var attempts = 0
    @State private var errorMsg = ""
 
    private let maxDigits = 6
 
    var body: some View {
        ZStack {
            Color(hex: "#060809").ignoresSafeArea()
 
            VStack(spacing: 40) {
                Spacer()
 
                // Logo
                VStack(spacing: 6) {
                    Image(systemName: "lock.shield.fill")
                        .font(.system(size: 48))
                        .foregroundColor(Color(hex: "#00e5a0"))
                    Text("MESHNET")
                        .font(.custom("IBMPlexMono-SemiBold", size: 22))
                        .foregroundColor(Color(hex: "#d4eaf5"))
                        .kerning(2)
                }
 
                // PIN dots
                HStack(spacing: 16) {
                    ForEach(0..<maxDigits, id: \.self) { i in
                        Circle()
                            .fill(i < pin.count
                                  ? Color(hex: "#00e5a0")
                                  : Color(hex: "#1e2d3d"))
                            .frame(width: 14, height: 14)
                            .overlay(
                                Circle().stroke(Color(hex: "#2a3f52"), lineWidth: 1)
                            )
                    }
                }
                .offset(x: shake ? -10 : 0)
                .animation(shake ? .easeInOut(duration: 0.05).repeatCount(5, autoreverses: true) : .default, value: shake)
 
                if !errorMsg.isEmpty {
                    Text(errorMsg)
                        .font(.custom("IBMPlexMono-Regular", size: 11))
                        .foregroundColor(Color(hex: "#e53e3e"))
                        .kerning(0.5)
                }
 
                // Numpad
                numpad
 
                // Biometrics button
                if lockManager.useBiometrics {
                    Button {
                        lockManager.authenticateWithBiometrics()
                    } label: {
                        HStack(spacing: 6) {
                            Image(systemName: lockManager.biometryType == .faceID
                                  ? "faceid" : "touchid")
                                .font(.system(size: 22))
                            Text(lockManager.biometryType == .faceID ? "Face ID" : "Touch ID")
                                .font(.custom("IBMPlexMono-Regular", size: 13))
                        }
                        .foregroundColor(Color(hex: "#00e5a0"))
                    }
                    .onAppear { lockManager.authenticateWithBiometrics() }
                }
 
                Spacer()
            }
        }
    }
 
    private var numpad: some View {
        VStack(spacing: 12) {
            ForEach([[1,2,3],[4,5,6],[7,8,9],[0]], id: \.self) { row in
                HStack(spacing: 20) {
                    ForEach(row, id: \.self) { digit in
                        if digit == 0 {
                            // Delete button takes place of leading blank
                            Color.clear.frame(width: 72, height: 72)
                            numKey(digit)
                            deleteKey
                        } else {
                            numKey(digit)
                        }
                    }
                }
            }
        }
    }
 
    private func numKey(_ digit: Int) -> some View {
        Button {
            guard pin.count < maxDigits else { return }
            pin.append(String(digit))
            if pin.count == maxDigits { verify() }
        } label: {
            Text("\(digit)")
                .font(.custom("IBMPlexMono-Regular", size: 24))
                .foregroundColor(Color(hex: "#d4eaf5"))
                .frame(width: 72, height: 72)
                .background(Color(hex: "#111820"))
                .clipShape(Circle())
                .overlay(Circle().stroke(Color(hex: "#1e2d3d"), lineWidth: 0.5))
        }
    }
 
    private var deleteKey: some View {
        Button {
            if !pin.isEmpty { pin.removeLast() }
        } label: {
            Image(systemName: "delete.left")
                .font(.system(size: 20))
                .foregroundColor(Color(hex: "#4a6580"))
                .frame(width: 72, height: 72)
        }
    }
 
    private func verify() {
        if lockManager.checkPIN(pin) {
            lockManager.isUnlocked = true
        } else {
            attempts += 1
            errorMsg = attempts >= 3 ? "Too many attempts. Wait." : "Incorrect PIN"
            shake = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { shake = false }
            pin = ""
        }
    }
}
 
// MARK: - PIN setup view (used in onboarding and settings)
 
struct PINSetupView: View {
    @ObservedObject var lockManager: AppLockManager
    var onComplete: () -> Void
 
    @State private var step: Step = .choose
    @State private var firstPIN = ""
    @State private var pin = ""
    @State private var errorMsg = ""
    @State private var shake = false
 
    enum Step { case choose, enter, confirm }
 
    var body: some View {
        ZStack {
            Color(hex: "#060809").ignoresSafeArea()
            VStack(spacing: 36) {
                Spacer()
 
                VStack(spacing: 8) {
                    Text(stepTitle)
                        .font(.custom("IBMPlexMono-SemiBold", size: 16))
                        .foregroundColor(Color(hex: "#d4eaf5"))
                    Text(stepSubtitle)
                        .font(.custom("IBMPlexMono-Regular", size: 11))
                        .foregroundColor(Color(hex: "#4a6580"))
                        .kerning(0.5)
                }
 
                if step == .choose {
                    choiceButtons
                } else {
                    pinEntry
                }
 
                if !errorMsg.isEmpty {
                    Text(errorMsg)
                        .font(.custom("IBMPlexMono-Regular", size: 11))
                        .foregroundColor(Color(hex: "#e53e3e"))
                }
 
                Spacer()
 
                Button("Skip for now") { onComplete() }
                    .font(.custom("IBMPlexMono-Regular", size: 12))
                    .foregroundColor(Color(hex: "#2a3f52"))
                    .padding(.bottom, 32)
            }
        }
    }
 
    private var stepTitle: String {
        switch step {
        case .choose:  return "SECURE YOUR APP"
        case .enter:   return "SET A PIN"
        case .confirm: return "CONFIRM PIN"
        }
    }
 
    private var stepSubtitle: String {
        switch step {
        case .choose:  return "Choose how to protect access"
        case .enter:   return "Enter a 4–6 digit PIN"
        case .confirm: return "Re-enter your PIN to confirm"
        }
    }
 
    private var choiceButtons: some View {
        VStack(spacing: 12) {
            choiceBtn(icon: "lock.fill", label: "Set a PIN",
                      sub: "4–6 digits, always available") { step = .enter }
 
            if lockManager.biometryType != .none {
                let bioLabel = lockManager.biometryType == .faceID ? "Face ID" : "Touch ID"
                choiceBtn(icon: lockManager.biometryType == .faceID ? "faceid" : "touchid",
                          label: bioLabel,
                          sub: "Fast unlock using biometrics") {
                    lockManager.useBiometrics = true
                    lockManager.isUnlocked = true
                    onComplete()
                }
            }
 
            choiceBtn(icon: "lock.open", label: "No lock",
                      sub: "Not recommended") {
                onComplete()
            }
        }
        .padding(.horizontal, 32)
    }
 
    private func choiceBtn(icon: String, label: String, sub: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 14) {
                Image(systemName: icon)
                    .font(.system(size: 20))
                    .foregroundColor(Color(hex: "#00e5a0"))
                    .frame(width: 36)
                VStack(alignment: .leading, spacing: 2) {
                    Text(label)
                        .font(.custom("IBMPlexMono-Medium", size: 13))
                        .foregroundColor(Color(hex: "#d4eaf5"))
                    Text(sub)
                        .font(.custom("IBMPlexMono-Regular", size: 10))
                        .foregroundColor(Color(hex: "#4a6580"))
                }
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.system(size: 12))
                    .foregroundColor(Color(hex: "#2a3f52"))
            }
            .padding(14)
            .background(Color(hex: "#0c1014"))
            .cornerRadius(10)
            .overlay(RoundedRectangle(cornerRadius: 10)
                .stroke(Color(hex: "#1e2d3d"), lineWidth: 0.5))
        }
        .buttonStyle(.plain)
    }
 
    private var pinEntry: some View {
        VStack(spacing: 32) {
            // Dots
            HStack(spacing: 14) {
                ForEach(0..<6, id: \.self) { i in
                    Circle()
                        .fill(i < pin.count ? Color(hex: "#00e5a0") : Color(hex: "#1e2d3d"))
                        .frame(width: 14, height: 14)
                        .overlay(Circle().stroke(Color(hex: "#2a3f52"), lineWidth: 0.8))
                }
            }
            .offset(x: shake ? -8 : 0)
            .animation(shake ? .easeInOut(duration: 0.05).repeatCount(5, autoreverses: true) : .default, value: shake)
 
            // Numpad
            VStack(spacing: 10) {
                ForEach([[1,2,3],[4,5,6],[7,8,9]], id: \.self) { row in
                    HStack(spacing: 16) {
                        ForEach(row, id: \.self) { d in pinKey(d) }
                    }
                }
                HStack(spacing: 16) {
                    Color.clear.frame(width: 68, height: 68)
                    pinKey(0)
                    Button {
                        if !pin.isEmpty { pin.removeLast() }
                    } label: {
                        Image(systemName: "delete.left")
                            .font(.system(size: 18))
                            .foregroundColor(Color(hex: "#4a6580"))
                            .frame(width: 68, height: 68)
                    }
                }
            }
        }
    }
 
    private func pinKey(_ digit: Int) -> some View {
        Button {
            guard pin.count < 6 else { return }
            pin.append(String(digit))
            if pin.count >= 4 {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { advance() }
            }
        } label: {
            Text("\(digit)")
                .font(.custom("IBMPlexMono-Regular", size: 22))
                .foregroundColor(Color(hex: "#d4eaf5"))
                .frame(width: 68, height: 68)
                .background(Color(hex: "#111820"))
                .clipShape(Circle())
                .overlay(Circle().stroke(Color(hex: "#1e2d3d"), lineWidth: 0.5))
        }
    }
 
    private func advance() {
        switch step {
        case .choose: break
        case .enter:
            firstPIN = pin
            pin = ""
            errorMsg = ""
            step = .confirm
        case .confirm:
            if pin == firstPIN {
                lockManager.setPIN(pin)
                lockManager.isUnlocked = true
                onComplete()
            } else {
                errorMsg = "PINs don't match — try again"
                shake = true
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { shake = false }
                pin = ""
                firstPIN = ""
                step = .enter
            }
        }
    }
}
 