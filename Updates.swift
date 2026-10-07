import Foundation

/// Asks GitHub for the newest TypeThru release. The request carries only the app name and
/// version (as the User-Agent); nothing is downloaded or installed.
enum Updates {
    struct Release: Equatable {
        let version: String
        let page: URL
    }

    static let feed = URL(string: "https://api.github.com/repos/sayre4ux/TypeThru/releases?per_page=10")!

    static var currentVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
    }

    /// "v0.3.0-beta" → [0, 3, 0]
    static func numbers(_ version: String) -> [Int] {
        version.drop { !$0.isNumber }.prefix { $0.isNumber || $0 == "." }
            .split(separator: ".").compactMap { Int($0) }
    }

    static func isNewer(_ candidate: String, than current: String) -> Bool {
        let a = numbers(candidate), b = numbers(current)
        for index in 0..<max(a.count, b.count) {
            let x = index < a.count ? a[index] : 0, y = index < b.count ? b[index] : 0
            if x != y { return x > y }
        }
        return false
    }

    /// The newest release in a GitHub API response. Only release pages of this project are
    /// accepted, so the Download button cannot be pointed anywhere else.
    static func newest(from data: Data) -> Release? {
        guard let list = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { return nil }
        return list.compactMap { item -> Release? in
            guard item["draft"] as? Bool != true, let tag = item["tag_name"] as? String,
                  !numbers(tag).isEmpty, let link = item["html_url"] as? String, let page = URL(string: link),
                  page.scheme == "https", page.host == "github.com", page.path.hasPrefix("/sayre4ux/") else { return nil }
            return Release(version: numbers(tag).map(String.init).joined(separator: "."), page: page)
        }
        .max { isNewer($1.version, than: $0.version) }
    }

    /// Calls back on the main thread with a newer release, nil when up to date, or an error.
    static func check(completion: @escaping (Result<Release?, Error>) -> Void) {
        var request = URLRequest(url: feed, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 15)
        request.setValue("TypeThru/\(currentVersion)", forHTTPHeaderField: "User-Agent")
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        // Ephemeral: no cookies or cache kept on disk.
        URLSession(configuration: .ephemeral).dataTask(with: request) { data, response, error in
            let result: Result<Release?, Error>
            if let error {
                result = .failure(error)
            } else if let data, (response as? HTTPURLResponse)?.statusCode == 200 {
                let newest = newest(from: data)
                result = .success(newest.flatMap { isNewer($0.version, than: currentVersion) ? $0 : nil })
            } else {
                result = .failure(URLError(.badServerResponse))
            }
            DispatchQueue.main.async { completion(result) }
        }.resume()
    }
}
