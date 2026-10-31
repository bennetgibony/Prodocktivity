import AppKit
import SwiftUI

/// A "blob" that bleeds out of the sidebar's right edge at the bottom, in the sidebar's
/// colors, listing recent downloads. Clicking anywhere outside it closes it.
@MainActor
final class DownloadsBlobController {
    private let downloads: DownloadsModel
    private let anchor: () -> NSRect
    private var panel: NSPanel?
    private var monitors: [Any] = []
    private var lastClosed = Date.distantPast

    var isShown: Bool { panel?.isVisible == true }

    init(downloads: DownloadsModel, anchor: @escaping () -> NSRect) {
        self.downloads = downloads
        self.anchor = anchor
    }

    func toggle() {
        if isShown { close(); return }
        // The click that closed the blob (outside it) can also land on the toggle button.
        guard Date().timeIntervalSince(lastClosed) > 0.25 else { return }
        show()
    }

    func show() {
        downloads.reload()
        let sidebar = anchor()
        // Starts exactly at the sidebar's edge so the two read as one surface.
        let height = blobHeight + BleedShape.neck * 2
        let frame = NSRect(x: sidebar.maxX - 1, y: sidebar.minY + Layout.cornerRadius + DS.Space.xxs,
                           width: DS.Size.popoverWide + BleedShape.neck, height: height)

        let panel = self.panel ?? makePanel()
        self.panel = panel
        panel.contentView = FirstMouseHostingView(rootView: DownloadsBlobView(downloads: downloads, onOpen: { [weak self] in
            self?.close()
        }).designRoot())
        panel.setFrame(frame, display: false)
        panel.alphaValue = 1
        panel.orderFrontRegardless()
        installMonitors()
    }

    func close() {
        guard let panel, panel.isVisible else { return }
        removeMonitors()
        lastClosed = Date()
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? 0 : DS.Motion.fast
            panel.animator().alphaValue = 0
        } completionHandler: {
            panel.orderOut(nil)
        }
    }

    private var blobHeight: CGFloat {
        let rows = max(1, min(downloads.items.count, 10))
        let scale = CGFloat(Settings.shared.textScale)
        return DS.Size.control * scale + DS.Space.xl + CGFloat(rows) * DS.Size.barRow(.standard, scale: scale) + DS.Space.m
    }

    private func makePanel() -> NSPanel {
        let p = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        p.isFloatingPanel = true
        p.level = .floating
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        p.backgroundColor = .clear
        p.isOpaque = false
        p.hasShadow = true
        p.hidesOnDeactivate = false
        p.isReleasedWhenClosed = false
        return p
    }

    private func installMonitors() {
        removeMonitors()
        let mask: NSEvent.EventTypeMask = [.leftMouseDown, .rightMouseDown, .otherMouseDown]
        // Clicks in other apps.
        if let m = NSEvent.addGlobalMonitorForEvents(matching: mask, handler: { [weak self] _ in
            MainActor.assumeIsolated { self?.close() }
        }) { monitors.append(m) }
        // Clicks in our own windows (e.g. the sidebar), except inside the blob.
        if let m = NSEvent.addLocalMonitorForEvents(matching: mask, handler: { [weak self] event in
            MainActor.assumeIsolated {
                if let self, event.window !== self.panel { self.close() }
            }
            return event
        }) { monitors.append(m) }
    }

    private func removeMonitors() {
        monitors.forEach(NSEvent.removeMonitor)
        monitors.removeAll()
    }
}

/// Rounded card on the right with a concave "neck" on the left that flares into the
/// sidebar's edge, so the blob looks like it grows out of the bar.
struct BleedShape: Shape {
    static let neck: CGFloat = 14
    var radius: CGFloat = DS.Radius.xl

    func path(in rect: CGRect) -> Path {
        let n = Self.neck, r = radius
        let top = rect.minY + n, bottom = rect.maxY - n
        var p = Path()
        p.move(to: CGPoint(x: rect.minX, y: rect.minY))
        p.addQuadCurve(to: CGPoint(x: rect.minX + n, y: top), control: CGPoint(x: rect.minX, y: top))
        p.addLine(to: CGPoint(x: rect.maxX - r, y: top))
        p.addQuadCurve(to: CGPoint(x: rect.maxX, y: top + r), control: CGPoint(x: rect.maxX, y: top))
        p.addLine(to: CGPoint(x: rect.maxX, y: bottom - r))
        p.addQuadCurve(to: CGPoint(x: rect.maxX - r, y: bottom), control: CGPoint(x: rect.maxX, y: bottom))
        p.addLine(to: CGPoint(x: rect.minX + n, y: bottom))
        p.addQuadCurve(to: CGPoint(x: rect.minX, y: rect.maxY), control: CGPoint(x: rect.minX, y: bottom))
        p.closeSubpath()
        return p
    }
}

private struct DownloadsBlobView: View {
    @ObservedObject var downloads: DownloadsModel
    let onOpen: () -> Void
    @State private var appeared = false

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Space.xxs) {
            HStack {
                Text("Downloads").textRole(.headline).foregroundStyle(Palette.text)
                Spacer()
                IconButton(symbol: "folder", help: "Open the Downloads folder") {
                    downloads.openFolder()
                    onOpen()
                }
            }
            .padding(.leading, DS.Space.rowInset)
            .padding(.trailing, DS.Space.xxs)
            .frame(height: DS.Size.control)

            if downloads.accessDenied {
                PermissionCard(
                    symbol: "arrow.down.circle",
                    title: "Show your downloads",
                    message: "Allow proDOCKtivity to read your Downloads folder under Privacy & Security → Files & Folders.",
                    buttonTitle: "Open Settings…",
                    action: downloads.openPrivacySettings
                )
            } else if downloads.items.isEmpty {
                VStack(spacing: DS.Space.s) {
                    Image(systemName: "arrow.down.circle").font(.system(size: DS.Size.emptyIcon))
                        .foregroundStyle(Palette.text3)
                    Text("Nothing downloaded yet").textRole(.body).foregroundStyle(Palette.text2)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, DS.Space.xl)
            } else {
                ForEach(downloads.items.prefix(10)) { item in
                    DownloadRow(item: item, downloads: downloads, onOpen: onOpen)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(DS.Space.s)
        .padding(.leading, BleedShape.neck)
        .padding(.vertical, BleedShape.neck)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        // The bar's own color, so the blob reads as part of it.
        .background(BarBackground())
        .clipShape(BleedShape())
        .overlay(BleedShape().stroke(Palette.separator, lineWidth: DS.Line.hairline))
        // Stretches out of the bar's edge (150 ms, ease-out, no bounce; with Reduce Motion it's
        // simply there).
        .scaleEffect(x: appeared ? 1 : DS.Motion.stretchFrom.width, y: appeared ? 1 : DS.Motion.stretchFrom.height, anchor: .leading)
        .opacity(appeared ? 1 : 0)
        .onAppear { DS.Motion.perform(DS.Motion.slide) { appeared = true } }
    }
}

private struct DownloadRow: View {
    let item: DownloadItem
    @ObservedObject var downloads: DownloadsModel
    let onOpen: () -> Void
    @State private var hovering = false
    @ObservedObject private var settings = Settings.shared

    var body: some View {
        HStack(spacing: DS.Space.s) {
            Image(nsImage: downloads.icon(for: item))
                .resizable()
                .interpolation(.high)
                .frame(width: settings.rowIcon, height: settings.rowIcon)
            Text(item.name)
                .textRole(.body)
                .foregroundStyle(Palette.text)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: DS.Space.xs)
            if item.isInProgress {
                ProgressView().controlSize(.mini)
            } else if hovering {
                IconButton(symbol: "magnifyingglass", help: "Show in Finder", small: true) {
                    downloads.reveal(item)
                    onOpen()
                }
                .transition(.opacity)
            } else {
                Text(item.added, format: .relative(presentation: .numeric, unitsStyle: .narrow))
                    .textRole(.footnote)
                    .monospacedDigit()
                    .foregroundStyle(Palette.text3)
                    .lineLimit(1)
            }
        }
        .padding(.leading, DS.Space.rowInset)
        .padding(.trailing, DS.Space.xxs)
        .frame(height: settings.rowHeight)
        .background(RowBackground(selected: false, hovering: hovering))
        .contentShape(Rectangle())
        .onTapGesture {
            downloads.open(item)
            onOpen()
        }
        .onHover { h in DS.Motion.perform(DS.Motion.quick) { hovering = h } }
        .onDrag { NSItemProvider(contentsOf: item.url) ?? NSItemProvider() }
        .contextMenu {
            Button("Open") { downloads.open(item) }
            Button("Show in Finder") { downloads.reveal(item) }
            Divider()
            Button("Move to Trash") { downloads.moveToTrash(item) }
        }
        .help(item.url.path)
    }
}
