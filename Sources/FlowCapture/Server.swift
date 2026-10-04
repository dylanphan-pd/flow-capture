import Foundation
import Network

/// Loopback-only HTTP server the FigJam plugin polls. Every request needs the shared token (?t=...),
/// because CORS is open and any webpage could otherwise read screenshots from localhost.
///   GET  /captures            -> pending captures as JSON
///   GET  /history             -> captures already sent (for re-import)
///   GET  /captures/<id>.png   -> image bytes
///   POST /captures/<id>/ack   -> mark as delivered
///   POST /flows/<flowID>/discard -> delete a finished flow that was not sent
///   POST /flows/<flowID>/delete  -> delete a placed flow (history)
///   POST /flows/<flowID>/rename?name= -> rename a finished flow
///   POST /config?w=&h=&c=     -> plugin reports FigJam's sticky size and default colour (hex)
final class Server {
    static let port: UInt16 = 47653
    static var token: String {
        if let t = UserDefaults.standard.string(forKey: "serverToken") { return t }
        let t = UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
        UserDefaults.standard.set(t, forKey: "serverToken")
        return t
    }

    private var listener: NWListener?

    func start() {
        let params = NWParameters.tcp
        params.requiredInterfaceType = .loopback
        do {
            let l = try NWListener(using: params, on: NWEndpoint.Port(rawValue: Server.port)!)
            l.newConnectionHandler = { [weak self] conn in self?.handle(conn) }
            l.start(queue: .global(qos: .utility))
            listener = l
        } catch {
            NSLog("FlowCapture: server failed to start: \(error)")
        }
    }

    private func handle(_ conn: NWConnection) {
        conn.start(queue: .global(qos: .utility))
        conn.receive(minimumIncompleteLength: 1, maximumLength: 16 * 1024) { [weak self] data, _, _, _ in
            guard let self, let data, let req = String(data: data, encoding: .utf8) else { conn.cancel(); return }
            let parts = (req.components(separatedBy: "\r\n").first ?? "").split(separator: " ")
            guard parts.count >= 2 else { conn.cancel(); return }
            self.respond(method: String(parts[0]), target: String(parts[1]), on: conn)
        }
    }

    private func respond(method: String, target: String, on conn: NWConnection) {
        if method == "OPTIONS" { return send(204, "text/plain", Data(), on: conn) }

        let comps = URLComponents(string: "http://x" + target)
        let supplied = comps?.queryItems?.first(where: { $0.name == "t" })?.value
        guard supplied == Server.token else { return send(401, "text/plain", Data("unauthorized".utf8), on: conn) }

        let path = comps?.path ?? ""
        if method == "GET", path == "/captures" {
            let enc = JSONEncoder(); enc.dateEncodingStrategy = .iso8601
            let body = (try? enc.encode(Store.shared.pending())) ?? Data("[]".utf8)
            send(200, "application/json", body, on: conn)
        } else if method == "GET", path == "/history" {
            let enc = JSONEncoder(); enc.dateEncodingStrategy = .iso8601
            send(200, "application/json", (try? enc.encode(Store.shared.sentRecords())) ?? Data("[]".utf8), on: conn)
        } else if method == "GET", path.hasPrefix("/captures/"), path.hasSuffix(".png") {
            let id = String(path.dropFirst("/captures/".count).dropLast(".png".count))
            guard UUID(uuidString: id) != nil, let data = try? Data(contentsOf: Store.shared.imageURL(for: id)) else {
                return send(404, "text/plain", Data(), on: conn)
            }
            send(200, "image/png", data, on: conn)
        } else if method == "POST", path.hasPrefix("/captures/"), path.hasSuffix("/ack") {
            let id = String(path.dropFirst("/captures/".count).dropLast("/ack".count))
            Store.shared.markSent(id)
            send(200, "text/plain", Data("ok".utf8), on: conn)
        } else if method == "POST", path.hasPrefix("/flows/"), path.hasSuffix("/discard") {
            let id = String(path.dropFirst("/flows/".count).dropLast("/discard".count))
            guard UUID(uuidString: id) != nil else { return send(400, "text/plain", Data(), on: conn) }
            let n = Store.shared.discardReady(flowID: id)
            send(200, "text/plain", Data("\(n)".utf8), on: conn)
        } else if method == "POST", path.hasPrefix("/flows/"), path.hasSuffix("/delete") {
            let id = String(path.dropFirst("/flows/".count).dropLast("/delete".count))
            guard UUID(uuidString: id) != nil else { return send(400, "text/plain", Data(), on: conn) }
            send(200, "text/plain", Data("\(Store.shared.deleteSent(flowID: id))".utf8), on: conn)
        } else if method == "POST", path.hasPrefix("/flows/"), path.hasSuffix("/rename") {
            let id = String(path.dropFirst("/flows/".count).dropLast("/rename".count))
            let name = (comps?.queryItems ?? []).first(where: { $0.name == "name" })?.value?.trimmingCharacters(in: .whitespaces) ?? ""
            guard UUID(uuidString: id) != nil, !name.isEmpty else { return send(400, "text/plain", Data(), on: conn) }
            Store.shared.renameFlow(flowID: id, name: name)
            send(200, "text/plain", Data("ok".utf8), on: conn)
        } else if method == "POST", path == "/config" {
            // Plugin reports FigJam's native sticky size so the overlay can match it.
            let q = comps?.queryItems ?? []
            if let w = q.first(where: { $0.name == "w" })?.value.flatMap(Double.init),
               let h = q.first(where: { $0.name == "h" })?.value.flatMap(Double.init), w > 0, h > 0 {
                UserDefaults.standard.set(w, forKey: "stickyW"); UserDefaults.standard.set(h, forKey: "stickyH")
            }
            if let c = q.first(where: { $0.name == "c" })?.value { UserDefaults.standard.set(c, forKey: "stickyColor") }
            send(200, "text/plain", Data("ok".utf8), on: conn)
        } else {
            send(404, "text/plain", Data(), on: conn)
        }
    }

    private func send(_ status: Int, _ type: String, _ body: Data, on conn: NWConnection) {
        let head = "HTTP/1.1 \(status) \(status == 200 ? "OK" : "Status")\r\n" +
            "Content-Type: \(type)\r\nContent-Length: \(body.count)\r\n" +
            "Access-Control-Allow-Origin: *\r\nAccess-Control-Allow-Methods: GET, POST, OPTIONS\r\n" +
            "Access-Control-Allow-Headers: *\r\nConnection: close\r\n\r\n"
        conn.send(content: Data(head.utf8) + body, completion: .contentProcessed { _ in conn.cancel() })
    }
}
