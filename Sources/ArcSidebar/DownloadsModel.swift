import AppKit

struct DownloadItem: Identifiable, Equatable {
    let url: URL
    let added: Date
    /// Being written by the built-in browser right now (it writes to the final name).
    var downloading = false
    var id: URL { url }
    var name: String { url.lastPathComponent }
    /// Partial browser downloads (Chromium/Arc use .crdownload, Safari .download), or one of ours.
    var isInProgress: Bool { downloading || ["crdownload", "download", "part"].contains(url.pathExtension.lowercased()) }
}

/// Recent files in ~/Downloads, updated live while the folder changes.
@MainActor
final class DownloadsModel: ObservableObject {
    @Published private(set) var items: [DownloadItem] = []
    @Published private(set) var accessDenied = false
    @Published var expanded = false

    let folder = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask)[0]
    private var source: DispatchSourceFileSystemObject?
    private var pendingReload: DispatchWorkItem?

    init() {
        reload()
        watch()
        WebBrowser.shared.onDownloadsChanged = { [weak self] in self?.reload() }
    }

    func reload() {
        let keys: [URLResourceKey] = [.addedToDirectoryDateKey, .creationDateKey]
        do {
            let urls = try FileManager.default.contentsOfDirectory(
                at: folder, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles]
            )
            let running = Set(WebBrowser.shared.activeDownloads.map(\.standardizedFileURL.path))
            let list = urls.map { url -> DownloadItem in
                let values = try? url.resourceValues(forKeys: Set(keys))
                return DownloadItem(url: url, added: values?.addedToDirectoryDate ?? values?.creationDate ?? .distantPast,
                                    downloading: running.contains(url.standardizedFileURL.path))
            }
            .sorted { $0.added > $1.added }
            let top = Array(list.prefix(20))
            if top != items { items = top }
            accessDenied = false
        } catch {
            accessDenied = true
        }
    }

    private func watch() {
        let fd = Darwin.open(folder.path, O_EVTONLY)
        guard fd >= 0 else { return }
        let src = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd, eventMask: [.write, .rename, .delete], queue: .main)
        src.setEventHandler { [weak self] in
            MainActor.assumeIsolated { self?.scheduleReload() }
        }
        src.setCancelHandler { Darwin.close(fd) }
        src.resume()
        source = src
    }

    private func scheduleReload() {
        pendingReload?.cancel()
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated { self?.reload() }
        }
        pendingReload = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3, execute: work)
    }

    func open(_ item: DownloadItem) { NSWorkspace.shared.open(item.url) }
    func reveal(_ item: DownloadItem) { NSWorkspace.shared.activateFileViewerSelecting([item.url]) }
    func openFolder() { NSWorkspace.shared.open(folder) }
    func moveToTrash(_ item: DownloadItem) {
        try? FileManager.default.trashItem(at: item.url, resultingItemURL: nil)
        reload()
    }

    func openPrivacySettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_FilesAndFolders") {
            NSWorkspace.shared.open(url)
        }
    }

    /// File icons, read once per file (the list redraws on every hover).
    private var icons: [URL: NSImage] = [:]
    func icon(for item: DownloadItem) -> NSImage {
        if let icon = icons[item.url] { return icon }
        let icon = NSWorkspace.shared.icon(forFile: item.url.path)
        if icons.count > 100 { icons.removeAll() }
        icons[item.url] = icon
        return icon
    }
}
