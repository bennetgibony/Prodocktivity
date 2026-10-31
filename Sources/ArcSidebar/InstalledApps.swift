import AppKit

/// Every installed app, also in subfolders (e.g. /Applications/Stata/StataSE.app).
enum InstalledApps {
    struct App: Identifiable {
        let fileName: String
        let name: String
        let url: URL
        let id: String // bundle identifier
    }

    /// Safari lives in the Cryptex folder: /Applications only has a hidden link to it.
    static let standardFolders = ["/Applications", "/System/Applications", "/System/Cryptexes/App/System/Applications",
                                  "/System/Library/CoreServices/Applications", NSHomeDirectory() + "/Applications"]

    static func scan(folders roots: [String] = standardFolders, addFinder: Bool = true) -> [App] {
        var seen = Set<String>()
        var apps: [App] = []
        func visit(_ dir: URL, depth: Int) {
            guard let items = try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.isDirectoryKey],
                                                                         options: [.skipsHiddenFiles]) else { return }
            for item in items {
                // Safari (and other system apps) sit in /Applications as symlinks into the system.
                let url = item.resolvingSymlinksInPath()
                if url.pathExtension == "app" {
                    guard let id = Bundle(url: url)?.bundleIdentifier, seen.insert(id).inserted else { continue }
                    let shown = FileManager.default.displayName(atPath: url.path).replacingOccurrences(of: ".app", with: "")
                    apps.append(App(fileName: url.deletingPathExtension().lastPathComponent, name: shown, url: url, id: id))
                } else if depth < 2, (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true {
                    visit(url, depth: depth + 1)
                }
            }
        }
        for root in roots { visit(URL(fileURLWithPath: root), depth: 0) }
        // Finder lives on its own in CoreServices.
        let finder = URL(fileURLWithPath: "/System/Library/CoreServices/Finder.app")
        if addFinder, !seen.contains("com.apple.finder") {
            apps.append(App(fileName: "Finder", name: "Finder", url: finder, id: "com.apple.finder"))
        }
        return apps
    }
}
