-- ui-probe.applescript
--
-- Drives Osmo's sheet system end-to-end via the macOS Accessibility API
-- (System Events UI scripting) to prove modals actually respond to clicks —
-- not just that the process is alive. Every step: click something, then
-- assert the AX tree changed the way it should within a short deadline. A
-- click that produces no change is exactly the "buttons don't work" bug.
--
-- Searches are scoped to the WHOLE PROCESS (every window), not a single
-- window reference — Osmo has more than one top-level window at once (the
-- main content window plus the floating pill panel), and which one is
-- "window 1" by System Events' z-order is not reliable.
--
-- Usage: osascript ui-probe.applescript
-- Exit code 0 = every step passed. Non-zero = see stdout for which step and
-- what was actually in the AX tree at the point of failure.

on run
	set appName to "Osmo"
	set stepLog to {}

	try
		tell application "System Events"
			if not (exists process appName) then
				error "Osmo is not running — launch it before probing."
			end if
			tell process appName
				set frontmost to true
				-- Give the window a moment to key up after activation.
				delay 0.3
				if (count of windows) is 0 then error "Osmo has no window."

				-- Step 1: consent sheet (only present pre-acceptance — tolerate
				-- either state, but if present, it must be dismissible).
				if my hasIdentifier("consent.accept") then
					my clickIdentifier("consent.accept")
					my waitUntilGone("consent.accept", 3)
					set end of stepLog to "PASS consent->accept"
				else
					set end of stepLog to "SKIP consent (already accepted)"
				end if

				-- Step 2: open the account/profile sheet from the sidebar.
				if not (my hasIdentifier("sidebar.account")) then error "sidebar.account not found — main window unresponsive or not loaded."
				my clickIdentifier("sidebar.account")
				my waitFor("profile.close", 3)
				set end of stepLog to "PASS sidebar.account -> profile sheet opened"

				-- Step 3: hand off to Feedback from within the profile sheet.
				my clickIdentifier("profile.feedback")
				my waitFor("feedback.send", 3)
				set end of stepLog to "PASS profile.feedback -> feedback sheet opened"

				-- Step 4: close feedback via its own close button (feedback has no
				-- cancel-role button, so Escape is not wired to dismiss it — click
				-- the real close control, same as a user would).
				my clickIdentifier("feedback.close")
				my waitUntilGone("feedback.send", 3)
				set end of stepLog to "PASS feedback dismissed"

				-- Step 5: main window still responsive — reopen account, hand off
				-- to Help this time.
				my clickIdentifier("sidebar.account")
				my waitFor("profile.help", 3)
				my clickIdentifier("profile.help")
				my waitFor("help.close", 3)
				set end of stepLog to "PASS profile.help handoff (help sheet opened)"
				my clickIdentifier("help.close")
				my waitUntilGone("help.close", 3)

				-- Step 6: main window still responsive after two round trips —
				-- click sidebar.account once more and confirm it reopens (proves
				-- event routing hasn't wedged).
				my clickIdentifier("sidebar.account")
				my waitFor("profile.close", 3)
				my clickIdentifier("profile.close")
				my waitUntilGone("profile.close", 3)
				set end of stepLog to "PASS main window responsive after full modal round trip"
			end tell
		end tell

		log "UI PROBE: ALL PASS"
		repeat with s in stepLog
			log s
		end repeat
		return 0
	on error errMsg
		log "UI PROBE: FAIL — " & errMsg
		repeat with s in stepLog
			log s
		end repeat
		error errMsg
	end try
end run

-- Depth-first search of the AX tree under `root` for any element (button,
-- checkbox, etc.) whose accessibility identifier matches `ident`. Returns the
-- UI element reference, or missing value if not found. Bounded depth keeps
-- this fast and avoids runaway recursion on odd AX trees.
on findByIdentifier(root, ident, depth)
	tell application "System Events"
		if depth is 0 then return missing value
		try
			set kids to UI elements of root
		on error
			return missing value
		end try
		repeat with kid in kids
			try
				if (value of attribute "AXIdentifier" of kid) is ident then return kid
			end try
			set found to my findByIdentifier(kid, ident, depth - 1)
			if found is not missing value then return found
		end repeat
	end tell
	return missing value
end findByIdentifier

-- Search every window of the Osmo process (not just one) — the app has more
-- than one top-level window at a time (main content + floating pill panel).
on findAcrossWindows(ident)
	tell application "System Events"
		tell process "Osmo"
			set winList to windows
			repeat with w in winList
				set found to my findByIdentifier(w, ident, 10)
				if found is not missing value then return found
			end repeat
		end tell
	end tell
	return missing value
end findAcrossWindows

on hasIdentifier(ident)
	set found to my findAcrossWindows(ident)
	return found is not missing value
end hasIdentifier

on clickIdentifier(ident)
	set found to my findAcrossWindows(ident)
	if found is missing value then error "Could not find AX element with identifier: " & ident
	tell application "System Events" to click found
end clickIdentifier

on waitFor(ident, timeoutSeconds)
	set elapsed to 0
	repeat while elapsed < timeoutSeconds
		if my hasIdentifier(ident) then return true
		delay 0.2
		set elapsed to elapsed + 0.2
	end repeat
	error "Timed out waiting for '" & ident & "' to appear — a click had no effect (frozen sheet?)."
end waitFor

on waitUntilGone(ident, timeoutSeconds)
	set elapsed to 0
	repeat while elapsed < timeoutSeconds
		if not (my hasIdentifier(ident)) then return true
		delay 0.2
		set elapsed to elapsed + 0.2
	end repeat
	error "Timed out waiting for '" & ident & "' to disappear — dismiss had no effect (wedged sheet?)."
end waitUntilGone
