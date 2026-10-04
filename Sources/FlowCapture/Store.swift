import AppKit

/// A vector annotation, stored in capture-local points (origin = top-left of the cropped screenshot, 1 unit = 1 screen point).
struct Annotation: Codable, Identifiable {
    enum Kind: String, Codable { case sticky, arrow, rect, oval, text }
    var id = UUID()
    var kind: Kind
    var x = 0.0, y = 0.0      // sticky: top-left; arrow: start; rect/oval/text: top-left corner
    var x2 = 0.0, y2 = 0.0    // arrow: end; rect/oval: bottom-right corner; text: right edge (x2 - x = wrap width)
    var text = ""
    var color = "yellow"      // sticky only: a StickyColor key
    var list = "none"         // sticky only: none | bullet | number
    var stroke = "red"        // arrow/rect/oval line colour and text colour: a StrokeColor key
    var weight = "medium"     // arrow/rect/oval: a LineWeight key
    var dashed = false        // arrow/rect/oval
    var size = "medium"       // text only: a TextSize key

    init(kind: Kind, x: Double = 0, y: Double = 0, x2: Double = 0, y2: Double = 0, text: String = "", color: String = "yellow",
         list: String = "none", stroke: String = "red", weight: String = "medium", dashed: Bool = false, size: String = "medium") {
        self.kind = kind; self.x = x; self.y = y; self.x2 = x2; self.y2 = y2; self.text = text; self.color = color; self.list = list
        self.stroke = stroke; self.weight = weight; self.dashed = dashed; self.size = size
    }

    // Annotations saved before colours, lists and shapes existed have no such keys.
    init(from d: Decoder) throws {
        let c = try d.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        kind = try c.decode(Kind.self, forKey: .kind)
        x = try c.decodeIfPresent(Double.self, forKey: .x) ?? 0; y = try c.decodeIfPresent(Double.self, forKey: .y) ?? 0
        x2 = try c.decodeIfPresent(Double.self, forKey: .x2) ?? 0; y2 = try c.decodeIfPresent(Double.self, forKey: .y2) ?? 0
        text = try c.decodeIfPresent(String.self, forKey: .text) ?? ""
        color = try c.decodeIfPresent(String.self, forKey: .color) ?? "yellow"
        list = try c.decodeIfPresent(String.self, forKey: .list) ?? "none"
        stroke = try c.decodeIfPresent(String.self, forKey: .stroke) ?? "red"
        weight = try c.decodeIfPresent(String.self, forKey: .weight) ?? "medium"
        dashed = try c.decodeIfPresent(Bool.self, forKey: .dashed) ?? false
        size = try c.decodeIfPresent(String.self, forKey: .size) ?? "medium"
    }
}

/// Sticky colours offered in the overlay: FigJam's exact sticky palette (FigJam only treats exact matches as palette colours).
/// Yellow is FigJam's own default, so the plugin leaves it untouched.
enum StickyColor: String, CaseIterable {
    case yellow, orange, red, pink, violet, blue, green, gray

    var hex: String {
        switch self {
        case .yellow: return FigJamMetrics.nativeYellowHex
        case .orange: return "#ffd3a8"; case .red: return "#ffb8a8"; case .pink: return "#ffa8db"
        case .violet: return "#d3bdff"; case .blue: return "#a8daff"; case .green: return "#b3efbd"; case .gray: return "#e6e6e6"
        }
    }
    var nsColor: NSColor { FigJamMetrics.color(hex: hex) }
}

/// Line / text colours for arrows, shapes and text: FigJam's exact connector palette (keep in sync with STROKE_COLORS in the plugin's code.js).
enum StrokeColor: String, CaseIterable {
    case red, orange, green, blue, violet, black, white
    var hex: String {
        switch self {
        case .red: return "#ff7556"; case .orange: return "#ff9e42"; case .green: return "#66d575"; case .blue: return "#3dadff"
        case .violet: return "#874fff"; case .black: return "#1e1e1e"; case .white: return "#ffffff"
        }
    }
    var nsColor: NSColor { FigJamMetrics.color(hex: hex) }
}

enum LineWeight: String, CaseIterable {
    case thin, medium, thick
    var points: CGFloat { switch self { case .thin: return 2; case .medium: return 3; case .thick: return 6 } }
}

enum TextSize: String, CaseIterable {
    case small, medium, large
    var points: CGFloat { switch self { case .small: return 16; case .medium: return 24; case .large: return 36 } }
    var label: String { switch self { case .small: return "S"; case .medium: return "M"; case .large: return "L" } }
}

/// Renders sticky text, with bullets or numbers when the sticky is a list.
enum StickyStyle {
    static func attributed(_ a: Annotation, fontSize: CGFloat) -> NSAttributedString {
        let indent = fontSize * 1.4
        let para = NSMutableParagraphStyle()
        para.tabStops = [NSTextTab(textAlignment: .left, location: indent)]
        let list = a.list != "none"
        if list { para.headIndent = indent; para.firstLineHeadIndent = 0 }
        let lines = a.text.components(separatedBy: "\n")
        let body = lines.enumerated().map { i, l in
            (list ? (a.list == "number" ? "\(i + 1).\t" : "•\t") : "") + l
        }.joined(separator: "\n")
        return NSAttributedString(string: body, attributes: [
            .font: NSFont.systemFont(ofSize: fontSize), .foregroundColor: NSColor.black, .paragraphStyle: para])
    }
}

struct CaptureRecord: Codable {
    let id: String
    let createdAt: Date
    let width: Double
    let height: Double
    var annotations: [Annotation]
    let flowID: String
    var flowName: String?   // set when the flow is finished
    var ready: Bool   // true once the user finished the flow; only ready captures are served to FigJam
    var sent: Bool
}

/// Captures live in ~/Library/Application Support/FlowCapture/. `sent == false` means queued for FigJam.
final class Store {
    static let shared = Store()
    let dir: URL
    private var records: [CaptureRecord] = []
    private var currentFlow: String {
        get { UserDefaults.standard.string(forKey: "currentFlow") ?? { let f = UUID().uuidString; UserDefaults.standard.set(f, forKey: "currentFlow"); return f }() }
        set { UserDefaults.standard.set(newValue, forKey: "currentFlow") }
    }
    private let lock = NSLock()
    private var indexURL: URL { dir.appendingPathComponent("index.json") }

    private init() {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        dir = base.appendingPathComponent("FlowCapture", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        if let data = try? Data(contentsOf: indexURL) {
            let dec = JSONDecoder(); dec.dateDecodingStrategy = .iso8601
            records = (try? dec.decode([CaptureRecord].self, from: data)) ?? []
        }
    }

    func imageURL(for id: String) -> URL { dir.appendingPathComponent("\(id).png") }

    func add(id: String, width: Double, height: Double, annotations: [Annotation]) {
        lock.lock(); defer { lock.unlock() }
        records.append(CaptureRecord(id: id, createdAt: Date(), width: width, height: height, annotations: annotations, flowID: currentFlow, flowName: nil, ready: false, sent: false))
        persist()
    }

    func pending() -> [CaptureRecord] {
        lock.lock(); defer { lock.unlock() }
        return records.filter { $0.ready && !$0.sent }
    }

    /// Steps captured in the flow that is still being recorded.
    func openFlowCount() -> Int {
        lock.lock(); defer { lock.unlock() }
        return records.filter { $0.flowID == currentFlow && !$0.ready }.count
    }

    /// Steps recorded so far in the flow being captured, oldest first.
    func openFlowRecords() -> [CaptureRecord] {
        lock.lock(); defer { lock.unlock() }
        return records.filter { $0.flowID == currentFlow && !$0.ready }
    }

    /// Releases the open flow to FigJam and starts a new one. Returns the number of steps released.
    @discardableResult
    func finishFlow(name: String) -> Int {
        lock.lock(); defer { lock.unlock() }
        var n = 0
        for i in records.indices where records[i].flowID == currentFlow && !records[i].ready { records[i].ready = true; records[i].flowName = name; n += 1 }
        if n > 0 { currentFlow = UUID().uuidString; persist() }
        return n
    }

    /// Captures already delivered to FigJam (kept until the user clears them), for re-importing.
    func sentRecords() -> [CaptureRecord] {
        lock.lock(); defer { lock.unlock() }
        return records.filter { $0.sent }
    }

    /// Undo for the last capture: removes the newest step of the flow being recorded.
    @discardableResult
    func removeLastStep() -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard let i = records.lastIndex(where: { $0.flowID == currentFlow && !$0.ready }) else { return false }
        try? FileManager.default.removeItem(at: imageURL(for: records[i].id))
        records.remove(at: i)
        persist()
        return true
    }

    /// Throws away every step of the flow being recorded. Returns the number of steps removed.
    @discardableResult
    func discardOpenFlow() -> Int {
        lock.lock(); defer { lock.unlock() }
        let doomed = records.filter { $0.flowID == currentFlow && !$0.ready }
        for r in doomed { try? FileManager.default.removeItem(at: imageURL(for: r.id)) }
        records.removeAll { $0.flowID == currentFlow && !$0.ready }
        if !doomed.isEmpty { persist() }
        return doomed.count
    }

    /// Deletes a flow that was already placed in FigJam (history). Returns the number of steps removed.
    @discardableResult
    func deleteSent(flowID: String) -> Int {
        lock.lock(); defer { lock.unlock() }
        let doomed = records.filter { $0.flowID == flowID && $0.sent }
        for r in doomed { try? FileManager.default.removeItem(at: imageURL(for: r.id)) }
        records.removeAll { $0.flowID == flowID && $0.sent }
        if !doomed.isEmpty { persist() }
        return doomed.count
    }

    /// Renames a finished flow, so the history shows the name that was actually used in FigJam.
    func renameFlow(flowID: String, name: String) {
        lock.lock(); defer { lock.unlock() }
        var changed = false
        for i in records.indices where records[i].flowID == flowID && records[i].ready { records[i].flowName = name; changed = true }
        if changed { persist() }
    }

    /// Deletes a finished flow that has not been sent to FigJam (records and images). The flow being recorded and
    /// flows already sent are never touched. Returns the number of steps removed.
    @discardableResult
    func discardReady(flowID: String) -> Int {
        lock.lock(); defer { lock.unlock() }
        guard flowID != currentFlow else { return 0 }
        let doomed = records.filter { $0.flowID == flowID && $0.ready && !$0.sent }
        for r in doomed { try? FileManager.default.removeItem(at: imageURL(for: r.id)) }
        records.removeAll { $0.flowID == flowID && $0.ready && !$0.sent }
        if !doomed.isEmpty { persist() }
        return doomed.count
    }

    func markSent(_ id: String) {
        lock.lock(); defer { lock.unlock() }
        if let i = records.firstIndex(where: { $0.id == id }) { records[i].sent = true; persist() }
    }

    // MARK: Storage

    private func size(of id: String) -> Int {
        (try? FileManager.default.attributesOfItem(atPath: imageURL(for: id).path)[.size] as? Int) ?? 0
    }

    /// Disk used by all capture images.
    func totalBytes() -> Int {
        lock.lock(); defer { lock.unlock() }
        return records.reduce(0) { $0 + size(of: $1.id) }
    }

    /// Disk used by captures already delivered to FigJam (the only ones that are safe to clear).
    func sentStats() -> (count: Int, bytes: Int) {
        lock.lock(); defer { lock.unlock() }
        let sent = records.filter { $0.sent }
        return (sent.count, sent.reduce(0) { $0 + size(of: $1.id) })
    }

    /// Deletes images and records of captures already sent to FigJam. Unsent captures are never touched.
    @discardableResult
    func clearSent() -> (count: Int, bytes: Int) {
        lock.lock(); defer { lock.unlock() }
        let sent = records.filter { $0.sent }
        let bytes = sent.reduce(0) { $0 + size(of: $1.id) }
        for r in sent { try? FileManager.default.removeItem(at: imageURL(for: r.id)) }
        records.removeAll { $0.sent }
        persist()
        return (sent.count, bytes)
    }

    private func persist() {
        let enc = JSONEncoder(); enc.dateEncodingStrategy = .iso8601
        try? enc.encode(records).write(to: indexURL)
    }
}

/// Native FigJam sticky size and default colour, reported by the plugin so the overlay draws stickies as FigJam will.
enum FigJamMetrics {
    static var stickyWidth: Double { stored("stickyW", 240) }
    static var stickyHeight: Double { stored("stickyH", 240) }

    /// FigJam's default sticky colour as measured by the plugin (fallback until the plugin has run once).
    static var nativeYellowHex: String { UserDefaults.standard.string(forKey: "stickyColor") ?? "#ffe299" }

    static func color(hex: String) -> NSColor {
        guard let n = Int(hex.replacingOccurrences(of: "#", with: ""), radix: 16) else { return NSColor(calibratedRed: 1, green: 0.85, blue: 0.4, alpha: 1) }
        return NSColor(calibratedRed: CGFloat((n >> 16) & 255) / 255, green: CGFloat((n >> 8) & 255) / 255,
                       blue: CGFloat(n & 255) / 255, alpha: 1)
    }

    private static func stored(_ key: String, _ fallback: Double) -> Double {
        let v = UserDefaults.standard.double(forKey: key)
        return v > 0 ? v : fallback
    }
}
