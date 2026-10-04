//
//  RTSPSource.swift
//  mantis
//
//  Приём видео с IP-камеры по RTSP без сторонних библиотек:
//    • RTSP поверх TCP (RTP «interleaved» в том же соединении — проходит через любые роутеры);
//    • авторизация Basic и Digest (Hikvision, Dahua и большинство камер);
//    • H.264 и H.265: сборка NAL-блоков из RTP (FU-A / STAP-A, FU / AP);
//    • аппаратное декодирование VideoToolbox → CVPixelBuffer (BGRA) — дальше тот же движок, что для камеры телефона.
//
//  Всё работает в отдельном потоке на обычных сокетах. При обрыве — переподключение через 3 с.
//

import CoreMedia
import CryptoKit
import Foundation
import Security
import VideoToolbox

/// Обёртка, чтобы передавать кадр между потоками.
nonisolated struct FrameBox: @unchecked Sendable {
    let buffer: CVPixelBuffer
}

/// Настройки IP-камеры (пароль хранится отдельно, в связке ключей).
nonisolated struct IPCameraConfig: Codable, Equatable, Sendable {
    var url = ""
    var user = ""

    static let storageKey = "ipCameraConfig.v1"
    static let keychainAccount = "ipCameraPassword"

    static func load() -> IPCameraConfig {
        guard let d = UserDefaults.standard.data(forKey: storageKey),
              let c = try? JSONDecoder().decode(IPCameraConfig.self, from: d) else { return IPCameraConfig() }
        return c
    }

    func save() {
        if let d = try? JSONEncoder().encode(self) { UserDefaults.standard.set(d, forKey: Self.storageKey) }
    }

    var isEmpty: Bool { url.trimmingCharacters(in: .whitespaces).isEmpty }
}

/// Пароль в связке ключей.
nonisolated enum Keychain {
    static func set(_ value: String, account: String) {
        let base: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrAccount as String: account]
        SecItemDelete(base as CFDictionary)
        guard !value.isEmpty else { return }
        var add = base
        add[kSecValueData as String] = Data(value.utf8)
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        SecItemAdd(add as CFDictionary, nil)
    }

    static func get(_ account: String) -> String {
        let q: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrAccount as String: account,
                                kSecReturnData as String: true, kSecMatchLimit as String: kSecMatchLimitOne]
        var out: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess, let d = out as? Data else { return "" }
        return String(decoding: d, as: UTF8.self)
    }
}

// MARK: - Источник

nonisolated final class RTSPSource: @unchecked Sendable {
    enum State: Sendable, Equatable {
        case connecting
        case playing(codec: String, width: Int, height: Int)
        case failed(String)
        case stopped
    }

    enum RTSPError: LocalizedError {
        case badURL
        case connect(String)
        case closed
        case status(Int, String)
        case unauthorized
        case notFound
        case noVideo
        case codec(String)
        case timeout

        var errorDescription: String? {
            switch self {
            case .badURL: return "Неверный адрес. Пример: rtsp://192.168.1.64:554/Streaming/Channels/102"
            case .connect(let s): return "Не удалось подключиться: \(s)"
            case .closed: return "Камера закрыла соединение"
            case .status(let c, let m): return "Камера ответила \(c) \(m)"
            case .unauthorized: return "Неверный логин или пароль"
            case .notFound: return "Поток не найден — проверьте путь в адресе"
            case .noVideo: return "В потоке нет видео"
            case .codec(let c): return "Кодек \(c) не поддерживается — включите в камере H.264 или H.265"
            case .timeout: return "Камера не отвечает"
            }
        }
    }

    /// Новый кадр (вызывается в потоке приёма).
    var onFrame: (@Sendable (FrameBox, Double) -> Void)?
    /// Смена состояния (вызывается в потоке приёма).
    var onState: (@Sendable (State) -> Void)?

    private let url: String
    private let user: String
    private let password: String
    private let lock = NSLock()
    private var _running = false
    private var fd: Int32 = -1
    /// Время непрерывно растёт и после переподключения (иначе подсчёт «застынет»).
    private var lastTime = 0.0

    private var running: Bool {
        get { lock.lock(); defer { lock.unlock() }; return _running }
        set { lock.lock(); _running = newValue; lock.unlock() }
    }

    init(url: String, user: String, password: String) {
        self.url = url.trimmingCharacters(in: .whitespaces)
        self.user = user
        self.password = password
    }

    func start() {
        guard !running else { return }
        running = true
        let thread = Thread { [self] in self.loop() }
        thread.name = "mantis.rtsp"
        thread.qualityOfService = .userInitiated
        thread.start()
    }

    func stop() {
        running = false
        lock.lock()
        let s = fd
        lock.unlock()
        if s >= 0 { shutdown(s, SHUT_RDWR) }   // разбудить recv
    }

    private func loop() {
        while running {
            onState?(.connecting)
            do {
                try session()
            } catch {
                guard running else { break }
                onState?(.failed((error as? LocalizedError)?.errorDescription ?? error.localizedDescription))
                // неверный пароль/путь/кодек — не долбим камеру часто
                let fatal: Bool
                switch error as? RTSPError {
                case .unauthorized?, .notFound?, .codec?, .badURL?, .noVideo?: fatal = true
                default: fatal = false
                }
                let wait = fatal ? 15.0 : 3.0
                var waited = 0.0
                while running && waited < wait {
                    Thread.sleep(forTimeInterval: 0.25)
                    waited += 0.25
                }
            }
        }
        onState?(.stopped)
    }

    // MARK: Сеанс RTSP

    private func session() throws {
        let u = try RTSPURL(url, user: user, password: password)
        let conn = try RTSPConnection(host: u.host, port: u.port, user: u.user, password: u.password)
        lock.lock()
        fd = conn.fd
        lock.unlock()
        defer {
            lock.lock()
            fd = -1
            lock.unlock()
            conn.close()
        }

        // DESCRIBE → SDP
        let describe = try conn.request("DESCRIBE", u.requestURL, ["Accept": "application/sdp"])
        let sdp = SDP(describe.body)
        guard let video = sdp.video else { throw RTSPError.noVideo }
        guard video.codec == "H264" || video.codec == "H265" || video.codec == "HEVC" else { throw RTSPError.codec(video.codec) }
        let hevc = video.codec != "H264"
        let base = describe.headers["content-base"] ?? describe.headers["content-location"] ?? u.requestURL

        // SETUP: RTP внутри того же TCP-соединения (каналы 0–1)
        let setup = try conn.request("SETUP", RTSPURL.resolve(base: base, control: video.control),
                                     ["Transport": "RTP/AVP/TCP;unicast;interleaved=0-1"])
        guard let sessionHeader = setup.headers["session"] else { throw RTSPError.status(setup.code, "нет Session") }
        let parts = sessionHeader.split(separator: ";")
        conn.session = String(parts[0]).trimmingCharacters(in: .whitespaces)
        var keepAlive = 30.0
        for p in parts.dropFirst() where p.trimmingCharacters(in: .whitespaces).hasPrefix("timeout=") {
            if let t = Double(p.split(separator: "=").last ?? "") { keepAlive = max(5, t * 0.6) }
        }
        var rtpChannel: UInt8 = 0
        if let tr = setup.headers["transport"], let r = tr.range(of: "interleaved=") {
            rtpChannel = UInt8(tr[r.upperBound...].prefix { $0.isNumber }) ?? 0
        }

        _ = try conn.request("PLAY", base, ["Range": "npt=0.000-"])

        let depack = Depacketizer(hevc: hevc)
        let decoder = VideoDecoder(hevc: hevc)
        for ps in video.parameterSets { decoder.updateParameterSet(ps) }
        var announced = false
        var lastKeepAlive = Date()
        var clock = RTPClock()
        let offset = lastTime + 0.1

        while running {
            if Date().timeIntervalSince(lastKeepAlive) > keepAlive {
                lastKeepAlive = Date()
                try conn.send("OPTIONS", u.requestURL, [:])   // ответ придёт в общем потоке и будет пропущен
            }
            guard let packet = try conn.nextPacket() else { continue }   // ответ RTSP — пропускаем
            guard packet.channel == rtpChannel, let rtp = RTPPacket(packet.payload) else { continue }
            guard let au = depack.push(rtp) else { continue }
            let t = offset + clock.seconds(au.timestamp)
            lastTime = t
            decoder.decode(au.nals, time: t) { [self] pixel in
                if !announced {
                    announced = true
                    onState?(.playing(codec: hevc ? "H.265" : "H.264",
                                      width: CVPixelBufferGetWidth(pixel), height: CVPixelBufferGetHeight(pixel)))
                }
                onFrame?(FrameBox(buffer: pixel), t)
            }
        }
        _ = try? conn.send("TEARDOWN", base, [:])
    }
}

// MARK: - Адрес

nonisolated struct RTSPURL {
    var host: String
    var port: Int
    var user: String
    var password: String
    /// Адрес без логина и пароля — для строки запроса.
    var requestURL: String

    init(_ raw: String, user: String, password: String) throws {
        guard let c = URLComponents(string: raw), c.scheme?.lowercased() == "rtsp", let host = c.host, !host.isEmpty else {
            throw RTSPSource.RTSPError.badURL
        }
        self.host = host
        port = c.port ?? 554
        self.user = user.isEmpty ? (c.user?.removingPercentEncoding ?? "") : user
        self.password = password.isEmpty ? (c.password?.removingPercentEncoding ?? "") : password
        var clean = c
        clean.user = nil
        clean.password = nil
        clean.port = port
        requestURL = clean.string ?? raw
    }

    static func resolve(base: String, control: String) -> String {
        if control.isEmpty || control == "*" { return base }
        if control.lowercased().hasPrefix("rtsp://") { return control }
        return base.hasSuffix("/") ? base + control : base + "/" + control
    }
}

// MARK: - Соединение (сокеты)

nonisolated final class RTSPConnection {
    struct Response {
        var code: Int
        var headers: [String: String]
        var body: String
    }

    struct Interleaved {
        var channel: UInt8
        var payload: ArraySlice<UInt8>
    }

    let fd: Int32
    var session: String?
    private let user: String
    private let password: String
    private var cseq = 0
    private var auth: (digest: Bool, realm: String, nonce: String)?
    private var buf: [UInt8] = []
    private var pos = 0
    private var chunk = [UInt8](repeating: 0, count: 65536)

    init(host: String, port: Int, user: String, password: String) throws {
        self.user = user
        self.password = password
        fd = try Self.connect(host: host, port: port)
    }

    func close() { Darwin.close(fd) }

    static func connect(host: String, port: Int) throws -> Int32 {
        var hints = addrinfo()
        hints.ai_family = AF_UNSPEC
        hints.ai_socktype = SOCK_STREAM
        hints.ai_protocol = IPPROTO_TCP
        var res: UnsafeMutablePointer<addrinfo>?
        let gai = getaddrinfo(host, String(port), &hints, &res)
        guard gai == 0, let first = res else {
            throw RTSPSource.RTSPError.connect("адрес \(host) не найден")
        }
        defer { freeaddrinfo(first) }
        var lastError = "нет ответа"
        var ai: UnsafeMutablePointer<addrinfo>? = first
        while let a = ai {
            let s = socket(a.pointee.ai_family, a.pointee.ai_socktype, a.pointee.ai_protocol)
            if s >= 0 {
                var one: Int32 = 1
                setsockopt(s, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
                setsockopt(s, IPPROTO_TCP, TCP_NODELAY, &one, socklen_t(MemoryLayout<Int32>.size))
                // неблокирующее подключение с таймаутом 5 с
                let flags = fcntl(s, F_GETFL, 0)
                _ = fcntl(s, F_SETFL, flags | O_NONBLOCK)
                var ok = Darwin.connect(s, a.pointee.ai_addr, a.pointee.ai_addrlen) == 0
                if !ok && errno == EINPROGRESS {
                    var p = pollfd(fd: s, events: Int16(POLLOUT), revents: 0)
                    if poll(&p, 1, 5000) > 0 {
                        var err: Int32 = 0
                        var len = socklen_t(MemoryLayout<Int32>.size)
                        getsockopt(s, SOL_SOCKET, SO_ERROR, &err, &len)
                        ok = err == 0
                        if !ok { lastError = String(cString: strerror(err)) }
                    } else {
                        lastError = "таймаут"
                    }
                } else if !ok {
                    lastError = String(cString: strerror(errno))
                }
                if ok {
                    _ = fcntl(s, F_SETFL, flags)
                    var tv = timeval(tv_sec: 10, tv_usec: 0)
                    setsockopt(s, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
                    setsockopt(s, SOL_SOCKET, SO_SNDTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
                    return s
                }
                Darwin.close(s)
            }
            ai = a.pointee.ai_next
        }
        throw RTSPSource.RTSPError.connect(lastError)
    }

    // MARK: Запросы

    func send(_ method: String, _ uri: String, _ headers: [String: String]) throws {
        cseq += 1
        var lines = ["\(method) \(uri) RTSP/1.0", "CSeq: \(cseq)", "User-Agent: Mantis"]
        if let a = authorization(method: method, uri: uri) { lines.append("Authorization: \(a)") }
        if let session { lines.append("Session: \(session)") }
        for (k, v) in headers { lines.append("\(k): \(v)") }
        let data = Array((lines.joined(separator: "\r\n") + "\r\n\r\n").utf8)
        var sent = 0
        while sent < data.count {
            let n = data.withUnsafeBytes { Darwin.send(fd, $0.baseAddress! + sent, data.count - sent, 0) }
            if n <= 0 { throw RTSPSource.RTSPError.closed }
            sent += n
        }
    }

    /// Запрос с ответом; при 401 — один повтор с авторизацией.
    func request(_ method: String, _ uri: String, _ headers: [String: String]) throws -> Response {
        for attempt in 0..<2 {
            try send(method, uri, headers)
            let r = try readResponse()
            if r.code == 401 {
                guard attempt == 0, !user.isEmpty, let w = r.headers["www-authenticate"] else {
                    throw RTSPSource.RTSPError.unauthorized
                }
                auth = Self.parseAuth(w)
                continue
            }
            if r.code == 404 { throw RTSPSource.RTSPError.notFound }
            if r.code == 461 { throw RTSPSource.RTSPError.status(461, "транспорт TCP не поддерживается") }
            guard (200..<300).contains(r.code) else { throw RTSPSource.RTSPError.status(r.code, "") }
            return r
        }
        throw RTSPSource.RTSPError.unauthorized
    }

    private static func parseAuth(_ header: String) -> (digest: Bool, realm: String, nonce: String) {
        // при нескольких заголовках склеены через ", " — берём Digest, если есть
        let digest = header.lowercased().contains("digest")
        func value(_ key: String) -> String {
            guard let r = header.range(of: key + "=\"") else { return "" }
            return String(header[r.upperBound...].prefix { $0 != "\"" })
        }
        return (digest, value("realm"), value("nonce"))
    }

    private func authorization(method: String, uri: String) -> String? {
        guard let auth, !user.isEmpty else { return nil }
        if !auth.digest {
            return "Basic " + Data("\(user):\(password)".utf8).base64EncodedString()
        }
        func md5(_ s: String) -> String { Insecure.MD5.hash(data: Data(s.utf8)).map { String(format: "%02x", $0) }.joined() }
        let ha1 = md5("\(user):\(auth.realm):\(password)")
        let ha2 = md5("\(method):\(uri)")
        let response = md5("\(ha1):\(auth.nonce):\(ha2)")
        return "Digest username=\"\(user)\", realm=\"\(auth.realm)\", nonce=\"\(auth.nonce)\", uri=\"\(uri)\", response=\"\(response)\""
    }

    // MARK: Чтение

    private var available: Int { buf.count - pos }

    private func fill() throws {
        let n = chunk.withUnsafeMutableBytes { recv(fd, $0.baseAddress, $0.count, 0) }
        if n == 0 { throw RTSPSource.RTSPError.closed }
        if n < 0 {
            if errno == EAGAIN || errno == EWOULDBLOCK { throw RTSPSource.RTSPError.timeout }
            throw RTSPSource.RTSPError.closed
        }
        if pos > 0 && pos >= buf.count / 2 {
            buf.removeFirst(pos)
            pos = 0
        }
        buf.append(contentsOf: chunk[0..<n])
    }

    private func need(_ n: Int) throws {
        while available < n { try fill() }
    }

    /// Пропустить пакеты RTP, дождаться и разобрать ответ RTSP.
    private func readResponse() throws -> Response {
        while true {
            try need(1)
            if buf[pos] == 0x24 {   // '$' — пакет RTP/RTCP
                try need(4)
                let n = Int(buf[pos + 2]) << 8 | Int(buf[pos + 3])
                try need(4 + n)
                pos += 4 + n
                continue
            }
            return try parseResponse()
        }
    }

    private func parseResponse() throws -> Response {
        // ждём конец заголовков
        var end: Int?
        while end == nil {
            if available >= 4 {
                for i in pos...(buf.count - 4) where buf[i] == 13 && buf[i + 1] == 10 && buf[i + 2] == 13 && buf[i + 3] == 10 {
                    end = i
                    break
                }
            }
            if end == nil {
                if available > 64 * 1024 { throw RTSPSource.RTSPError.status(0, "неверный ответ") }
                try fill()
            }
        }
        let headEnd = end!
        let head = String(decoding: buf[pos..<headEnd], as: UTF8.self)
        let lines = head.components(separatedBy: "\r\n")
        let statusParts = (lines.first ?? "").split(separator: " ", maxSplits: 2)
        let code = statusParts.count > 1 ? Int(statusParts[1]) ?? 0 : 0
        var headers: [String: String] = [:]
        for l in lines.dropFirst() {
            guard let c = l.firstIndex(of: ":") else { continue }
            let k = l[..<c].trimmingCharacters(in: .whitespaces).lowercased()
            let v = l[l.index(after: c)...].trimmingCharacters(in: .whitespaces)
            headers[k] = headers[k].map { $0 + ", " + v } ?? v
        }
        let length = Int(headers["content-length"] ?? "0") ?? 0
        let bodyStart = headEnd + 4
        let consumedBefore = bodyStart - pos
        try need(consumedBefore + length)
        let start = pos + consumedBefore
        let body = String(decoding: buf[start..<(start + length)], as: UTF8.self)
        pos = start + length
        return Response(code: code, headers: headers, body: body)
    }

    /// Следующий пакет из потока: RTP/RTCP (канал + данные) или nil, если это был ответ RTSP.
    func nextPacket() throws -> Interleaved? {
        try need(1)
        guard buf[pos] == 0x24 else {
            let r = try parseResponse()
            if r.code == 401 || r.code == 454 { throw RTSPSource.RTSPError.closed }
            return nil
        }
        try need(4)
        let channel = buf[pos + 1]
        let n = Int(buf[pos + 2]) << 8 | Int(buf[pos + 3])
        try need(4 + n)
        let payload = buf[(pos + 4)..<(pos + 4 + n)]
        pos += 4 + n
        return Interleaved(channel: channel, payload: payload)
    }
}

// MARK: - SDP

nonisolated struct SDP {
    struct Video {
        var codec = ""
        var control = ""
        var parameterSets: [[UInt8]] = []
    }

    var video: Video?

    init(_ text: String) {
        var inVideo = false
        var v = Video()
        var found = false
        for raw in text.components(separatedBy: .newlines) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("m=") {
                if found && inVideo { break }   // первая видеодорожка
                inVideo = line.hasPrefix("m=video")
                if inVideo { found = true }
            } else if inVideo, line.hasPrefix("a=rtpmap:") {
                if let enc = line.split(separator: " ").dropFirst().first {
                    v.codec = String(enc.split(separator: "/").first ?? "").uppercased()
                }
            } else if inVideo, line.hasPrefix("a=control:") {
                v.control = String(line.dropFirst("a=control:".count))
            } else if inVideo, line.hasPrefix("a=fmtp:") {
                let params = line.split(separator: " ", maxSplits: 1).last ?? ""
                var sets: [String: String] = [:]
                for kv in params.split(separator: ";") {
                    let p = kv.trimmingCharacters(in: .whitespaces)
                    guard let e = p.firstIndex(of: "=") else { continue }
                    sets[String(p[..<e]).lowercased()] = String(p[p.index(after: e)...])
                }
                if let s = sets["sprop-parameter-sets"] {
                    v.parameterSets += s.split(separator: ",").compactMap { Data(base64Encoded: Self.pad(String($0))).map { [UInt8]($0) } }
                }
                for k in ["sprop-vps", "sprop-sps", "sprop-pps"] {
                    if let s = sets[k], let d = Data(base64Encoded: Self.pad(s)) { v.parameterSets.append([UInt8](d)) }
                }
            }
        }
        if found { video = v }
    }

    private static func pad(_ s: String) -> String {
        let r = s.count % 4
        return r == 0 ? s : s + String(repeating: "=", count: 4 - r)
    }
}

// MARK: - RTP

nonisolated struct RTPPacket {
    var marker: Bool
    var timestamp: UInt32
    var payload: ArraySlice<UInt8>

    init?(_ p: ArraySlice<UInt8>) {
        guard p.count >= 12 else { return nil }
        let s = p.startIndex
        let b0 = p[s], b1 = p[s + 1]
        guard b0 >> 6 == 2 else { return nil }
        marker = b1 & 0x80 != 0
        timestamp = UInt32(p[s + 4]) << 24 | UInt32(p[s + 5]) << 16 | UInt32(p[s + 6]) << 8 | UInt32(p[s + 7])
        var off = s + 12 + Int(b0 & 0x0f) * 4
        if b0 & 0x10 != 0 {
            guard off + 4 <= p.endIndex else { return nil }
            off += 4 + (Int(p[off + 2]) << 8 | Int(p[off + 3])) * 4
        }
        var end = p.endIndex
        if b0 & 0x20 != 0, let last = p.last { end -= Int(last) }
        guard off < end else { return nil }
        payload = p[off..<end]
    }
}

/// Непрерывное время по 90-кГц меткам RTP (с учётом переполнения 32 бит).
nonisolated struct RTPClock {
    private var first: Int64?
    private var last: UInt32 = 0
    private var wraps: Int64 = 0

    mutating func seconds(_ ts: UInt32) -> Double {
        if first != nil {
            if ts < last && last - ts > 0x8000_0000 { wraps += 1 }
        }
        last = ts
        let full = Int64(ts) + wraps << 32
        if first == nil { first = full }
        return Double(full - (first ?? full)) / 90000
    }
}

/// Сборка кадров (access unit) из RTP-пакетов.
nonisolated final class Depacketizer {
    struct AccessUnit {
        var nals: [[UInt8]]
        var timestamp: UInt32
    }

    private let hevc: Bool
    private var nals: [[UInt8]] = []
    private var fu: [UInt8]?
    private var ts: UInt32 = 0

    init(hevc: Bool) { self.hevc = hevc }

    func push(_ p: RTPPacket) -> AccessUnit? {
        var done: AccessUnit?
        // новая метка времени без маркера на прошлом кадре — отдаём накопленное
        if !nals.isEmpty && p.timestamp != ts {
            done = AccessUnit(nals: nals, timestamp: ts)
            nals = []
            fu = nil
        }
        ts = p.timestamp
        let pl = p.payload
        guard let h0 = pl.first else { return done }
        let s = pl.startIndex
        if !hevc {
            let type = h0 & 0x1f
            switch type {
            case 1...23:
                nals.append(Array(pl))
            case 24:   // STAP-A
                var i = s + 1
                while i + 2 <= pl.endIndex {
                    let n = Int(pl[i]) << 8 | Int(pl[i + 1])
                    guard i + 2 + n <= pl.endIndex else { break }
                    nals.append(Array(pl[(i + 2)..<(i + 2 + n)]))
                    i += 2 + n
                }
            case 28:   // FU-A
                guard pl.count > 2 else { break }
                let fh = pl[s + 1]
                if fh & 0x80 != 0 {
                    fu = [(h0 & 0xe0) | (fh & 0x1f)] + pl[(s + 2)...]
                } else if fu != nil {
                    fu! += pl[(s + 2)...]
                }
                if fh & 0x40 != 0, let f = fu {
                    nals.append(f)
                    fu = nil
                }
            default:
                break
            }
        } else {
            guard pl.count >= 2 else { return done }
            let type = (h0 >> 1) & 0x3f
            switch type {
            case 0..<48:
                nals.append(Array(pl))
            case 48:   // AP
                var i = s + 2
                while i + 2 <= pl.endIndex {
                    let n = Int(pl[i]) << 8 | Int(pl[i + 1])
                    guard i + 2 + n <= pl.endIndex else { break }
                    nals.append(Array(pl[(i + 2)..<(i + 2 + n)]))
                    i += 2 + n
                }
            case 49:   // FU
                guard pl.count > 3 else { break }
                let fh = pl[s + 2]
                if fh & 0x80 != 0 {
                    fu = [(h0 & 0x81) | ((fh & 0x3f) << 1), pl[s + 1]] + pl[(s + 3)...]
                } else if fu != nil {
                    fu! += pl[(s + 3)...]
                }
                if fh & 0x40 != 0, let f = fu {
                    nals.append(f)
                    fu = nil
                }
            default:
                break
            }
        }
        if p.marker && !nals.isEmpty && done == nil {
            let au = AccessUnit(nals: nals, timestamp: ts)
            nals = []
            return au
        }
        // если уже отдаём прошлый кадр, текущий останется в nals и уйдёт со следующим пакетом
        return done
    }
}

// MARK: - Декодер VideoToolbox

/// Результат декодирования из обработчика VideoToolbox.
nonisolated final class DecodedBox: @unchecked Sendable {
    private let lock = NSLock()
    private var value: CVPixelBuffer?
    func set(_ v: CVPixelBuffer) { lock.lock(); value = v; lock.unlock() }
    func get() -> CVPixelBuffer? { lock.lock(); defer { lock.unlock() }; return value }
}

nonisolated final class VideoDecoder {
    private let hevc: Bool
    private var vps: [UInt8]?
    private var sps: [UInt8]?
    private var pps: [UInt8]?
    private var format: CMVideoFormatDescription?
    private var session: VTDecompressionSession?
    private var gotKeyframe = false

    init(hevc: Bool) { self.hevc = hevc }

    deinit {
        if let session { VTDecompressionSessionInvalidate(session) }
    }

    private func type(_ nal: [UInt8]) -> Int {
        guard let b = nal.first else { return -1 }
        return hevc ? Int((b >> 1) & 0x3f) : Int(b & 0x1f)
    }

    /// Параметры кодека (из SDP или из потока). Если поменялись — пересоздаём декодер.
    @discardableResult
    func updateParameterSet(_ nal: [UInt8]) -> Bool {
        let t = type(nal)
        var changed = false
        if hevc {
            switch t {
            case 32: if vps != nal { vps = nal; changed = true }
            case 33: if sps != nal { sps = nal; changed = true }
            case 34: if pps != nal { pps = nal; changed = true }
            default: return false
            }
        } else {
            switch t {
            case 7: if sps != nal { sps = nal; changed = true }
            case 8: if pps != nal { pps = nal; changed = true }
            default: return false
            }
        }
        if changed { reset() }
        return true
    }

    private func reset() {
        if let session { VTDecompressionSessionInvalidate(session) }
        session = nil
        format = nil
    }

    private func isKeyframe(_ t: Int) -> Bool { hevc ? (16...21).contains(t) : t == 5 }

    func decode(_ nals: [[UInt8]], time: Double, output: (CVPixelBuffer) -> Void) {
        var payload: [UInt8] = []
        var key = false
        for nal in nals {
            if updateParameterSet(nal) { continue }
            let t = type(nal)
            if !hevc && t == 9 { continue }      // AUD
            if hevc && t == 35 { continue }
            if isKeyframe(t) { key = true }
            let n = UInt32(nal.count)
            payload += [UInt8(n >> 24), UInt8((n >> 16) & 0xff), UInt8((n >> 8) & 0xff), UInt8(n & 0xff)]
            payload += nal
        }
        if key { gotKeyframe = true }
        guard gotKeyframe, !payload.isEmpty, ensureSession(), let session, let format else { return }

        var block: CMBlockBuffer?
        guard CMBlockBufferCreateWithMemoryBlock(allocator: kCFAllocatorDefault, memoryBlock: nil, blockLength: payload.count,
                                                 blockAllocator: kCFAllocatorDefault, customBlockSource: nil, offsetToData: 0,
                                                 dataLength: payload.count, flags: 0, blockBufferOut: &block) == noErr,
              let block else { return }
        let copied = payload.withUnsafeBytes {
            CMBlockBufferReplaceDataBytes(with: $0.baseAddress!, blockBuffer: block, offsetIntoDestination: 0, dataLength: payload.count)
        }
        guard copied == noErr else { return }

        var sample: CMSampleBuffer?
        var timing = CMSampleTimingInfo(duration: .invalid,
                                        presentationTimeStamp: CMTime(seconds: time, preferredTimescale: 90000),
                                        decodeTimeStamp: .invalid)
        var size = payload.count
        guard CMSampleBufferCreateReady(allocator: kCFAllocatorDefault, dataBuffer: block, formatDescription: format,
                                        sampleCount: 1, sampleTimingEntryCount: 1, sampleTimingArray: &timing,
                                        sampleSizeEntryCount: 1, sampleSizeArray: &size, sampleBufferOut: &sample) == noErr,
              let sample else { return }

        let result = DecodedBox()
        let status = VTDecompressionSessionDecodeFrame(session, sampleBuffer: sample, flags: [], infoFlagsOut: nil) { st, _, image, _, _ in
            if st == noErr, let image { result.set(image) }
        }
        VTDecompressionSessionWaitForAsynchronousFrames(session)
        let decoded = result.get()
        if status == kVTInvalidSessionErr {
            reset()   // например, после ухода приложения в фон — пересоздастся на следующем кадре
            gotKeyframe = false
            return
        }
        if let decoded { output(decoded) }
    }

    private func ensureSession() -> Bool {
        if session != nil { return true }
        let sets: [[UInt8]]
        if hevc {
            guard let vps, let sps, let pps else { return false }
            sets = [vps, sps, pps]
        } else {
            guard let sps, let pps else { return false }
            sets = [sps, pps]
        }
        guard let fmt = Self.makeFormat(sets, hevc: hevc) else { return false }
        let attrs: [CFString: Any] = [
            kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_32BGRA,
            kCVPixelBufferIOSurfacePropertiesKey: [CFString: Any]() as CFDictionary,
        ]
        var s: VTDecompressionSession?
        guard VTDecompressionSessionCreate(allocator: kCFAllocatorDefault, formatDescription: fmt, decoderSpecification: nil,
                                           imageBufferAttributes: attrs as CFDictionary, outputCallback: nil,
                                           decompressionSessionOut: &s) == noErr, let s else { return false }
        format = fmt
        session = s
        return true
    }

    private static func makeFormat(_ sets: [[UInt8]], hevc: Bool) -> CMVideoFormatDescription? {
        let buffers: [UnsafeMutablePointer<UInt8>] = sets.map { set in
            let p = UnsafeMutablePointer<UInt8>.allocate(capacity: set.count)
            p.initialize(from: set, count: set.count)
            return p
        }
        defer { buffers.forEach { $0.deallocate() } }
        let pointers: [UnsafePointer<UInt8>] = buffers.map { UnsafePointer($0) }
        let sizes = sets.map(\.count)
        var fmt: CMFormatDescription?
        let status: OSStatus
        if hevc {
            status = CMVideoFormatDescriptionCreateFromHEVCParameterSets(
                allocator: kCFAllocatorDefault, parameterSetCount: sets.count, parameterSetPointers: pointers,
                parameterSetSizes: sizes, nalUnitHeaderLength: 4, extensions: nil, formatDescriptionOut: &fmt)
        } else {
            status = CMVideoFormatDescriptionCreateFromH264ParameterSets(
                allocator: kCFAllocatorDefault, parameterSetCount: sets.count, parameterSetPointers: pointers,
                parameterSetSizes: sizes, nalUnitHeaderLength: 4, formatDescriptionOut: &fmt)
        }
        return status == noErr ? fmt : nil
    }
}
