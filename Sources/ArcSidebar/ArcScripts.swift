import Foundation

// Generated from the AppleScript tested against Arc's scripting dictionary.
enum ArcScripts {
    static let fetch = #"""
set US to character id 31
set RS to character id 30
-- A busy or hung Arc must not hold up the bar for the default two minutes.
with timeout of 8 seconds
tell application id "company.thebrowser.Browser"
	set wIdx to 0
	repeat with wi from 1 to count of windows
		try
			if (count of spaces of window wi) > 0 then
				set wIdx to wi
				exit repeat
			end if
		end try
	end repeat
	if wIdx is 0 then return ""
	set activeTab to ""
	set activeSpace to ""
	try
		set activeTab to id of active tab of window wIdx
	end try
	try
		set activeSpace to id of active space of window wIdx
	end try
	set out to "A" & US & activeTab & US & activeSpace & RS
	repeat with si from 1 to count of spaces of window wIdx
		tell space si of window wIdx
			set sid to its id
			set spaceTitle to its title
			if spaceTitle is missing value then set spaceTitle to ""
			set out to out & "S" & US & sid & US & spaceTitle & RS
			set tids to id of every tab
			set ttitles to title of every tab
			set turls to URL of every tab
			set tlocs to location of every tab
		end tell
		repeat with i from 1 to count of tids
			set t1 to item i of ttitles
			if t1 is missing value then set t1 to ""
			set u1 to item i of turls
			if u1 is missing value then set u1 to ""
			set l1 to item i of tlocs
			if l1 is missing value then set l1 to ""
			set out to out & "T" & US & (item i of tids) & US & t1 & US & u1 & US & l1 & RS
		end repeat
	end repeat
	tell window wIdx
		set tids to id of every tab
		set ttitles to title of every tab
		set turls to URL of every tab
		set tlocs to location of every tab
	end tell
	repeat with i from 1 to count of tids
		set t1 to item i of ttitles
		if t1 is missing value then set t1 to ""
		set u1 to item i of turls
		if u1 is missing value then set u1 to ""
		set l1 to item i of tlocs
		if l1 is missing value then set l1 to ""
		set out to out & "W" & US & (item i of tids) & US & t1 & US & u1 & US & l1 & RS
	end repeat
	return out
end tell
end timeout
"""#
}

extension ArcScripts {
    /// Only the front window: active tab/space plus every tab (≈4x faster than `fetch`).
    static let fastFetch = #"""
set US to character id 31
set RS to character id 30
-- A busy or hung Arc must not hold up the bar for the default two minutes.
with timeout of 8 seconds
tell application id "company.thebrowser.Browser"
	if (count of windows) is 0 then return ""
	tell window 1
		set activeTab to ""
		set activeSpace to ""
		try
			set activeTab to id of active tab
		end try
		try
			set activeSpace to id of active space
		end try
		set tids to id of every tab
		set ttitles to title of every tab
		set turls to URL of every tab
		set tlocs to location of every tab
	end tell
	set out to "A" & US & activeTab & US & activeSpace & RS
	repeat with i from 1 to count of tids
		set t1 to item i of ttitles
		if t1 is missing value then set t1 to ""
		set u1 to item i of turls
		if u1 is missing value then set u1 to ""
		set l1 to item i of tlocs
		if l1 is missing value then set l1 to ""
		set out to out & "W" & US & (item i of tids) & US & t1 & US & u1 & US & l1 & RS
	end repeat
	return out
end tell
end timeout
"""#

    /// Compiled once; called as handlers with arguments (no recompiling per click).
    static let handlers = #"""
on selecttab(tid, sid, u)
	tell application id "company.thebrowser.Browser"
		tell window 1
			try
				tell tab id tid to select
			on error
				try
					if sid is not "" then tell space id sid to focus
					tell tab id tid to select
				on error
					if u is not "" then open location u
				end try
			end try
		end tell
	end tell
	return ""
end selecttab

on focusspace(sid)
	tell application id "company.thebrowser.Browser" to tell window 1 to tell space id sid to focus
	return ""
end focusspace

on closetab(tid)
	tell application id "company.thebrowser.Browser" to tell window 1 to close tab id tid
	return ""
end closetab

on seturl(u)
	tell application id "company.thebrowser.Browser"
		set URL of active tab of window 1 to u
	end tell
	return ""
end seturl

on navigate(what)
	tell application id "company.thebrowser.Browser"
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

on maketab(u)
	tell application id "company.thebrowser.Browser"
		tell window 1
			set t to make new tab with properties {URL:u}
		end tell
		try
			return id of t
		end try
	end tell
	return ""
end maketab

on openurl(u)
	tell application id "company.thebrowser.Browser" to open location u
	return ""
end openurl
"""#
}
