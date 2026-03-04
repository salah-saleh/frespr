import Foundation

final class UpdateChecker {
    var onUpdateAvailable: ((String, URL) -> Void)?

    private let apiURL = URL(string: "https://api.github.com/repos/salah-saleh/frespr/releases/latest")!
    private let checkIntervalSeconds: TimeInterval = 86400 // 24h

    func checkIfNeeded() {
        let lastCheck = AppSettings.shared.lastUpdateCheckDate
        if let last = lastCheck, Date().timeIntervalSince(last) < checkIntervalSeconds { return }
        performCheck()
    }

    private func performCheck() {
        Task { @MainActor in AppSettings.shared.lastUpdateCheckDate = Date() }
        var request = URLRequest(url: apiURL)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")

        URLSession.shared.dataTask(with: request) { [weak self] data, _, error in
            guard error == nil,
                  let data,
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let tag = json["tag_name"] as? String,
                  let htmlUrl = json["html_url"] as? String,
                  let releaseURL = URL(string: htmlUrl) else { return }

            let remoteVersion = tag.hasPrefix("v") ? String(tag.dropFirst()) : tag
            let localVersion = "1.0.0" // Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.0.0"

            guard Self.isNewer(remote: remoteVersion, than: localVersion) else { return }
            let callback = self?.onUpdateAvailable
            Task { @MainActor in callback?(tag, releaseURL) }
        }.resume()
    }

    private static func isNewer(remote: String, than local: String) -> Bool {
        let r = remote.split(separator: ".").compactMap { Int($0) }
        let l = local.split(separator: ".").compactMap { Int($0) }
        let count = max(r.count, l.count)
        for i in 0..<count {
            let rv = i < r.count ? r[i] : 0
            let lv = i < l.count ? l[i] : 0
            if rv != lv { return rv > lv }
        }
        return false
    }
}
