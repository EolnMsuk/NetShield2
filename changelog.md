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
