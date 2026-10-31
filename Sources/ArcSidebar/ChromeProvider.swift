import AppKit
import Carbon

/// Google Chrome via its AppleScript dictionary: for extensions (e.g. Claude in Chrome).
/// Chrome has no spaces, so its open tabs follow the sidebar's active space.
final class ChromeProvider: BrowserProvider, @unchecked Sendable {
    let displayName = "Chrome"
    let bundleID = "com.google.Chrome"
    var hasSpaces: Bool { false }
    static let spaceID = "chrome"

    private var handlerScript: NSAppleScript?

    private static let handlers = #"""
on fetchall()
	set US to character id 31
	set RS to character id 30
	with timeout of 8 seconds
	tell application id "com.google.Chrome"
		if (count of windows) is 0 then return ""
		set out to "A" & US & (id of active tab of window 1) & RS
		repeat with w in windows
			set tids to id of every tab of w
			set ttitles to title of every tab of w
			set turls to URL of every tab of w
			repeat with i from 1 to count of tids
				set out to out & "T" & US & (item i of tids) & US & (item i of ttitles) & US & (item i of turls) & RS
			end repeat
		end repeat
		return out
	end tell
	end timeout
end fetchall

on selecttab(tid)
	tell application id "com.google.Chrome"
		repeat with w in windows
			set i to 0
			repeat with t in tabs of w
				set i to i + 1
				if (id of t as text) is tid then
					set active tab index of w to i
					set index of w to 1
					activate
					return ""
				end if
			end repeat
		end repeat
	end tell
	return ""
end selecttab

on closetab(tid)
	tell application id "com.google.Chrome"
		repeat with w in windows
			repeat with t in tabs of w
				if (id of t as text) is tid then
					close t
					return ""
				end if
			end repeat
		end repeat
	end tell
	return ""
end closetab

on maketab(u)
	tell application id "com.google.Chrome"
		if (count of windows) is 0 then make new window
		tell window 1
			set t to make new tab with properties {URL:u}
			return (id of t) as text
		end tell
	end tell
end maketab

on seturl(u)
	tell application id "com.google.Chrome"
		if (count of windows) is 0 then make new window
		set URL of active tab of window 1 to u
	end tell
	return ""
end seturl

on navigate(what)
	tell application id "com.google.Chrome"
		tell active tab of window 1
			if what is "back" then
				go back
			else if what is "forward" then
				go forward
			else
				reload
			end if
		end tell
	end tell
	return ""
end navigate
"""#

    func fetch() throws -> BrowserSnapshot {
        guard runningApp != nil else { throw BrowserError.notRunning }
        return Self.snapshot(from: try call("fetchall"))
    }

    /// Turns the script's answer (records split by \u{1E}, fields by \u{1F}) into a snapshot.
    static func snapshot(from raw: String) -> BrowserSnapshot {
        var space = BrowserSpace(id: spaceID, title: "Chrome")
        var snap = BrowserSnapshot(activeSpaceID: spaceID)
        for record in raw.split(separator: "\u{1E}", omittingEmptySubsequences: true) {
            let f = record.split(separator: "\u{1F}", omittingEmptySubsequences: false).map(String.init)
            switch f.first {
            case "A" where f.count >= 2: snap.activeTabID = f[1]
            case "T" where f.count >= 4: space.unpinned.append(BrowserItem(id: f[1], title: f[2], url: f[3], kind: .tab))
            default: continue
            }
        }
        snap.spaces = [space]
        return snap
    }

    func select(_ tab: BrowserItem, spaceID: String?) throws { try call("selecttab", tab.id) }
    func close(_ tab: BrowserItem) throws { try call("closetab", tab.id) }
    func focus(spaceID: String) throws {}
    func open(url: String) throws { _ = try makeTab(url: url) }
    func navigate(_ action: NavigationAction) throws { try call("navigate", action.rawValue) }
    func load(url: String) throws { try call("seturl", url) }
    func makeTab(url: String) throws -> String { try call("maketab", url) }

    @discardableResult
    private func call(_ handler: String, _ args: String...) throws -> String {
        if handlerScript == nil {
            guard let script = NSAppleScript(source: Self.handlers) else { throw BrowserError.script("Couldn't build script") }
            var error: NSDictionary?
            script.compileAndReturnError(&error)
            if let error { throw BrowserError.script(error[NSAppleScript.errorMessage] as? String ?? "Compile error") }
            handlerScript = script
        }
        let event = NSAppleEventDescriptor(
            eventClass: AEEventClass(kASAppleScriptSuite), eventID: AEEventID(kASSubroutineEvent),
            targetDescriptor: .currentProcess(), returnID: AEReturnID(kAutoGenerateReturnID),
            transactionID: AETransactionID(kAnyTransactionID)
        )
        event.setParam(NSAppleEventDescriptor(string: handler), forKeyword: AEKeyword(keyASSubroutineName))
        let list = NSAppleEventDescriptor.list()
        for (i, a) in args.enumerated() { list.insert(NSAppleEventDescriptor(string: a), at: i + 1) }
        event.setParam(list, forKeyword: AEKeyword(keyDirectObject))
        var error: NSDictionary?
        let result = handlerScript!.executeAppleEvent(event, error: &error)
        if let error {
            let code = error[NSAppleScript.errorNumber] as? Int ?? 0
            switch code {
            case -1743, -1744: throw BrowserError.notAuthorized
            case -600, -609: throw BrowserError.notRunning
            case -1712: throw BrowserError.script("Chrome isn't responding.")
            default: throw BrowserError.script(error[NSAppleScript.errorMessage] as? String ?? "AppleScript error \(code)")
            }
        }
        return result.stringValue ?? ""
    }
}
