import SwiftUI

struct MeshStatusBar: View {
    @EnvironmentObject var mesh: BluetoothMeshService
    @State private var pulseScale: CGFloat = 1.0
    @State private var pulseOpacity: Double = 1.0

    var body: some View {
        HStack {
            // Left side: animated pulse dot + peer count + link state text
            HStack(spacing: 6) {
                if mesh.isScanning && mesh.readyRemoteCount == 0 {
                    Circle()
                        .fill(Color.meshWarn)
                        .frame(width: 8, height: 8)
                        .scaleEffect(pulseScale)
                        .opacity(pulseOpacity)
                        .onAppear {
                            withAnimation(Animation.easeInOut(duration: 0.9).repeatForever(autoreverses: true)) {
                                pulseScale = 1.5
                                pulseOpacity = 0.5
                            }
                        }
                    Text("SCANNING...")
                        .font(.system(.caption, design: .monospaced))
                        .foregroundColor(.meshWarn)
                } else if mesh.readyRemoteCount > 0 {
                    Circle()
                        .fill(Color.meshSuccess)
                        .frame(width: 8, height: 8)
                    Text("\(mesh.readyRemoteCount) PEERS LINKED")
                        .font(.system(.caption, design: .monospaced))
                        .foregroundColor(.meshSuccess)
                } else {
                    Circle()
                        .fill(Color.gray)
                        .frame(width: 8, height: 8)
                    Text("NO PEERS")
                        .font(.system(.caption, design: .monospaced))
                        .foregroundColor(.secondary)
                }
            }
            
            Spacer()
            
            // Centre: app name "MESHMAP"
            Text("MESHMAP")
                .font(.system(.caption, design: .monospaced))
                .fontWeight(.bold)
                .foregroundColor(.secondary)
            
            Spacer()
            
            // Right side: "BT ON" / "BT OFF"
            Text(mesh.bluetoothState == .poweredOn ? "BT ON" : "BT OFF")
                .font(.system(.caption, design: .monospaced))
                .foregroundColor(mesh.bluetoothState == .poweredOn ? .secondary : .meshAccent)
        }
        .padding(.horizontal, 12)
        .frame(height: 36)
        .background(Color(UIColor.systemBackground))
        .overlay(
            Rectangle()
                .frame(height: 0.5)
                .foregroundColor(Color.gray.opacity(0.3)),
            alignment: .bottom
        )
    }
}
