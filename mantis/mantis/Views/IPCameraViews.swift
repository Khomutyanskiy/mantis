//
//  IPCameraViews.swift
//  mantis
//
//  IP-камера: показ RTSP-потока (AVSampleBufferDisplayLayer) и экран настроек подключения.
//

import AVFoundation
import SwiftUI
import UIKit

// MARK: - Показ кадров

final class RTSPDisplayView: UIView {
    override class var layerClass: AnyClass { AVSampleBufferDisplayLayer.self }
    private var displayLayer: AVSampleBufferDisplayLayer { layer as! AVSampleBufferDisplayLayer }

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .black
        displayLayer.videoGravity = .resizeAspect
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) не используется") }

    /// Показать декодированный кадр.
    func show(_ frame: FrameBox) {
        let pb = frame.buffer
        var fmt: CMVideoFormatDescription?
        guard CMVideoFormatDescriptionCreateForImageBuffer(allocator: kCFAllocatorDefault, imageBuffer: pb,
                                                           formatDescriptionOut: &fmt) == noErr, let fmt else { return }
        var timing = CMSampleTimingInfo(duration: .invalid, presentationTimeStamp: CMClockGetTime(CMClockGetHostTimeClock()),
                                        decodeTimeStamp: .invalid)
        var sb: CMSampleBuffer?
        guard CMSampleBufferCreateReadyWithImageBuffer(allocator: kCFAllocatorDefault, imageBuffer: pb, formatDescription: fmt,
                                                       sampleTiming: &timing, sampleBufferOut: &sb) == noErr, let sb else { return }
        // показать сразу, без привязки ко времени
        if let atts = CMSampleBufferGetSampleAttachmentsArray(sb, createIfNecessary: true), CFArrayGetCount(atts) > 0 {
            let dict = unsafeBitCast(CFArrayGetValueAtIndex(atts, 0), to: CFMutableDictionary.self)
            CFDictionarySetValue(dict, Unmanaged.passUnretained(kCMSampleAttachmentKey_DisplayImmediately).toOpaque(),
                                 Unmanaged.passUnretained(kCFBooleanTrue).toOpaque())
        }
        let renderer = displayLayer.sampleBufferRenderer
        if renderer.status == .failed { renderer.flush() }
        renderer.enqueue(sb)
    }

    func clear() {
        displayLayer.sampleBufferRenderer.flush(removingDisplayedImage: true, completionHandler: nil)
    }
}

struct RTSPPreview: UIViewRepresentable {
    let view: RTSPDisplayView

    func makeUIView(context: Context) -> RTSPDisplayView { view }
    func updateUIView(_ uiView: RTSPDisplayView, context: Context) {}
}

// MARK: - Настройки подключения

struct IPCameraSettingsView: View {
    let onSave: () -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var config = IPCameraConfig.load()
    @State private var password = Keychain.get(IPCameraConfig.keychainAccount)

    private struct Example: Identifiable {
        let id = UUID()
        let brand: String
        let url: String
    }

    private let examples = [
        Example(brand: "Hikvision (доп. поток)", url: "rtsp://192.168.1.64:554/Streaming/Channels/102"),
        Example(brand: "Dahua (доп. поток)", url: "rtsp://192.168.1.108:554/cam/realmonitor?channel=1&subtype=1"),
        Example(brand: "Uniview", url: "rtsp://192.168.1.13:554/media/video2"),
        Example(brand: "Тест с Mac (симулятор)", url: "rtsp://localhost:8554/cam"),
    ]

    var body: some View {
        Form {
            Section {
                NavigationLink {
                    CameraDiscoveryView { url, user, pass in
                        config.url = url
                        if !user.isEmpty { config.user = user }
                        if !pass.isEmpty { password = pass }
                    }
                } label: {
                    Label("Найти камеры в сети", systemImage: "magnifyingglass")
                        .foregroundStyle(Theme.moon)
                }
            } footer: {
                Text("Найдёт камеры в Wi-Fi магазина и сам подставит адрес потока.")
                    .foregroundStyle(Theme.moonDim)
            }
            .listRowBackground(Theme.surface)

            Section {
                TextField("rtsp://адрес:554/путь", text: $config.url)
                    .keyboardType(.URL)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                TextField("Логин", text: $config.user)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                SecureField("Пароль", text: $password)
            } header: {
                Text("Подключение").foregroundStyle(Theme.moonDim)
            } footer: {
                Text("Телефон и камера должны быть в одной сети (Wi-Fi магазина). Пароль хранится в связке ключей iPhone.")
                    .foregroundStyle(Theme.moonDim)
            }
            .listRowBackground(Theme.surface)

            Section {
                ForEach(examples) { e in
                    Button {
                        config.url = e.url
                    } label: {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(e.brand).font(.subheadline.weight(.semibold)).foregroundStyle(Theme.moon)
                            Text(e.url).font(.caption.monospaced()).foregroundStyle(Theme.moonDim)
                        }
                    }
                }
            } header: {
                Text("Примеры адресов").foregroundStyle(Theme.moonDim)
            } footer: {
                Text("Берите дополнительный поток (720p) — его хватает для подсчёта и он меньше нагружает телефон. В камере включите кодек H.264 или H.265.")
                    .foregroundStyle(Theme.moonDim)
            }
            .listRowBackground(Theme.surface)
        }
        .themedList()
        .navigationTitle("IP-камера")
        .navigationBarTitleDisplayMode(.inline)
        .themedNavigationBar()
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Отмена") { dismiss() }
            }
            ToolbarItem(placement: .confirmationAction) {
                Button("Подключить") {
                    config.url = config.url.trimmingCharacters(in: .whitespaces)
                    config.save()
                    Keychain.set(password, account: IPCameraConfig.keychainAccount)
                    onSave()
                    dismiss()
                }
                .disabled(config.isEmpty)
            }
        }
    }
}

// MARK: - Поиск камер в сети

struct CameraDiscoveryView: View {
    /// Выбранная камера: адрес RTSP, логин, пароль.
    let onPick: (String, String, String) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var scanning = false
    @State private var results: [DiscoveredCamera] = []
    @State private var subnetText = ""
    @State private var noNetwork = false
    @State private var loginFor: DiscoveredCamera?
    @State private var templateFor: DiscoveredCamera?

    var body: some View {
        List {
            Section {
                if scanning {
                    HStack(spacing: 12) {
                        ProgressView().tint(Theme.moon)
                        Text("Ищем камеры в сети \(subnetText)…").foregroundStyle(Theme.moonDim)
                    }
                } else if noNetwork {
                    Label("Нет подключения к Wi-Fi. Подключите телефон к сети магазина, где стоят камеры.",
                          systemImage: "wifi.slash")
                        .foregroundStyle(.orange)
                } else if results.isEmpty {
                    Text("Камеры не найдены в сети \(subnetText).")
                        .foregroundStyle(Theme.moonDim)
                }
                ForEach(results) { cam in
                    Button {
                        if cam.onvifURL != nil { loginFor = cam } else { templateFor = cam }
                    } label: {
                        HStack(spacing: 12) {
                            Image(systemName: cam.onvifURL != nil ? "web.camera.fill" : "video.badge.ellipsis")
                                .font(.title3)
                                .foregroundStyle(Theme.moon)
                                .frame(width: 30)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(cam.title).font(.subheadline.weight(.semibold)).foregroundStyle(Theme.moon)
                                Text(cam.subtitle).font(.caption).foregroundStyle(Theme.moonDim)
                            }
                            Spacer()
                            Image(systemName: "chevron.right").font(.caption.weight(.semibold)).foregroundStyle(Theme.moonDim)
                        }
                    }
                }
            } header: {
                Text("Найдено в сети").foregroundStyle(Theme.moonDim)
            } footer: {
                Text("Ищем камеры с ONVIF и устройства с открытым портом RTSP. Если iPhone спросил доступ к локальной сети — разрешите и нажмите «Искать снова». Камеры в отдельной сети или за VPN найти нельзя — введите адрес вручную.")
                    .foregroundStyle(Theme.moonDim)
            }
            .listRowBackground(Theme.surface)
        }
        .themedList()
        .navigationTitle("Поиск камер")
        .navigationBarTitleDisplayMode(.inline)
        .themedNavigationBar()
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button("Искать снова") { Task { await scan() } }
                    .disabled(scanning)
            }
        }
        .task { await scan() }
        .sheet(item: $loginFor) { cam in
            NavigationStack {
                ONVIFLoginView(camera: cam) { url, user, password in
                    loginFor = nil
                    onPick(url, user, password)
                    dismiss()
                }
            }
            .preferredColorScheme(.dark)
            .presentationDetents([.medium, .large])
        }
        .confirmationDialog("Какая это камера?", isPresented: Binding(get: { templateFor != nil }, set: { if !$0 { templateFor = nil } }),
                            titleVisibility: .visible, presenting: templateFor) { cam in
            ForEach(Self.templates(for: cam)) { t in
                Button(t.title) {
                    templateFor = nil
                    onPick(t.url, "", "")
                    dismiss()
                }
            }
            Button("Отмена", role: .cancel) {}
        } message: { cam in
            Text("\(cam.ip) не отвечает по ONVIF. Выберите марку — подставим путь потока, логин и пароль введёте на следующем экране.")
        }
    }

    private func scan() async {
        guard let subnet = CameraDiscovery.localSubnet() else {
            noNetwork = true
            return
        }
        noNetwork = false
        subnetText = subnet.description
        scanning = true
        results = await CameraDiscovery.scan(subnet: subnet)
        scanning = false
    }

    struct Template: Identifiable {
        let title: String
        let url: String
        var id: String { title }
    }

    static func templates(for cam: DiscoveredCamera) -> [Template] {
        let port = cam.rtspPorts.first ?? 554
        let base = "rtsp://\(cam.ip):\(port)"
        var t = [
            Template(title: "Hikvision", url: base + "/Streaming/Channels/102"),
            Template(title: "Dahua", url: base + "/cam/realmonitor?channel=1&subtype=1"),
            Template(title: "Uniview", url: base + "/media/video2"),
            Template(title: "TP-Link VIGI / Tapo", url: base + "/stream2"),
        ]
        if port == 8554 { t.insert(Template(title: "Тестовая камера (mediamtx)", url: base + "/cam"), at: 0) }
        return t
    }
}

/// Логин и пароль камеры → RTSP-ссылка через ONVIF.
struct ONVIFLoginView: View {
    let camera: DiscoveredCamera
    let onDone: (String, String, String) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var user = "admin"
    @State private var password = ""
    @State private var busy = false
    @State private var error: String?

    var body: some View {
        Form {
            Section {
                LabeledContent("Камера", value: camera.title)
                LabeledContent("Адрес", value: camera.ip)
            }
            .listRowBackground(Theme.surface)

            Section {
                TextField("Логин", text: $user)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                SecureField("Пароль", text: $password)
            } header: {
                Text("Вход в камеру").foregroundStyle(Theme.moonDim)
            } footer: {
                Text("Логин и пароль, которые задали при установке камеры. Приложение само получит адрес видеопотока.")
                    .foregroundStyle(Theme.moonDim)
            }
            .listRowBackground(Theme.surface)

            if let error {
                Section {
                    Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(.orange)
                }
                .listRowBackground(Theme.surface)
            }

            Section {
                Button {
                    Task { await connect() }
                } label: {
                    HStack {
                        Spacer()
                        if busy { ProgressView().tint(Theme.moon) } else { Text("Получить видеопоток").fontWeight(.semibold) }
                        Spacer()
                    }
                }
                .disabled(busy || user.isEmpty)
            }
            .listRowBackground(Theme.surfaceHigh)
        }
        .themedList()
        .navigationTitle("Подключение")
        .navigationBarTitleDisplayMode(.inline)
        .themedNavigationBar()
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Отмена") { dismiss() }
            }
        }
    }

    private func connect() async {
        guard let url = camera.onvifURL else { return }
        busy = true
        error = nil
        defer { busy = false }
        let u = user, p = password
        do {
            let info = try await Task.detached(priority: .userInitiated) {
                try ONVIFClient.streamURI(deviceURL: url, user: u, password: p)
            }.value
            onDone(info.uri, u, p)
        } catch {
            self.error = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }
}
