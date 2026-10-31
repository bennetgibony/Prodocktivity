import AppKit
import Security

/// Updates from GitHub: looks at the latest release of the repository named in Info.plist
/// (`PDUpdateRepository`, e.g. "owner/prodocktivity") at launch and every 6 hours. A newer version shows a
/// card at the bottom of the bar; Update downloads the release's .zip, checks that the new app is signed
/// by the same certificate as this one, swaps it in and starts it again.
/// Off while no repository is set, and in development builds (their own bundle id).
@MainActor
final class Updater: ObservableObject {
    static let shared = Updater()

    struct Release: Equatable {
        let version: String
        let page: URL
        let download: URL
        let notes: String
    }

    enum State: Equatable { case idle, downloading, failed(String) }

    @Published private(set) var available: Release?
    @Published private(set) var state: State = .idle
    @Published private(set) var lastCheck: Date?

    private var timer: Timer?
    private let defaults = UserDefaults.standard

    static var repository: String? {
        let repo = (Bundle.main.object(forInfoDictionaryKey: "PDUpdateRepository") as? String ?? "").trimmingCharacters(in: .whitespaces)
        return repo.isEmpty ? nil : repo
    }
    static var currentVersion: String { Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0" }
    /// The shared app's id (scripts/package.sh); a development build has its own and updates by building.
    static let sharedBundleID = "app.prodocktivity.sidebar"
    static var isEnabled: Bool { repository != nil && Bundle.main.bundleIdentifier == sharedBundleID }

    func start() {
        guard Self.isEnabled else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 30) { [weak self] in MainActor.assumeIsolated { self?.check() } }
        timer = Timer.scheduledTimer(withTimeInterval: 6 * 3600, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.check() }
        }
        timer?.tolerance = 600
    }

    /// "1.10" is newer than "1.9"; a leading "v" doesn't count.
    nonisolated static func isNewer(_ candidate: String, than current: String) -> Bool {
        func parts(_ v: String) -> [Int] {
            v.trimmingCharacters(in: CharacterSet(charactersIn: "vV ")).split(separator: ".").map { Int($0.prefix { $0.isNumber }) ?? 0 }
        }
        let a = parts(candidate), b = parts(current)
        for i in 0..<max(a.count, b.count) {
            let x = i < a.count ? a[i] : 0, y = i < b.count ? b[i] : 0
            if x != y { return x > y }
        }
        return false
    }

    /// The release a GitHub "latest release" answer describes, if it has a .zip to download.
    nonisolated static func release(fromGitHub data: Data) -> Release? {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let tag = json["tag_name"] as? String, json["draft"] as? Bool != true, json["prerelease"] as? Bool != true,
              let page = (json["html_url"] as? String).flatMap(URL.init(string:)),
              let assets = json["assets"] as? [[String: Any]],
              let zip = assets.first(where: { ($0["name"] as? String)?.lowercased().hasSuffix(".zip") == true }),
              let download = (zip["browser_download_url"] as? String).flatMap(URL.init(string:)) else { return nil }
        return Release(version: tag.trimmingCharacters(in: CharacterSet(charactersIn: "vV")), page: page, download: download,
                       notes: json["body"] as? String ?? "")
    }

    func check(manually: Bool = false) {
        guard let repo = Self.repository, let url = URL(string: "https://api.github.com/repos/\(repo)/releases/latest") else { return }
        var request = URLRequest(url: url, timeoutInterval: 20)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        Task {
            let data = try? await URLSession.shared.data(for: request).0
            lastCheck = Date()
            guard let data, let release = Self.release(fromGitHub: data) else { return }
            let skipped = !manually && defaults.string(forKey: "update.later") == release.version
            if Self.isNewer(release.version, than: Self.currentVersion), !skipped {
                available = release
                Log.write("update: \(release.version) available")
            } else if manually {
                available = nil
            }
        }
    }

    /// Debug aid (ARCSIDEBAR_SNAPSHOT_UPDATE): shows the card for a made-up release.
    func pretend(version: String) {
        available = Release(version: version, page: URL(string: "https://github.com")!, download: URL(string: "https://github.com")!, notes: "")
    }

    /// Hides the card until a newer version than this one comes out.
    func later() {
        if let available { defaults.set(available.version, forKey: "update.later") }
        available = nil
        state = .idle
    }

    func install() {
        guard let release = available, state != .downloading else { return }
        state = .downloading
        Task {
            do {
                let app = try await Self.download(release)
                try Self.replaceAndRelaunch(with: app)
            } catch {
                Log.write("update failed: \(error)")
                state = .failed((error as? LocalizedError)?.errorDescription ?? error.localizedDescription)
            }
        }
    }

    enum Problem: LocalizedError {
        case noApp, wrongApp, notSigned, notWritable
        var errorDescription: String? {
            switch self {
            case .noApp: "The download didn't contain proDOCKtivity."
            case .wrongApp: "The download is a different app or not newer."
            case .notSigned: "The update isn't signed like your copy, so it wasn't installed. Download it from the release page instead."
            case .notWritable: "proDOCKtivity can't replace itself where it is. Move it to Applications, or download the update from the release page."
            }
        }
    }

    /// Downloads and unpacks the release; returns the new app after checking it.
    private static func download(_ release: Release) async throws -> URL {
        let (zip, _) = try await URLSession.shared.download(from: release.download)
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("proDOCKtivity-update-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let unzip = Process()
        unzip.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        unzip.arguments = ["-x", "-k", zip.path, folder.path]
        try unzip.run()
        unzip.waitUntilExit()
        guard unzip.terminationStatus == 0, let app = findApp(in: folder) else { throw Problem.noApp }
        guard let bundle = Bundle(url: app), bundle.bundleIdentifier == Bundle.main.bundleIdentifier,
              isNewer(bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0", than: currentVersion)
        else { throw Problem.wrongApp }
        guard signedLikeThisApp(app) else { throw Problem.notSigned }
        return app
    }

    private static func findApp(in folder: URL) -> URL? {
        let items = FileManager.default.enumerator(at: folder, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])
        while let url = items?.nextObject() as? URL {
            if url.pathExtension == "app" { return url }
        }
        return nil
    }

    /// The new app meets this app's designated requirement: same id, same signing certificate.
    static func signedLikeThisApp(_ app: URL) -> Bool {
        var me: SecCode?
        var mine: SecStaticCode?
        var requirement: SecRequirement?
        var other: SecStaticCode?
        guard SecCodeCopySelf([], &me) == errSecSuccess, let me,
              SecCodeCopyStaticCode(me, [], &mine) == errSecSuccess, let mine,
              SecCodeCopyDesignatedRequirement(mine, [], &requirement) == errSecSuccess, let requirement,
              SecStaticCodeCreateWithPath(app as CFURL, [], &other) == errSecSuccess, let other else { return false }
        return SecStaticCodeCheckValidity(other, SecCSFlags(rawValue: kSecCSCheckAllArchitectures), requirement) == errSecSuccess
    }

    /// A small helper waits until this app has quit, puts the new one in its place and opens it.
    private static func replaceAndRelaunch(with app: URL) throws {
        let target = Bundle.main.bundleURL
        guard FileManager.default.isWritableFile(atPath: target.deletingLastPathComponent().path) else { throw Problem.notWritable }
        let script = """
        while kill -0 "$0" 2>/dev/null; do sleep 0.2; done
        rm -rf "$2.old"; mv "$2" "$2.old" || exit 1
        if mv "$1" "$2"; then xattr -cr "$2"; rm -rf "$2.old"; else mv "$2.old" "$2"; fi
        /usr/bin/open "$2"
        """
        let helper = Process()
        helper.executableURL = URL(fileURLWithPath: "/bin/sh")
        helper.arguments = ["-c", script, String(getpid()), app.path, target.path]
        try helper.run()
        Log.write("update: installing \(app.path) over \(target.path)")
        NSApp.terminate(nil)
    }
}
