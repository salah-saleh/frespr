import Foundation

// Writes timestamped lines to /tmp/frespr_debug.log
// Read with: tail -f /tmp/frespr_debug.log
func dbg(_ msg: String, file: String = #fileID, line: Int = #line) {
    let ts = DateFormatter.localizedString(from: Date(), dateStyle: .none, timeStyle: .medium)
    let src = URL(fileURLWithPath: file).lastPathComponent
    let line = "[\(ts)] \(src):\(line) \(msg)\n"
    if let data = line.data(using: .utf8) {
        let url = URL(fileURLWithPath: "/tmp/frespr_debug.log")
        if let fh = try? FileHandle(forWritingTo: url) {
            fh.seekToEndOfFile()
            fh.write(data)
            try? fh.close()
        } else {
            try? data.write(to: url)
        }
    }
}
