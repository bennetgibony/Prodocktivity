import AppKit
import SwiftUI

// Dragging pins, tabs and apps around the bar.

/// Bridges "Pin to Top" from browser rows to the apps model (set by SidebarView's owner).
@MainActor enum TabDrag {
    static var current: String?
    static var currentItem: BrowserItem?
    static var libraryItem: String?
    /// The space an app row was dragged out of.
    static var appSourceSpace: String?

    /// Forgets a sidebar row drag (e.g. one that was cancelled) when an app drag starts.
    static func clearSidebarDrag() {
        current = nil; currentItem = nil; libraryItem = nil; appSourceSpace = nil
    }
    static var pin: ((BrowserItem) -> Void)?
}

/// Shared drag feedback (which folder is being hovered).
@MainActor final class DragState: ObservableObject {
    static let shared = DragState()
    @Published var folderTarget: String?
}

/// Sidebar pins follow the cursor while dragging (live reorder); folders light up and
/// take the item on drop; open tabs dropped on the pins become pins.
struct LibraryDropDelegate: DropDelegate {
    let targetID: String?
    let intoFolder: Bool
    let library: Library?

    private var spaceID: String? {
        guard let library, let targetID else { return nil }
        return library.spaces.first(where: { Library.contains($0.pinned, id: targetID) })?.id
    }

    func dropEntered(info: DropInfo) {
        MainActor.assumeIsolated {
            guard let library, let targetID, let spaceID else { return }
            if intoFolder {
                DS.Motion.perform(DS.Motion.quick) { DragState.shared.folderTarget = targetID }
            } else if let moving = TabDrag.libraryItem, moving != targetID {
                DS.Motion.perform(DS.Motion.standard) {
                    library.moveLive(moving, over: targetID, space: spaceID)
                }
            }
        }
    }

    func dropExited(info: DropInfo) {
        MainActor.assumeIsolated {
            if intoFolder, DragState.shared.folderTarget == targetID {
                DS.Motion.perform(DS.Motion.quick) { DragState.shared.folderTarget = nil }
            }
        }
    }

    func dropUpdated(info: DropInfo) -> DropProposal? { DropProposal(operation: .move) }

    func performDrop(info: DropInfo) -> Bool {
        MainActor.assumeIsolated {
            defer {
                TabDrag.libraryItem = nil; TabDrag.current = nil; TabDrag.currentItem = nil
                DragState.shared.folderTarget = nil
            }
            guard let library, let targetID, let spaceID else { return false }
            if let moving = TabDrag.libraryItem {
                // Already moved live; a drop on a folder puts it inside.
                if intoFolder, moving != targetID {
                    DS.Motion.perform(DS.Motion.standard) {
                        library.move(moving, intoFolder: targetID, space: spaceID)
                    }
                }
                return true
            }
            // An app dragged from the list or the pin area joins the space (or the folder).
            if let appID = DuplicateActions.apps?.draggingID {
                DuplicateActions.apps?.draggingID = nil
                guard !library.containsApp(appID, inSpace: spaceID) || intoFolder else { return true }
                if intoFolder { library.removeApp(appID, fromSpace: spaceID) }
                DS.Motion.perform(DS.Motion.standard) {
                    library.add(.app(appID, title: DuplicateActions.apps?.displayName(for: appID) ?? appID), toSpace: spaceID,
                                inFolder: intoFolder ? targetID : nil, before: intoFolder ? nil : targetID)
                }
                return true
            }
            // An open tab dropped on the pins becomes a pin right there.
            if let tab = TabDrag.currentItem {
                DS.Motion.perform(DS.Motion.standard) {
                    library.add(.site(tab.title, tab.url, arcTabID: tab.id), toSpace: spaceID,
                                inFolder: intoFolder ? targetID : nil, before: intoFolder ? nil : targetID)
                }
                return true
            }
            return false
        }
    }
}

/// Live reordering of a space's apps; an open app dropped here joins the space.
struct SpaceAppDropDelegate: DropDelegate {
    let target: String
    let spaceID: String?
    let apps: AppsModel

    func dropEntered(info: DropInfo) {
        MainActor.assumeIsolated {
            guard let spaceID, let dragging = apps.draggingID, dragging != target,
                  apps.isApp(dragging, inSpace: spaceID) else { return }
            DS.Motion.perform(DS.Motion.standard) {
                apps.moveSpaceApp(dragging, over: target, space: spaceID)
            }
        }
    }

    func dropUpdated(info: DropInfo) -> DropProposal? { DropProposal(operation: .move) }

    func performDrop(info: DropInfo) -> Bool {
        MainActor.assumeIsolated {
            defer { apps.draggingID = nil }
            guard let spaceID, let dragging = apps.draggingID else { return false }
            if !apps.isApp(dragging, inSpace: spaceID) {
                DS.Motion.perform(DS.Motion.standard) { apps.addApp(dragging, toSpace: spaceID) }
            }
            return true
        }
    }
}

/// The floating pill shown under the cursor while dragging.
struct DragPreview: View {
    let title: String
    var icon: Image?
    var favicon: String?

    var body: some View {
        // Lifted: `raised`, floating elevation, 98 % scale.
        HStack(spacing: DS.Space.s) {
            Group {
                if let icon { icon.resizable().scaledToFit() } else { FaviconView(host: favicon) }
            }
            .frame(width: DS.Size.icon, height: DS.Size.icon)
            Text(title).textRole(.body).foregroundStyle(Palette.text).lineLimit(1)
        }
        .padding(.horizontal, DS.Space.rowInset)
        .frame(width: DS.Size.dragPreview, height: DS.Size.control, alignment: .leading)
        .background(Palette.raised, in: RoundedRectangle(cornerRadius: DS.Radius.s, style: .continuous))
        .elevation(.floating)
        .scaleEffect(DS.Motion.pressScale)
        .designRoot()
    }
}
