import SwiftUI

// MARK: - Colour Palette

extension Color {
    static let meshAccent   = Color(red: 0.91, green: 0.35, blue: 0.24) // #E8593C — primary action / hazard
    static let meshSuccess  = Color(red: 0.11, green: 0.62, blue: 0.46) // #1D9E75 — linked / safe / medical
    static let meshWarn     = Color(red: 0.73, green: 0.46, blue: 0.09) // #BA7517 — caution / checkpoint
    static let meshInfo     = Color(red: 0.09, green: 0.37, blue: 0.65) // #185FA5 — peers / info
    static let mapBackground = Color(red: 0.10, green: 0.14, blue: 0.19) // dark map canvas
}

// MARK: - Shared Badges

struct MeshBadge: View {
    enum Style { case success, warn, danger, info, neutral }
    let text: String
    let style: Style
    
    var body: some View {
        Text(text)
            .font(.system(.caption, design: .monospaced))
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(backgroundColor)
            .foregroundColor(.white)
            .cornerRadius(8)
    }
    
    private var backgroundColor: Color {
        switch style {
        case .success: return .meshSuccess
        case .warn:    return .meshWarn
        case .danger:  return .meshAccent
        case .info:    return .meshInfo
        case .neutral: return .gray
        }
    }
}

struct TrustBadge: View {
    let score: Double // 0.0–1.0
    
    var body: some View {
        Text("TRUST \(Int(score * 100))%")
            .font(.system(.caption, design: .monospaced))
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(backgroundColor)
            .foregroundColor(.white)
            .cornerRadius(8)
    }
    
    private var backgroundColor: Color {
        if score >= 0.80 { return .meshSuccess }
        if score >= 0.55 { return .meshWarn }
        return .meshAccent
    }
}

struct TTLBadge: View {
    let expiresAt: Date
    
    var body: some View {
        let remaining = expiresAt.timeIntervalSince(Date())
        let minutes = max(0, Int(remaining / 60))
        
        Text("\(minutes)m TTL")
            .font(.system(.caption, design: .monospaced))
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(minutes < 5 ? Color.meshAccent : Color.gray.opacity(0.5))
            .foregroundColor(.white)
            .cornerRadius(8)
    }
}

struct HopIndicator: View {
    let hops: Int      // 1–5
    let maxHops: Int   // typically 5
    
    var body: some View {
        HStack(spacing: 2) {
            ForEach(0..<maxHops, id: \.self) { i in
                Circle()
                    .fill(i < hops ? Color.meshInfo : Color.gray.opacity(0.3))
                    .frame(width: 6, height: 6)
            }
        }
    }
}
