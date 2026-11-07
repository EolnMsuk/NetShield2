# 2.7.8

- Locked NetShield2 to portrait on iPhone and iPad, with full-screen mode on iPad.
- Actionable Ask Me banners now say "Long press banner to Allow or Block".

# 2.7.7

- Hide empty App Rules and System Rules sections, including their placeholder messages, headings, descriptions, and spacing. System Rules remain hidden while Allow all iOS system traffic is enabled.

# 2.7.6

- App Rules and System Rules now show the saved checkmarks as soon as you select or clear a choice in the open sheet.
- Global rules using UDP & TCP now apply to all protocols delivered by iOS, including non-TCP/UDP traffic and flows without protocol metadata. TCP-only and UDP-only rules remain protocol-specific; existing combined rules gain the same coverage.
- Shortened custom-rule descriptions and clarified combined-protocol coverage.
- Simplified healthy Firewall status, showing fallback details when an issue needs attention, and shortened the Firewall and Filter System Sockets descriptions.
- Hid Waiting for Your Decision when no apps are waiting.
- Moved Domain and IP address directly below Process name in connection details.

# 2.7.4

- Ask Me banners show the requested domain, or the remote IP when a domain is unavailable.
- Banners refresh when the displayed peer changes.
- Renamed the link-opening prompt and shortened its description.

# 2.7.2

**After an update**  
If iOS still shows the content filter as Invalid after refreshing saved preferences and explicitly retrying, a full reboot and re-jailbreak may be needed.

- Fixed first-time Firewall setup so approving the iOS content filter can complete activation from a single On action. The dashboard shows setup progress and separates verified saved state from control-provider health.
- Improved saved-state checks and recovery for Firewall changes, reset, and removal. Delayed preference writes retain ownership, and fresh readbacks detect external changes before another write.
- Hardened shared app-group file access through both `/var` and `/private/var`, with bounded reads, atomic writes, stricter rule and activity validation, and a smaller read-only data provider. Strengthened stock-boot fallback checks.
- Improved provider startup, shutdown, and reply handling, with bounded work queues, permission-notification retries, and deadlines for background actions.
- Improved DNS refresh scheduling and reverse-address matching, bounded lookup work, and tightened expiry and invalidation on rule and network changes.
- Made Recent Activity distinguish transport and show mixed outcomes and grouped peers, safely total bytes, and keep cleared history from reappearing. Clarified how custom rules combine with legacy rule precedence.
- Moved storage work off the main thread, fixed dashboard color reuse, protected active exports during cleanup, and improved dialog cleanup and bounded update downloads.
- Improved reset and uninstall diagnostics and respring cleanup. Version and generation checks keep stale detached workers from triggering a respring.
- Strengthened GitHub package, signature, and entitlement checks and added build provenance and draft-asset verification for all three variants. Expanded regression and sanitizer coverage, updated the build overview, and removed obsolete documentation and test references.

# 2.6.4

- **FilterGate Fixed:** included the guarded stock-boot fallback policy by default for RootHide (main impact), rootless and rootful, with typed runtime access to the actual private `disableDefaultDrop` property and readback/copy/persistence checks. 
- Fixed export staging using the shared app-group cache.
- Prepared a stable release, retaining the stock-boot connectivity fallback for all jailbreak variants.
- Fixed some labels and update settings.

# 2.6.3

- Fixed export staging using the shared app-group cache.
- Prepared a stable release, retaining the stock-boot connectivity fallback for all jailbreak variants.

# 2.6.2

- **BETA:** includes the first attempt with guarded stock-boot fallback policy by default for RootHide, rootless and rootful, with typed runtime access to the actual private `disableDefaultDrop` property and readback/copy/persistence checks.

# 2.6.1

- Modified update instructions

# 2.6.0

- Fixed uninstall failing on the first attempt when Firewall was enabled by waiting for shared-state locks to become available after filter removal.
- Edited some update labels and UI.

# 2.5.9

- Open Unidentified and Default Rule sheets at half-screen height.
- Added / updated update-check controls with daily-on-launch checks by default.

# 2.5.8

- Added a sandbox exemption to the main app only, should fix in app respring feature.

# 2.5.7

- Fixed successful-uninstall resprings.
- Replaced reset choices with **Reset Settings** and **Remove Filter & Settings**; both clear rules/history and restore defaults with Firewall off, while the latter also removes the content filter.
- Simplified App/System Rule descriptions, put System Rules before App Rules, and moved Global Rules clearing above saved global rules.
- Recent Activity action sheets open at half height and place Copy all details after connection details.

# 2.5.6

- Renamed the iOS content filter to **Firewall & Monitor**.
- Recent Activity will no longer clear when the firewall is turned on.
- Only shows Clear buttons for non-empty sections.
- All settings are now removed (along with filter) on un-installation.

# 2.5.5

- Fixed searchbar keyboard predictive text from covering the input field.

# 2.5.4

- Remove the duplicate large process name from popups with process details; keep it in windows without those details.
- Remove the Done toolbar above the Recent Activity search keyboard.
- Clear the Recent Activity search after either CONFIGURATION reset.
- Rename **Check for Update** to **Check for Updates** and move it above **GitHub Link**.
- Change its description to **Checks GitHub for a newer version**.

# 2.5.3

- UI fixes.
- Copy only a detail's displayed value when tapped.
- Color app/system rows with two explicit directions using the outgoing decision: green for allowed and red for blocked.
- Rename the both-directions **Block In & Out** action to **Block**.
- Sort App Rules/System Rules alphabetically by their sanitized names.
- Schedule one automatic respring after successful installs (sorry for anyone impacted by the lack of this during updates).

# 2.5.2

- Save independent incoming/outgoing app and system decisions in one rule row. The existing-rule editor saves each choice immediately, shows all active checkmarks, and closes with Done.
- Restrict connection prompts and notification actions to the current direction; retain the opposite decision and refresh banners when a pending token changes direction.
- Migrate directional blocks so the opposite direction follows the Default Rule instead of being implicitly allowed.

# 2.5.1

- Name release deb files with the current control-file version and rootful, rootless, or roothide suffix.
- Move Copy connection details below rule choices and above connection details in Recent Activity menus.
- Align the Recent Activity search field with its heading and rename its placeholder to Search recent connections.
- Dismiss the search keyboard on outside touches or scrolling, and add a Done button above the keyboard even with an empty query.
- Preserve keyboard visibility when clearing the Recent Activity search with its x button.
- Align Clear buttons with the surrounding content and reduce their height by 25% while retaining their font size, including System Rules.
- Use larger, consistent uppercase section titles and rename Reset Settings to CONFIGURATION.

# 2.4.8

- Search Recent Activity by connection details, including full process identities.
- Add confirmed Clear buttons for Recent Activity, App Rules, System Rules, and Global Rules.
- Add Copy to Clipboard below connection details, copying all details and the full process identity on one line.
- Leave traffic outside a global rule's direction to other rules or the default policy, including Ask Me, while preserving app-rule behavior.
- Allow identical global-rule conditions in opposing directions and reject overlapping directions regardless of allow/block action.

# 2.4.7

- Open Edit Custom Rule directly when tapping an existing Global Rule.
- Offer all six direction choices in App Rules, network permission prompts, and Recent Activity connection menus. 
- Move connection details below the action choices in network permission and Recent Activity dialogs.

# 2.4.6

- The build script now automatically pulls version numbers from the tweak's control file.
- Added Allow Outgoing and Allow Incoming to custom rules.
- Show connection details and direction in separate rows in recent-activity menus and network permission prompts.
- Added Add Custom Rule to app and connection menus, prefilling available details without changing existing app rules.
- Renamed global-rule editing labels to Custom Rule and Action to Direction, and moved the override footer below Add a Custom Rule.

# 2.4.5

- Show full, unsanitized app/process identities in rule and recent-activity action popups and the Add/Edit Global Rule app selector.
- Allow global rules with only an action and protocol, applying to all apps, destinations, and ports with UDP, TCP, or both.
- Brighten green, red, and orange rule/activity colors in dark mode and darken them slightly in light mode, including selected action-row backgrounds.
- Show selected rule checkmarks in white in dark mode and black in light mode.

# 2.4.4

- Reduced popup action-row text size by 25% while keeping the existing row height and horizontal and vertical centering.

# 2.4.3

- Increased popup action-row font size by 50% to match the taller rows.
- Show the selected, checkmarked rule's text in white in dark mode and black in light mode while retaining its colored background.

# 2.4.2

- Highlight only the selected, checkmarked rule's background in app and global rule action popups; other options keep their rule text colors without tinted backgrounds.
- Increased popup action-row height by 50% while keeping the same font size and centering labels horizontally and vertically.
- Open app-rule menus at their expanded height to accommodate the taller rows.

# 2.4.1

- Fixed centering of Allow, Block Incoming, and Block In & Out in in-app permission prompts and rule menus, including when a selected rule has a checkmark.
- After stripping the prefix through the first period, remove every remaining `com.` and then `org.` from app/process display names throughout the app and notifications.
- Changed Add a Global Rule to the same system green used for Active firewall status.

# 2.4.0

- Removed every remaining `com.` from app/process display names after stripping the prefix through the first period.
- Removed the Notifications section description.

# 2.3.9

- Changed Add a Global Rule to the standard adaptive label color.
- Renamed Advanced Settings to Reset Settings.
- Moved the version, developer, iOS, and jailbreak text above GitHub Link with separate padding.

# 2.3.8

- Moved the version, developer, iOS, and jailbreak footer beneath Advanced Settings, directly below Reset Settings & Filter.
- Open the Allow network access? sheet at its expanded height so the connection description and actions have room immediately, without an upward swipe.
- Centered Allow, Block Incoming, Block In & Out, and Not Now in the network-access prompt.

# 2.3.7

- Require an app, domain/IP, or port before saving from Add/Edit Global Rule. An explanatory popup with a Close button preserves the editor when no condition is set.
- Moved Advanced Settings above the separate links section and removed the Support heading while retaining spacing.
- Added a shared action picker with adaptive green, orange, and red text for global-rule editing, saved-rule choices, and in-app Ask Me prompts. Rule and activity rows share the same palette.

# 2.3.6

- Global rules can select multiple apps. App menus, selections, and saved rules show shortened display names while retaining exact iOS identities for filtering.
- Restyled the rule editor selectors with native rounded controls and system dropdown indicators.
- Moved Action to the top of the editor and changed the default for new rules to **Allow**.

# 2.3.5

- Added a single **Add a Global Rule** editor at the top of Global Rules, with an app selector, comma-separated domains/IP ranges, remote/local ports, UDP & TCP / UDP / TCP, and an action.
- Combined rules match all selected conditions and remain in Global Rules, including rules scoped to a specific app. Existing global rules can be edited in the same form.
- Moved **Export Rules and Recent Activity**, **Reset Rules & History**, and **Reset Settings & Filter** into Advanced Settings, in that order.

# 2.3.4

- Reordered Support options and renamed reset to **Reset Settings & Filter**. Removed uninstall wording.
- Limited global rule previews to 5 entries followed by `...`.
- Moved **Edit Rule** below **Remove Rule**. Global edits now prompt for a rule before saving.
- Renamed **Allow In & Out** to **Allow**.
- Replaced **Use Default Rule** with a red **Remove Rule** action.
- Fixed swipe removal, including default app rules. Removed apps stay hidden across refreshes and relaunches unless a new rule is saved.
