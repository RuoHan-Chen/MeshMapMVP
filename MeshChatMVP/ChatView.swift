import SwiftUI
import PhotosUI

/// Chat-only UI (mesh status strip + transcript + send + simple photo send).
struct ChatView: View {
    @EnvironmentObject var mesh: BluetoothMeshService
    @State private var draft = ""
    @FocusState private var messageFocused: Bool
    @State private var sendCooldown = false
    @State private var pickedItem: PhotosPickerItem?
    @State private var imageBusy = false
    @State private var showPhotoSendInfo = false
    /// Non-nil while chunks are going out over BLE.
    @State private var imageSendPacketsTotal: Int?

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                statusStrip
                if imageBusy, let total = imageSendPacketsTotal, total > 0 {
                    sendingImageBanner(packetCount: total)
                }
                Divider()
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 10) {
                            ForEach(mesh.chatMessages) { m in
                                bubble(m)
                                    .id(m.id)
                            }
                        }
                        .padding()
                        .contentShape(Rectangle())
                        .onTapGesture { messageFocused = false }
                    }
                    .onChange(of: mesh.chatMessages.count) { _ in
                        if let last = mesh.chatMessages.last {
                            withAnimation { proxy.scrollTo(last.id, anchor: .bottom) }
                        }
                    }
                }
                Divider()
                HStack(alignment: .bottom, spacing: 10) {
                    PhotosPicker(selection: $pickedItem, matching: .images, photoLibrary: .shared()) {
                        Image(systemName: "photo.on.rectangle.angled")
                            .font(.title2)
                            .foregroundColor(imageBusy ? .secondary : .accentColor)
                    }
                    .disabled(imageBusy || sendCooldown)
                    TextField("Message", text: $draft, axis: .vertical)
                        .textFieldStyle(.roundedBorder)
                        .lineLimit(1...4)
                        .focused($messageFocused)
                    Button {
                        let t = draft.trimmingCharacters(in: .whitespacesAndNewlines)
                        guard !t.isEmpty, !sendCooldown else { return }
                        sendCooldown = true
                        mesh.sendChat(text: t)
                        draft = ""
                        messageFocused = false
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
                            sendCooldown = false
                        }
                    } label: {
                        Image(systemName: "arrow.up.circle.fill")
                            .font(.title2)
                    }
                    .disabled(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || sendCooldown)
                }
                .padding()
            }
            .navigationTitle(mesh.identity.nickname)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItemGroup(placement: .keyboard) {
                    Spacer()
                    Button("Done") { messageFocused = false }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        showPhotoSendInfo = true
                    } label: {
                        Label("How photos send", systemImage: "info.circle")
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        messageFocused = false
                    } label: {
                        Label("Hide keyboard", systemImage: "keyboard.chevron.compact.down")
                    }
                    .opacity(messageFocused ? 1 : 0)
                    .disabled(!messageFocused)
                }
            }
            .sheet(isPresented: $showPhotoSendInfo) {
                photoSendInfoSheet
            }
            .onChange(of: pickedItem) { newItem in
                guard let newItem else { return }
                imageBusy = true
                imageSendPacketsTotal = nil
                Task {
                    defer {
                        if imageSendPacketsTotal == nil {
                            Task { @MainActor in
                                imageBusy = false
                                pickedItem = nil
                            }
                        }
                    }
                    guard let data = try? await newItem.loadTransferable(type: Data.self),
                          let ui = UIImage(data: data),
                          let jpeg = try? MeshImageUtils.jpegDataForMesh(from: ui)
                    else {
                        await MainActor.run {
                            imageBusy = false
                            pickedItem = nil
                        }
                        return
                    }
                    let chunkSize = BluetoothMeshService.imageChunkByteSize
                    let packets = (jpeg.count + chunkSize - 1) / chunkSize
                    await MainActor.run {
                        imageSendPacketsTotal = packets
                        sendCooldown = true
                        mesh.sendImage(jpegData: jpeg) { sent in
                            imageBusy = false
                            imageSendPacketsTotal = nil
                            pickedItem = nil
                            sendCooldown = false
                            if sent == 0 {
                                // encode failed etc.
                            }
                        }
                        messageFocused = false
                    }
                }
            }
        }
    }

    private var photoSendInfoSheet: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    Text("How your photo is sent")
                        .font(.title2.bold())
                    Group {
                        Text("Bluetooth limit — Each mesh packet can only hold about \(BluetoothMeshService.meshEnvelopeMaxBytes) bytes of JSON (BLE-friendly size). A JPEG is much larger, so the app splits it.")
                        Text("Slices — Your image is compressed (max \(MeshImageUtils.maxJPEGBytes / 1024) KB), then cut into pieces of \(BluetoothMeshService.imageChunkByteSize) bytes each. Each piece rides in one packet with a small header (which slice, how many total, same transfer ID).")
                        Text("Order — Packets are sent one after another over the mesh. Peers (and relays) copy them until TTL runs out. The receiver puts the slices back in order to rebuild the JPEG.")
                        Text("Why it can feel slow — Lots of tiny packets + short pauses between them keep radios stable. Stay linked (Dashboard) for best delivery.")
                    }
                    .font(.body)
                    .foregroundStyle(.primary)
                }
                .padding(20)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { showPhotoSendInfo = false }
                }
            }
        }
        .presentationDetents([.medium, .large])
    }

    private func sendingImageBanner(packetCount: Int) -> some View {
        HStack(spacing: 10) {
            ProgressView()
            VStack(alignment: .leading, spacing: 2) {
                Text("Sending photo over mesh")
                    .font(.subheadline.weight(.semibold))
                Text("\(packetCount) packets (~\(BluetoothMeshService.imageChunkByteSize) bytes JPEG each, max \(BluetoothMeshService.meshEnvelopeMaxBytes) B per packet)")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(Color.accentColor.opacity(0.12))
    }

    private var statusStrip: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 12) {
                Label(
                    mesh.readyRemoteCount > 0 || mesh.subscribedCentralCount > 0 ? "Linked" : "Finding peers…",
                    systemImage: mesh.readyRemoteCount > 0 || mesh.subscribedCentralCount > 0
                        ? "link.circle.fill" : "antenna.radiowaves.left.and.right"
                )
                .font(.subheadline.weight(.medium))
                .foregroundStyle(
                    mesh.readyRemoteCount > 0 || mesh.subscribedCentralCount > 0 ? Color.green : Color.secondary
                )
                Spacer()
                if mesh.isScanning {
                    Text("Scanning")
                        .font(.caption2)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(Capsule().fill(Color.green.opacity(0.2)))
                } else if mesh.secondsUntilNextScan > 0 {
                    Text("Next scan \(Int(mesh.secondsUntilNextScan))s")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
            Text("Photos: many small mesh packets (see ⓘ). Dashboard = link quality.")
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
        .padding(.horizontal)
        .padding(.vertical, 10)
        .background(Color(.secondarySystemBackground))
    }

    private func bubble(_ m: ChatMessage) -> some View {
        HStack {
            if m.isLocal { Spacer(minLength: 48) }
            VStack(alignment: m.isLocal ? .trailing : .leading, spacing: 4) {
                HStack(spacing: 6) {
                    if !m.isLocal {
                        Text(mesh.senderDisplayName(senderID: m.senderID, fallbackSenderName: m.senderName))
                            .font(.caption.weight(.semibold))
                    }
                    Text(m.date, style: .time).font(.caption2).foregroundStyle(.secondary)
                    if m.isLocal { Text("You").font(.caption.weight(.semibold)) }
                }
                if !m.isLocal, let dist = m.distanceFromMe {
                    Text(distanceString(dist)).font(.caption2).foregroundStyle(.secondary)
                }
                Group {
                    if let b64 = m.imageJPEGBase64, let imgData = Data(base64Encoded: b64), let ui = UIImage(data: imgData) {
                        Image(uiImage: ui)
                            .resizable()
                            .scaledToFit()
                            .frame(maxWidth: 220, maxHeight: 220)
                            .clipShape(RoundedRectangle(cornerRadius: 12))
                    } else {
                        Text(m.text)
                            .font(.body)
                    }
                }
                .padding(12)
                .background(
                    RoundedRectangle(cornerRadius: 16)
                        .fill(m.isLocal ? Color.accentColor.opacity(0.2) : Color(.secondarySystemBackground))
                )
            }
            if !m.isLocal { Spacer(minLength: 48) }
        }
    }

    private func distanceString(_ meters: Double) -> String {
        if meters < 1000 { return "~\(Int(round(meters))) m away" }
        return String(format: "~%.1f km away", meters / 1000)
    }
}

#Preview {
    ChatView()
        .environmentObject(BluetoothMeshService())
}
