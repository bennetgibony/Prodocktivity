# proDOCKtivity design notes

Every design value (colors, the 16 accents, the 18 workspace colors, spacing, radius, sizes, text roles, motion,
elevation) lives in `Sources/ArcSidebar/Views/Theme.swift`; views use only those tokens. Dates, times and durations go through `Formats.swift` (24-hour time, weeks
start on Monday, "1 h 30"). Interface strings are collected in `Resources/Localizable.xcstrings`
(`scripts/strings.py extract` adds new ones; the build compiles translations into the app).

Default accent: Indigo. Paste: ⌘V without formatting, ⇧⌘V with.

## Icons (SF Symbols, one meaning each)

| Symbol | Means |
|---|---|
| `star` | Favorites |
| `square.stack.3d.up` | Workspaces |
| `magnifyingglass` | DOCKlight (search, ⌥Space; Spotlight keeps ⌘Space) |
| `sidebar.left` | The bar (show/hide, Settings › Bar & Docks); the menu bar item is its own template drawing (MenuBarIcon) |
| `plus` | Add (space, folder, pin) |
| `folder` / `folder.fill` | Folder open / closed |
| `globe` | Website, browser |
| `puzzlepiece.extension` | Web extensions |
| `arrow.down.circle` | Downloads |
| `rectangle.split.2x1` | Split screen |
| `snowflake` | Frozen (kept on one half) |
| `theatermasks.fill` | Private tab |
| `gearshape` | Settings (bar, bottom left, and the Settings window's General tab) |
| `ellipsis` | More (the bar's menu of secondary actions) |
| `macwindow.on.rectangle` | Windows: snapping (Accessibility), frame, per-app window rules |
| `trash` | Remove |
| `exclamationmark.triangle` | Something failed (with Retry) |
| `checkmark.circle` | Saved / done |
| `xmark` | Close or dismiss |

Settings panes: `gearshape` General, `paintbrush` Appearance, `square.stack.3d.up` Workspaces, `sidebar.left`
Bar & Docks, `macwindow.on.rectangle` Windows, `globe` Browser, `timer` Auto-Quit, `keyboard` Shortcuts,
`externaldrive` Data.

## What the marks in the bar mean (one meaning each)

| Mark | Means |
|---|---|
| Accent pill with an accent outline behind a row or tile | The one thing in front right now (an app, or the tab when the browser is in front): the accent a bit stronger than a Favorites square. Never more than one. |
| Stripes in the address row | Another app is in front; the row shows that app instead of a web address. |
| Medium-weight title, no pill | The browser's current tab while another app is in front. |
| Grey text | The app isn't open. Also "New Tab" and other placeholders. (No dot beside running apps.) |
| Short line under a Favorites tile | The app is open (running), like the Dock. |
| Hover square | The pointer is over it. |
| Red dot on an icon | The app or website has news (its Dock badge, or a count in the tab's title). |
| The workspace's accent | Focus, a drop target, switches in Settings, primary buttons, and the workspace's own marks: the square behind each Favorites icon, pinned folders, the address row, the new-folder button and the buttons at the bottom of the bar. |
| The workspace's color | The bar and frame background only. |

## Names

In the interface a space is called a **workspace**; Arc's own spaces keep their name. Favorites, pinned items and the rest
keep their names. In code and comments you will also meet **Pinwall** (= Favorites, the icon grid at the top), **Workbench**
(a workspace's pinned items and folders) and **Open area** (open tabs and apps).
