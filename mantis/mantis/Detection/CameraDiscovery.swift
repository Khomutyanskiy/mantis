//
//  CameraDiscovery.swift
//  mantis
//
//  Поиск IP-камер в локальной сети без группового (multicast) разрешения Apple:
//    1. ONVIF WS-Discovery — запрос Probe отправляется КАЖДОМУ адресу подсети по отдельности (UDP 3702);
//       камеры отвечают адресом сервиса, названием и моделью.
//    2. Проверка портов RTSP (554, 8554) — для камер без ONVIF.
//  После выбора камеры и ввода пароля ONVIF отдаёт готовую RTSP-ссылку (GetProfiles → GetStreamUri).
//

import CryptoKit
import Foundation

nonisolated struct DiscoveredCamera: Identifiable, Hashable, Sendable {
    var ip: String
    var name: String?
    var hardware: String?
    /// Адрес ONVIF device service (если камера ответила на ONVIF).
    var onvifURL: String?
    /// Открытые RTSP-порты.
    var rtspPorts: [Int] = []

    var id: String { ip }

    var title: String {
        if let name, !name.isEmpty { return name }
        if let hardware, !hardware.isEmpty { return hardware }
        return onvifURL != nil ? "ONVIF-камера" : "Устройство с RTSP"
    }

    var subtitle: String {
        var parts = [ip]
        if let hardware, hardware != title { parts.append(hardware) }
        if onvifURL != nil { parts.append("ONVIF") }
        if !rtspPorts.isEmpty { parts.append("RTSP :" + rtspPorts.map(String.init).joined(separator: ", :")) }
        return parts.joined(separator: " · ")
    }
}

nonisolated enum CameraDiscovery {
    struct Subnet {
        var ip: UInt32
        var hosts: [UInt32]
        var description: String
    }

    // MARK: Подсеть

    /// Адрес телефона в Wi-Fi и адреса соседей (не больше 254 — подсеть /24 вокруг телефона).
    static func localSubnet() -> Subnet? {
        var ifap: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifap) == 0, let first = ifap else { return nil }
        defer { freeifaddrs(ifap) }
        var candidates: [(name: String, ip: UInt32, mask: UInt32)] = []
        var p: UnsafeMutablePointer<ifaddrs>? = first
        while let a = p {
            defer { p = a.pointee.ifa_next }
            let flags = Int32(bitPattern: a.pointee.ifa_flags)
            guard let addr = a.pointee.ifa_addr, addr.pointee.sa_family == UInt8(AF_INET),
                  flags & IFF_UP != 0, flags & IFF_LOOPBACK == 0 else { continue }
            let name = String(cString: a.pointee.ifa_name)
            guard name.hasPrefix("en") || name.hasPrefix("bridge") else { continue }   // Wi-Fi / Ethernet, не сотовая сеть
            let ip = addr.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { UInt32(bigEndian: $0.pointee.sin_addr.s_addr) }
            var mask: UInt32 = 0xffff_ff00
            if let m = a.pointee.ifa_netmask {
                mask = m.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { UInt32(bigEndian: $0.pointee.sin_addr.s_addr) }
            }
            candidates.append((name, ip, mask))
        }
        guard let c = candidates.first(where: { $0.name == "en0" }) ?? candidates.first else { return nil }
        // большие подсети ужимаем до /24 вокруг телефона
        let mask = max(c.mask, 0xffff_ff00)
        let net = c.ip & mask
        let broadcast = net | ~mask
        var hosts: [UInt32] = []
        var h = net + 1
        while h < broadcast {
            if h != c.ip { hosts.append(h) }
            h += 1
        }
        return Subnet(ip: c.ip, hosts: hosts, description: "\(ipString(net))/\(mask.nonzeroBitCount)")
    }

    static func ipString(_ v: UInt32) -> String {
        "\(v >> 24 & 255).\(v >> 16 & 255).\(v >> 8 & 255).\(v & 255)"
    }

    // MARK: Поиск

    /// Полный поиск: ONVIF и порты RTSP параллельно. Занимает 3–4 с.
    static func scan(subnet: Subnet) async -> [DiscoveredCamera] {
        async let onvif = Task.detached(priority: .userInitiated) { probeONVIF(hosts: subnet.hosts) }.value
        async let ports = Task.detached(priority: .userInitiated) { scanPorts(hosts: subnet.hosts, ports: [554, 8554]) }.value
        let (o, r) = await (onvif, ports)
        var byIP: [String: DiscoveredCamera] = [:]
        for (ip, cam) in o { byIP[ip] = cam }
        for (ip, list) in r {
            var cam = byIP[ip] ?? DiscoveredCamera(ip: ip)
            cam.rtspPorts = list.sorted()
            byIP[ip] = cam
        }
        // свой Mac в симуляторе: тестовая камера на 8554 видна по localhost
        return byIP.values.sorted { a, b in
            if (a.onvifURL != nil) != (b.onvifURL != nil) { return a.onvifURL != nil }
            return ipOrder(a.ip) < ipOrder(b.ip)
        }
    }

    private static func ipOrder(_ s: String) -> UInt32 {
        s.split(separator: ".").compactMap { UInt32($0) }.reduce(0) { $0 << 8 | $1 }
    }

    /// WS-Discovery: Probe на каждый адрес (UDP 3702), ждём ответы.
    static func probeONVIF(hosts: [UInt32], timeout: Double = 3) -> [String: DiscoveredCamera] {
        let s = socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP)
        guard s >= 0 else { return [:] }
        defer { close(s) }
        let flags = fcntl(s, F_GETFL, 0)
        _ = fcntl(s, F_SETFL, flags | O_NONBLOCK)

        let probe = Array(probeMessage().utf8)
        for (i, h) in hosts.enumerated() {
            var addr = sockaddr_in()
            addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
            addr.sin_family = sa_family_t(AF_INET)
            addr.sin_port = in_port_t(3702).bigEndian
            addr.sin_addr.s_addr = h.bigEndian
            _ = probe.withUnsafeBytes { bytes in
                withUnsafePointer(to: &addr) {
                    $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                        sendto(s, bytes.baseAddress, bytes.count, 0, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
                    }
                }
            }
            if i % 32 == 31 { usleep(3000) }   // не переполнять буфер отправки
        }

        var found: [String: DiscoveredCamera] = [:]
        var buf = [UInt8](repeating: 0, count: 65536)
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            var p = pollfd(fd: s, events: Int16(POLLIN), revents: 0)
            let ms = Int32(max(1, deadline.timeIntervalSinceNow * 1000))
            guard poll(&p, 1, ms) > 0 else { continue }
            var from = sockaddr_in()
            var len = socklen_t(MemoryLayout<sockaddr_in>.size)
            let n = withUnsafeMutablePointer(to: &from) { fp in
                fp.withMemoryRebound(to: sockaddr.self, capacity: 1) { sp in
                    buf.withUnsafeMutableBytes { recvfrom(s, $0.baseAddress, $0.count, 0, sp, &len) }
                }
            }
            guard n > 0 else { continue }
            let ip = ipString(UInt32(bigEndian: from.sin_addr.s_addr))
            let xml = String(decoding: buf[0..<n], as: UTF8.self)
            guard xml.contains("ProbeMatch") else { continue }
            var cam = found[ip] ?? DiscoveredCamera(ip: ip)
            if let x = XML.first("XAddrs", in: xml) {
                let urls = x.split(separator: " ").map(String.init)
                cam.onvifURL = urls.first { $0.contains(ip) } ?? urls.first
            }
            if let scopes = XML.first("Scopes", in: xml) {
                for sc in scopes.split(whereSeparator: { $0 == " " || $0 == "\n" || $0 == "\t" }) {
                    let v = String(sc)
                    if let r = v.range(of: "onvif://www.onvif.org/name/") {
                        cam.name = String(v[r.upperBound...]).removingPercentEncoding?.replacingOccurrences(of: "_", with: " ")
                    } else if let r = v.range(of: "onvif://www.onvif.org/hardware/") {
                        cam.hardware = String(v[r.upperBound...]).removingPercentEncoding
                    }
                }
            }
            found[ip] = cam
        }
        return found
    }

    private static func probeMessage() -> String {
        """
        <?xml version="1.0" encoding="UTF-8"?>\
        <e:Envelope xmlns:e="http://www.w3.org/2003/05/soap-envelope" \
        xmlns:w="http://schemas.xmlsoap.org/ws/2004/08/addressing" \
        xmlns:d="http://schemas.xmlsoap.org/ws/2005/04/discovery" \
        xmlns:dn="http://www.onvif.org/ver10/network/wsdl">\
        <e:Header><w:MessageID>uuid:\(UUID().uuidString.lowercased())</w:MessageID>\
        <w:To e:mustUnderstand="true">urn:schemas-xmlsoap-org:ws:2005:04:discovery</w:To>\
        <w:Action e:mustUnderstand="true">http://schemas.xmlsoap.org/ws/2005/04/discovery/Probe</w:Action>\
        </e:Header><e:Body><d:Probe><d:Types>dn:NetworkVideoTransmitter</d:Types></d:Probe></e:Body></e:Envelope>
        """
    }

    /// Какие адреса принимают TCP-соединение на заданных портах (пачками, таймаут 0,6 с).
    static func scanPorts(hosts: [UInt32], ports: [Int], timeout: Int32 = 600) -> [String: [Int]] {
        var targets: [(UInt32, Int)] = []
        for h in hosts { for p in ports { targets.append((h, p)) } }
        var open: [String: [Int]] = [:]
        let batch = 128
        var i = 0
        while i < targets.count {
            let part = targets[i..<min(i + batch, targets.count)]
            i += batch
            var fds: [(fd: Int32, host: UInt32, port: Int)] = []
            for (h, port) in part {
                let s = socket(AF_INET, SOCK_STREAM, IPPROTO_TCP)
                guard s >= 0 else { continue }
                var one: Int32 = 1
                setsockopt(s, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
                _ = fcntl(s, F_SETFL, fcntl(s, F_GETFL, 0) | O_NONBLOCK)
                var addr = sockaddr_in()
                addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
                addr.sin_family = sa_family_t(AF_INET)
                addr.sin_port = in_port_t(port).bigEndian
                addr.sin_addr.s_addr = h.bigEndian
                let r = withUnsafePointer(to: &addr) {
                    $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(s, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
                }
                if r == 0 {
                    open[ipString(h), default: []].append(port)
                    close(s)
                } else if errno == EINPROGRESS {
                    fds.append((s, h, port))
                } else {
                    close(s)
                }
            }
            var pfds = fds.map { pollfd(fd: $0.fd, events: Int16(POLLOUT), revents: 0) }
            let deadline = Date().addingTimeInterval(Double(timeout) / 1000)
            var pending = pfds.count
            while pending > 0 && Date() < deadline {
                let ms = Int32(max(1, deadline.timeIntervalSinceNow * 1000))
                guard poll(&pfds, nfds_t(pfds.count), ms) > 0 else { break }
                for k in pfds.indices where pfds[k].fd >= 0 && pfds[k].revents != 0 {
                    var err: Int32 = 0
                    var len = socklen_t(MemoryLayout<Int32>.size)
                    getsockopt(pfds[k].fd, SOL_SOCKET, SO_ERROR, &err, &len)
                    if err == 0 && pfds[k].revents & Int16(POLLOUT) != 0 {
                        open[ipString(fds[k].host), default: []].append(fds[k].port)
                    }
                    pfds[k].fd = -1   // poll пропускает отрицательные
                    pending -= 1
                }
            }
            for f in fds { close(f.fd) }
        }
        return open
    }
}

// MARK: - Мини-разбор XML (без учёта префиксов пространств имён)

nonisolated enum XML {
    /// Содержимое первого элемента с таким локальным именем.
    static func first(_ tag: String, in xml: String) -> String? {
        all(tag, in: xml).first
    }

    static func all(_ tag: String, in xml: String) -> [String] {
        let pattern = "<(?:[A-Za-z0-9_]+:)?\(tag)(?:\\s[^>]*)?>([\\s\\S]*?)</(?:[A-Za-z0-9_]+:)?\(tag)>"
        guard let re = try? NSRegularExpression(pattern: pattern) else { return [] }
        let ns = xml as NSString
        return re.matches(in: xml, range: NSRange(location: 0, length: ns.length)).map {
            unescape(ns.substring(with: $0.range(at: 1)).trimmingCharacters(in: .whitespacesAndNewlines))
        }
    }

    /// Значения атрибута у элементов с таким локальным именем.
    static func attributes(_ attr: String, of tag: String, in xml: String) -> [String] {
        let pattern = "<(?:[A-Za-z0-9_]+:)?\(tag)\\s[^>]*\\b\(attr)=\"([^\"]+)\""
        guard let re = try? NSRegularExpression(pattern: pattern) else { return [] }
        let ns = xml as NSString
        return re.matches(in: xml, range: NSRange(location: 0, length: ns.length)).map { ns.substring(with: $0.range(at: 1)) }
    }

    static func unescape(_ s: String) -> String {
        s.replacingOccurrences(of: "&amp;", with: "&")
            .replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">")
            .replacingOccurrences(of: "&quot;", with: "\"")
            .replacingOccurrences(of: "&apos;", with: "'")
    }
}

// MARK: - ONVIF: получение RTSP-ссылки

nonisolated enum ONVIFClient {
    enum ONVIFError: LocalizedError {
        case unauthorized
        case noMedia
        case noProfiles
        case noURI
        case http(Int)

        var errorDescription: String? {
            switch self {
            case .unauthorized: return "Неверный логин или пароль камеры"
            case .noMedia: return "Камера не сообщила адрес видеосервиса"
            case .noProfiles: return "В камере нет видеопрофилей"
            case .noURI: return "Камера не отдала RTSP-ссылку"
            case .http(let c): return "Камера ответила HTTP \(c)"
            }
        }
    }

    struct StreamInfo: Sendable {
        var uri: String
        var profile: String
        var profilesCount: Int
    }

    /// RTSP-ссылка дополнительного потока (второй профиль; если его нет — основной).
    static func streamURI(deviceURL: String, user: String, password: String) throws -> StreamInfo {
        // 1. адрес Media-сервиса
        let caps = try call(deviceURL, user: user, password: password,
                            body: "<GetCapabilities xmlns=\"http://www.onvif.org/ver10/device/wsdl\"><Category>All</Category></GetCapabilities>")
        var mediaURL = deviceURL
        if let media = XML.first("Media", in: caps), let x = XML.first("XAddr", in: media) { mediaURL = x }

        // 2. профили
        let prof = try call(mediaURL, user: user, password: password,
                            body: "<GetProfiles xmlns=\"http://www.onvif.org/ver10/media/wsdl\"/>")
        let tokens = XML.attributes("token", of: "Profiles", in: prof)
        guard !tokens.isEmpty else { throw ONVIFError.noProfiles }
        let token = tokens.count > 1 ? tokens[1] : tokens[0]

        // 3. ссылка
        let uriXML = try call(mediaURL, user: user, password: password, body: """
            <GetStreamUri xmlns="http://www.onvif.org/ver10/media/wsdl"><StreamSetup>\
            <Stream xmlns="http://www.onvif.org/ver10/schema">RTP-Unicast</Stream>\
            <Transport xmlns="http://www.onvif.org/ver10/schema"><Protocol>RTSP</Protocol></Transport>\
            </StreamSetup><ProfileToken>\(token)</ProfileToken></GetStreamUri>
            """)
        guard let uri = XML.first("Uri", in: uriXML), uri.lowercased().hasPrefix("rtsp") else { throw ONVIFError.noURI }
        return StreamInfo(uri: uri, profile: token, profilesCount: tokens.count)
    }

    /// SOAP-запрос с WS-Security (UsernameToken digest) и, если камера просит, HTTP Digest.
    private static func call(_ url: String, user: String, password: String, body: String) throws -> String {
        let envelope = """
            <?xml version="1.0" encoding="UTF-8"?>\
            <s:Envelope xmlns:s="http://www.w3.org/2003/05/soap-envelope"><s:Header>\(security(user: user, password: password))</s:Header>\
            <s:Body xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance" xmlns:xsd="http://www.w3.org/2001/XMLSchema">\(body)</s:Body></s:Envelope>
            """
        let r = try HTTP.post(url, body: envelope, contentType: "application/soap+xml; charset=utf-8", user: user, password: password)
        let text = r.body
        if r.code == 401 || text.contains("NotAuthorized") || text.contains("FailedAuthentication") {
            throw ONVIFError.unauthorized
        }
        guard (200..<300).contains(r.code) else {
            // ошибка SOAP с кодом 400/500 — покажем её текст, если есть
            if let reason = XML.first("Text", in: text) { throw CloudError.message("Камера: \(reason)") }
            throw ONVIFError.http(r.code)
        }
        return text
    }

    private static func security(user: String, password: String) -> String {
        guard !user.isEmpty else { return "" }
        var nonce = [UInt8](repeating: 0, count: 16)
        for i in nonce.indices { nonce[i] = UInt8.random(in: 0...255) }
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        let created = f.string(from: Date())
        var data = Data(nonce)
        data.append(Data(created.utf8))
        data.append(Data(password.utf8))
        let digest = Data(Insecure.SHA1.hash(data: data)).base64EncodedString()
        return """
            <Security s:mustUnderstand="1" xmlns="http://docs.oasis-open.org/wss/2004/01/oasis-200401-wss-wssecurity-secext-1.0.xsd">\
            <UsernameToken><Username>\(user)</Username>\
            <Password Type="http://docs.oasis-open.org/wss/2004/01/oasis-200401-wss-username-token-profile-1.0#PasswordDigest">\(digest)</Password>\
            <Nonce EncodingType="http://docs.oasis-open.org/wss/2004/01/oasis-200401-soap-message-security-1.0#Base64Binary">\(Data(nonce).base64EncodedString())</Nonce>\
            <Created xmlns="http://docs.oasis-open.org/wss/2004/01/oasis-200401-wss-wssecurity-utility-1.0.xsd">\(created)</Created>\
            </UsernameToken></Security>
            """
    }
}

// MARK: - Простой HTTP по сокету (без ATS, для камер в локальной сети)

nonisolated enum HTTP {
    struct Response {
        var code: Int
        var headers: [String: String]
        var body: String
    }

    static func post(_ urlString: String, body: String, contentType: String, user: String, password: String) throws -> Response {
        guard let u = URLComponents(string: urlString), let host = u.host else { throw ONVIFClient.ONVIFError.noMedia }
        let port = u.port ?? 80
        var path = u.percentEncodedPath.isEmpty ? "/" : u.percentEncodedPath
        if let q = u.percentEncodedQuery { path += "?" + q }

        var r = try once(host: host, port: port, path: path, body: body, contentType: contentType, auth: nil)
        if r.code == 401, !user.isEmpty, let w = r.headers["www-authenticate"] {
            r = try once(host: host, port: port, path: path, body: body, contentType: contentType,
                         auth: authorization(challenge: w, method: "POST", uri: path, user: user, password: password))
        }
        return r
    }

    private static func once(host: String, port: Int, path: String, body: String, contentType: String, auth: String?) throws -> Response {
        let fd = try RTSPConnection.connect(host: host, port: port)
        defer { close(fd) }
        let bodyBytes = Array(body.utf8)
        var head = "POST \(path) HTTP/1.1\r\nHost: \(host):\(port)\r\nContent-Type: \(contentType)\r\n"
        head += "Content-Length: \(bodyBytes.count)\r\nConnection: close\r\nUser-Agent: Mantis\r\n"
        if let auth { head += "Authorization: \(auth)\r\n" }
        head += "\r\n"
        let out = Array(head.utf8) + bodyBytes
        var sent = 0
        while sent < out.count {
            let n = out.withUnsafeBytes { send(fd, $0.baseAddress! + sent, out.count - sent, 0) }
            if n <= 0 { throw RTSPSource.RTSPError.closed }
            sent += n
        }
        // читаем до закрытия соединения
        var data: [UInt8] = []
        var chunk = [UInt8](repeating: 0, count: 16384)
        while true {
            let n = chunk.withUnsafeMutableBytes { recv(fd, $0.baseAddress, $0.count, 0) }
            if n <= 0 { break }
            data += chunk[0..<n]
            if data.count > 4_000_000 { break }
        }
        guard let sep = find(data, [13, 10, 13, 10]) else { throw RTSPSource.RTSPError.timeout }
        let headText = String(decoding: data[0..<sep], as: UTF8.self)
        let lines = headText.components(separatedBy: "\r\n")
        let parts = (lines.first ?? "").split(separator: " ")
        let code = parts.count > 1 ? Int(parts[1]) ?? 0 : 0
        var headers: [String: String] = [:]
        for l in lines.dropFirst() {
            guard let c = l.firstIndex(of: ":") else { continue }
            let k = l[..<c].trimmingCharacters(in: .whitespaces).lowercased()
            let v = l[l.index(after: c)...].trimmingCharacters(in: .whitespaces)
            headers[k] = headers[k].map { $0 + ", " + v } ?? v
        }
        var bodyData = Array(data[(sep + 4)...])
        if headers["transfer-encoding"]?.lowercased().contains("chunked") == true { bodyData = dechunk(bodyData) }
        return Response(code: code, headers: headers, body: String(decoding: bodyData, as: UTF8.self))
    }

    private static func find(_ data: [UInt8], _ pattern: [UInt8]) -> Int? {
        guard data.count >= pattern.count else { return nil }
        for i in 0...(data.count - pattern.count) where data[i] == pattern[0] {
            if Array(data[i..<(i + pattern.count)]) == pattern { return i }
        }
        return nil
    }

    private static func dechunk(_ d: [UInt8]) -> [UInt8] {
        var out: [UInt8] = []
        var i = 0
        while i < d.count {
            guard let lineEnd = find(Array(d[i...]), [13, 10]) else { break }
            let sizeText = String(decoding: d[i..<(i + lineEnd)], as: UTF8.self).split(separator: ";").first ?? ""
            guard let size = Int(sizeText.trimmingCharacters(in: .whitespaces), radix: 16), size > 0 else { break }
            let start = i + lineEnd + 2
            guard start + size <= d.count else { out += d[start...]; break }
            out += d[start..<(start + size)]
            i = start + size + 2
        }
        return out
    }

    /// Заголовок Authorization для HTTP Basic или Digest (в т.ч. qop=auth).
    private static func authorization(challenge: String, method: String, uri: String, user: String, password: String) -> String {
        guard challenge.lowercased().contains("digest") else {
            return "Basic " + Data("\(user):\(password)".utf8).base64EncodedString()
        }
        func value(_ key: String) -> String? {
            guard let r = challenge.range(of: key + "=\"") else { return nil }
            return String(challenge[r.upperBound...].prefix { $0 != "\"" })
        }
        func md5(_ s: String) -> String { Insecure.MD5.hash(data: Data(s.utf8)).map { String(format: "%02x", $0) }.joined() }
        let realm = value("realm") ?? "", nonce = value("nonce") ?? ""
        let ha1 = md5("\(user):\(realm):\(password)"), ha2 = md5("\(method):\(uri)")
        var header = "Digest username=\"\(user)\", realm=\"\(realm)\", nonce=\"\(nonce)\", uri=\"\(uri)\""
        if let qop = value("qop"), qop.contains("auth") {
            let cnonce = String(UUID().uuidString.prefix(8)).lowercased(), nc = "00000001"
            let response = md5("\(ha1):\(nonce):\(nc):\(cnonce):auth:\(ha2)")
            header += ", qop=auth, nc=\(nc), cnonce=\"\(cnonce)\", response=\"\(response)\""
        } else {
            header += ", response=\"\(md5("\(ha1):\(nonce):\(ha2)"))\""
        }
        if let opaque = value("opaque") { header += ", opaque=\"\(opaque)\"" }
        return header
    }
}
