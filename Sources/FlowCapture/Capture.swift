import Foundation

enum Capture {
    /// Freezes `frame` (global points, origin top-left) to a PNG using the system tool, which honours the Screen Recording grant.
    static func screen(frame: CGRect, to url: URL) -> Bool {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
        p.arguments = ["-x", "-R", "\(Int(frame.minX)),\(Int(frame.minY)),\(Int(frame.width)),\(Int(frame.height))", url.path]
        try? p.run()
        p.waitUntilExit()
        return FileManager.default.fileExists(atPath: url.path)
    }
}
