-- ui-probe.applescript
--
-- Drives Osmo end-to-end via the macOS Accessibility API (System Events UI
-- scripting) to prove surfaces actually respond — not just that the process is
-- alive. Every step: do something, then assert the AX tree changed the way it
-- should within a short deadline. A click that produces no change is exactly
-- the "buttons don't work" bug.
--
-- Searches are scoped to the WHOLE PROCESS (every window), not a single window
-- reference — Osmo has more than one top-level window at once (the main content
-- window plus the floating pill panel), and which one is "window 1" by System
-- Events' z-order is not reliable.
--
-- Usage: osascript ui-probe.applescript [scenario]
--   scenario ∈ { modals (default), ask, connections, queue-human-filter }
-- The queue-human-filter scenario assumes the caller (ui-probe-extended.sh) has
-- already emitted the two probe messages via /api/dev/emit and only asserts the
-- resulting queue state.
-- Exit code 0 = every step passed. Non-zero = see stdout for which step failed
-- and what was actually in the AX tree at that point.

on run argv
	set appName to "Osmo"
	set scenario to "modals"
	if (count of argv) > 0 then set scenario to item 1 of argv
	set stepLog to {}

	try
		tell application "System Events"
			if not (exists process appName) then
				error "Osmo is not running — launch it before probing."
			end if
			tell process appName
				set frontmost to true
				delay 0.3
				set winWait to 0
				repeat while (count of windows) is 0 and winWait < 5
					delay 0.3
					set winWait to winWait + 0.3
				end repeat
				if (count of windows) is 0 then error "Osmo has no window."
			end tell
		end tell

		if scenario is "settle" then
			my runSettle(stepLog)
		else if scenario is "modals" then
			my runModals(stepLog)
		else if scenario is "ask" then
			my runAsk(stepLog)
		else if scenario is "connections" then
			my runConnections(stepLog)
		else if scenario is "queue-human-filter" then
			my runQueueHumanFilter(stepLog)
		else
			error "Unknown scenario: " & scenario
		end if

		log "UI PROBE [" & scenario & "]: ALL PASS"
		repeat with s in stepLog
			log s
		end repeat
		return 0
	on error errMsg
		log "UI PROBE [" & scenario & "]: FAIL — " & errMsg
		repeat with s in stepLog
			log s
		end repeat
		error errMsg
	end try
end run

-- ═══════════════════════════════════════════════════════════════════════════
-- Scenario: settle — dismiss any launch sheet (consent / What's New) that would
-- cover the sidebar, then wait for the main window to be ready. Run this once
-- after a fresh relaunch before the data-driven scenarios.
-- ═══════════════════════════════════════════════════════════════════════════
on runSettle(stepLog)
	tell application "System Events"
		tell process "Osmo"
			if my hasIdentifier("consent.accept") then
				my clickIdentifier("consent.accept")
				my waitUntilGone("consent.accept", 12)
				set end of stepLog to "PASS dismissed consent"
			end if
			if my hasIdentifier("whatsnew.done") then
				my clickIdentifier("whatsnew.done")
				my waitUntilGone("whatsnew.done", 12)
				set end of stepLog to "PASS dismissed What's New"
			end if
			-- Jump to Today via ⌘1 and confirm the main UI is live. Retried:
			-- a keystroke fired while a launch sheet is still animating away
			-- gets swallowed. (List rows don't expose ids; ⌘1–⌘5 are the
			-- stable way in.)
			set todayReady to false
			repeat 3 times
				key code 18 using {command down}   -- ⌘1 → Today
				try
					my waitFor("ask.input", 12)
					set todayReady to true
					exit repeat
				end try
			end repeat
			if not todayReady then error "Today never became ready after 3 ⌘1 attempts."
			set end of stepLog to "PASS main UI ready (⌘1 → Today)"
		end tell
	end tell
end runSettle

-- ═══════════════════════════════════════════════════════════════════════════
-- Scenario: modals — the original sheet click-through (regression guard).
-- ═══════════════════════════════════════════════════════════════════════════
on runModals(stepLog)
	tell application "System Events"
		tell process "Osmo"
			-- Step 1: consent sheet (only present pre-acceptance — tolerate
			-- either state, but if present, it must be dismissible).
			if my hasIdentifier("consent.accept") then
				my clickIdentifier("consent.accept")
				my waitUntilGone("consent.accept", 12)
				set end of stepLog to "PASS consent->accept"
			else
				set end of stepLog to "SKIP consent (already accepted)"
			end if

			-- Step 2: open the account/profile sheet from the sidebar.
			if not (my hasIdentifier("sidebar.account")) then error "sidebar.account not found — main window unresponsive or not loaded."
			my clickIdentifier("sidebar.account")
			my waitFor("profile.close", 12)
			set end of stepLog to "PASS sidebar.account -> profile sheet opened"

			-- Step 3: hand off to Feedback from within the profile sheet.
			my clickIdentifier("profile.feedback")
			my waitFor("feedback.send", 12)
			set end of stepLog to "PASS profile.feedback -> feedback sheet opened"

			-- Step 4: close feedback via its own close button.
			my clickIdentifier("feedback.close")
			my waitUntilGone("feedback.send", 12)
			set end of stepLog to "PASS feedback dismissed"

			-- Step 5: main window still responsive — reopen account, Help this time.
			my clickIdentifier("sidebar.account")
			my waitFor("profile.help", 12)
			my clickIdentifier("profile.help")
			my waitFor("help.close", 12)
			set end of stepLog to "PASS profile.help handoff (help sheet opened)"
			my clickIdentifier("help.close")
			my waitUntilGone("help.close", 12)

			-- Step 6: main window still responsive after two round trips.
			my clickIdentifier("sidebar.account")
			my waitFor("profile.close", 12)
			my clickIdentifier("profile.close")
			my waitUntilGone("profile.close", 12)
			set end of stepLog to "PASS main window responsive after full modal round trip"
		end tell
	end tell
end runModals

-- ═══════════════════════════════════════════════════════════════════════════
-- Scenario: ask — type a question, send it, assert an answer bubble appears.
-- In mock mode askOsmo answers deterministically from local state (no model
-- call), so this exercises the whole Ask surface without any credentials.
-- ═══════════════════════════════════════════════════════════════════════════
on runAsk(stepLog)
	tell application "System Events"
		tell process "Osmo"
			key code 18 using {command down}   -- ⌘1 → Today
			my waitFor("ask.input", 12)
			set end of stepLog to "PASS navigated to Today, ask.input present"

			-- Write the question straight into the field's AX value: a plain AX
			-- `click` on a SwiftUI TextField doesn't take keyboard focus, so
			-- `keystroke` lands nowhere; setting AXValue bridges to the binding
			-- (the send button only un-hides once the binding is non-empty).
			my setValueByIdentifier("ask.input", "Who is waiting on me")
			delay 0.4
			my waitFor("ask.send", 12)
			my clickIdentifier("ask.send")
			set end of stepLog to "PASS question submitted"

			-- The answer bubble must materialize.
			my waitFor("ask.answer", 15)
			set end of stepLog to "PASS ask.answer rendered"
		end tell
	end tell
end runAsk

-- ═══════════════════════════════════════════════════════════════════════════
-- Scenario: connections — the connect phase must actually flip on click.
-- Click Connect on LinkedIn → the row enters .linking (Cancel appears) →
-- Cancel → back to .notConnected (Connect returns). Fully in-app; never
-- leaves for a browser.
-- ═══════════════════════════════════════════════════════════════════════════
on runConnections(stepLog)
	tell application "System Events"
		tell process "Osmo"
			key code 23 using {command down}   -- ⌘5 → Connections
			-- The page's onAppear fires a reconcile(verify:) that re-renders the
			-- rows for a beat; let it settle before asserting on the CTA.
			delay 2
			-- Key off the status text (proves the row rendered its state) rather
			-- than a row-level id — a container-level AXIdentifier collapses its
			-- children out of the tree, hiding the very buttons we need to click.
			my waitFor("connections.status.linkedin", 12)
			set end of stepLog to "PASS Connections page shows LinkedIn row + status"

			-- Only meaningful from a not-connected start; if a prior run left it
			-- linking, cancel first.
			if my hasIdentifier("connections.cancel.linkedin") then
				my clickIdentifier("connections.cancel.linkedin")
				my waitFor("connections.connect.linkedin", 12)
			end if

			my waitFor("connections.connect.linkedin", 45)
			my clickIdentifier("connections.connect.linkedin")
			my waitFor("connections.cancel.linkedin", 45)
			set end of stepLog to "PASS Connect flipped LinkedIn to linking (Cancel appeared)"

			my clickIdentifier("connections.cancel.linkedin")
			my waitFor("connections.connect.linkedin", 45)
			set end of stepLog to "PASS Cancel returned LinkedIn to not-connected"
		end tell
	end tell
end runConnections

-- ═══════════════════════════════════════════════════════════════════════════
-- Scenario: queue-human-filter — the caller has already emitted an automated
-- email (Poker Night / noreply@) and a human email (Sam Rivera / gmail). Sync,
-- open Today, and assert the human is in "You owe a reply" and the automated
-- one is NOT. This is the end-to-end proof that the classifier keeps company
-- mail out of the human queue.
-- ═══════════════════════════════════════════════════════════════════════════
on runQueueHumanFilter(stepLog)
	tell application "System Events"
		tell process "Osmo"
			-- Pull the emitted messages in now (⌘R), then open Today (⌘1).
			key code 15 using {command down}   -- ⌘R → Sync now
			delay 3
			key code 18 using {command down}   -- ⌘1 → Today
			delay 1.5
			set end of stepLog to "PASS synced + opened Today"

			-- The human sender must surface as an owed reply. Queue-card ids are
			-- queue.card.<name>-<uuid4> (the suffix de-dupes same-named people),
			-- so match on the name PREFIX.
			my waitForPrefix("queue.card.sam", 12)
			set end of stepLog to "PASS human sender (Sam) is in the reply queue"

			-- The automated sender must NOT.
			if my hasIdentifierPrefix("queue.card.poker") then
				error "queue.card.poker* present — automated email leaked into the human reply queue."
			end if
			set end of stepLog to "PASS automated sender (Poker Night) correctly filtered out"
		end tell
	end tell
end runQueueHumanFilter

-- ═══════════════════════════════════════════════════════════════════════════
-- Helpers
-- ═══════════════════════════════════════════════════════════════════════════

-- Depth-first search of the AX tree under `root` for any element whose AX
-- identifier matches `ident`. Returns the element reference or missing value.
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

-- Depth-first search for any element whose AX identifier STARTS WITH `prefix`
-- — for id families with a de-dupe suffix (queue.card.<name>-<uuid4>). Exact
-- matching stays the default everywhere else.
on findByIdentifierPrefix(root, prefix, depth)
	tell application "System Events"
		if depth is 0 then return missing value
		try
			set kids to UI elements of root
		on error
			return missing value
		end try
		repeat with kid in kids
			try
				if (value of attribute "AXIdentifier" of kid) starts with prefix then return kid
			end try
			set found to my findByIdentifierPrefix(kid, prefix, depth - 1)
			if found is not missing value then return found
		end repeat
	end tell
	return missing value
end findByIdentifierPrefix

-- Search every window of the Osmo process (main content + floating pill panel).
on findAcrossWindows(ident)
	tell application "System Events"
		tell process "Osmo"
			set winList to windows
			repeat with w in winList
				set found to my findByIdentifier(w, ident, 12)
				if found is not missing value then return found
			end repeat
		end tell
	end tell
	return missing value
end findAcrossWindows

-- Prefix-matching variant of findAcrossWindows.
on findAcrossWindowsPrefix(prefix)
	tell application "System Events"
		tell process "Osmo"
			set winList to windows
			repeat with w in winList
				set found to my findByIdentifierPrefix(w, prefix, 12)
				if found is not missing value then return found
			end repeat
		end tell
	end tell
	return missing value
end findAcrossWindowsPrefix

on hasIdentifier(ident)
	set found to my findAcrossWindows(ident)
	return found is not missing value
end hasIdentifier

on hasIdentifierPrefix(prefix)
	set found to my findAcrossWindowsPrefix(prefix)
	return found is not missing value
end hasIdentifierPrefix

on clickIdentifier(ident)
	set found to my findAcrossWindows(ident)
	if found is missing value then error "Could not find AX element with identifier: " & ident
	tell application "System Events" to click found
end clickIdentifier

-- Set a text field's value directly by identifier (used when a click+keystroke
-- would be flaky). SwiftUI TextFields honor AXValue writes for their binding.
on setValueByIdentifier(ident, newValue)
	set found to my findAcrossWindows(ident)
	if found is missing value then error "Could not find AX element with identifier: " & ident
	tell application "System Events"
		-- Focus first: a SwiftUI TextField only bridges an AXValue write into its
		-- binding while it holds keyboard focus (an unfocused set is dropped).
		try
			set focused of found to true
		end try
		delay 0.2
		set value of found to newValue
	end tell
end setValueByIdentifier

on waitFor(ident, timeoutSeconds)
	-- WALL-CLOCK deadline: each AX tree walk can take seconds on a busy app
	-- (the walk itself forces SwiftUI to materialize accessibility nodes), so
	-- counting iterations would stretch a "10s timeout" into many minutes.
	set deadline to (current date) + timeoutSeconds
	repeat while (current date) < deadline
		if my hasIdentifier(ident) then return true
		delay 1.2
	end repeat
	error "Timed out waiting for '" & ident & "' to appear — an action had no effect (frozen surface?)."
end waitFor

on waitForPrefix(prefix, timeoutSeconds)
	set deadline to (current date) + timeoutSeconds
	repeat while (current date) < deadline
		if my hasIdentifierPrefix(prefix) then return true
		delay 1.2
	end repeat
	error "Timed out waiting for an id starting with '" & prefix & "' — an action had no effect (frozen surface?)."
end waitForPrefix

on waitUntilGone(ident, timeoutSeconds)
	set deadline to (current date) + timeoutSeconds
	repeat while (current date) < deadline
		if not (my hasIdentifier(ident)) then return true
		delay 1.2
	end repeat
	error "Timed out waiting for '" & ident & "' to disappear — dismiss had no effect (wedged surface?)."
end waitUntilGone
