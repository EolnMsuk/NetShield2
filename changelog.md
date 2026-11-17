# 3.0.2

- Prefills custom-rule ports by connection direction from permission prompts and single Recent Activity connections: incoming keeps the local port and leaves the remote port blank; outgoing keeps the remote port and leaves the local port blank. Both fields remain editable.
- Added collapse controls for System Rules, App Rules, and Recent Activity, retaining the activity search and section choices during dashboard refreshes.
- Skips redundant `UISwitch setOn:animated:` calls during dashboard refreshes and identical scroll-offset restoration after reloads. HaptiX vibration behavior still requires on-device confirmation.
- Adds direct touch-and-hold and supported 3D Touch actions: copy a Recent Activity connection, create a custom rule for the exact App/System process, or edit the selected Global Rule.

# 3.0.1

- Recognizes more iOS system processes.
- Adds an option to block 20 telemetry processes.
- Keeps system rules visible and restores your saved choices.

# 3.0.0

- **Breaking Change:** Users must remove/reset saved rules before updating; older exports are unsupported and will not migrate.
- Fixed swipe removal in Global Rules so only the selected rule disappears without displaying an incorrect “Default Rule” label.
- Added batch app entry to Global Rules by separating identities with commas (invalid lists add nothing).
- Added crash protection and prevented opening the wrong rule when tapping during rule removal or refresh.
- “Add app by identity” now accepts names with or without a leading period (e.g., `networkd`), deduplicating matching spellings while preserving original spelling and rejecting blank or overly long names.

# 2.8

- Added **Import Rules** below Export with atomic replacement across Global, App, and System rules and reporting for rejected entries.
- Added **Ask Me** mode for unidentified connections (Allow remains default) with direction-aware permission cards/notifications, a **Not Now** queue in *Waiting for Your Decision*, and a 30-second auto-block timeout. Decisions with usable connection details save a cross-app global rule; those without apply once.
- Added IPv4/IPv6 CIDR and numeric port range/list support without interval expansion, unified validation across editors and imports, preserved endpoint `AND` conditions and independent local/remote ports, and distinguished `Any` protocol from `TCP & UDP`.
- Rejected intersecting global rules regardless of Allow/Block action.
- Refined process name sanitization: stripped leading periods in sheets/copied details, required both periods for `.com.` namespace removal, and appended ` (main)` when prefixes before `.com.` (including `Apple.com.` and `.Apple.com.`) contain alphanumeric characters.
- Updated the App picker in Add/Edit Custom Rule to show shortened app names and refresh checkmarks immediately on selection on iOS 16–18 (rebuilding menus on dismissal to mitigate scroll resets).
- Gave the FIREWALL fallback footer a constrained view with stable snapshots, updated update labels/descriptions, and refreshed screenshots/example images.

# 2.7

- Fixed first-time Firewall setup so approving the iOS content filter activates from a single **On** action, complete with setup progress and separated state/health indicators.
- Hardened shared app-group storage (`/var` and `/private/var`), preference write ownership/readbacks, DNS refresh scheduling, reverse-address matching, and provider lifecycle queues/deadlines.
- Added icons to **Check for Updates** and **GitHub Link**, renamed *Support the Developer* to **Donate** (with a coin icon), and shortened the link-opening prompt.
- Locked NetShield2 to portrait on iPhone and iPad, with full-screen mode on iPad.
- Updated Ask Me banners to show the requested domain (or remote IP), refresh when the peer changes, and display `"Long press to Allow or Block"`.
- Expanded Global rules using `UDP & TCP` to cover all protocols delivered by iOS (including non-TCP/UDP and metadata-less traffic), while keeping TCP-only and UDP-only protocol-specific.
- Improved UI clarity and density: hid empty App Rules, System Rules, and *Waiting for Your Decision* sections; showed immediate checkmarks in App/System Rule sheets; moved Domain and IP below Process name in connection details; simplified healthy Firewall status; and shortened custom-rule and Firewall descriptions.
- Improved Recent Activity transport/outcome grouping, byte totals, and cleared-history persistence; moved storage off the main thread; and hardened uninstall/respring cleanup, GitHub package/signature verification, and build provenance.

# 2.6

- **FilterGate Fixed:** Included the guarded stock-boot fallback policy by default across RootHide, rootless, and rootful variants with typed runtime access to `disableDefaultDrop` and persistence checks.
- Fixed export staging using the shared app-group cache.
- Fixed uninstall failing on the first attempt when Firewall was enabled by waiting for shared-state locks to release after filter removal.
- Updated update instructions, labels, and UI.

# 2.5

- Renamed the iOS content filter to **Firewall & Monitor** and renamed *Reset Settings* to **CONFIGURATION**.
- Replaced reset options with **Reset Settings** and **Remove Filter & Settings**, and ensured all settings and filters are removed on uninstallation.
- Added daily-on-launch update checks by default, renamed *Check for Update* to **Check for Updates** (above GitHub Link), and scheduled one automatic respring after successful installs (plus a main-app sandbox exemption to fix in-app resprings and uninstall resprings).
- Enabled independent incoming/outgoing decisions within a single App/System rule row, restricted prompts/notifications to the active direction, and migrated directional blocks so the opposite direction follows the Default Rule.
- Renamed *Block In & Out* to **Block**, sorted App/System Rules alphabetically, placed System Rules before App Rules, and moved Global Rules clearing above saved rules.
- Improved Recent Activity: prevented clearing when enabling the firewall, added a search bar with improved keyboard dismissal/clearing, opened action sheets at half-screen height, and copied only displayed values on tap.
- Hid Clear buttons on empty sections, standardized section titles, and removed duplicate process names in detail popups.
- Named release `.deb` files with the control-file version and jailbreak architecture suffix (`rootful`, `rootless`, or `roothide`).

# 2.4

- Added **Add Custom Rule** (renamed from Global Rule labels) with support for **Allow Outgoing** and **Allow Incoming**, protocol-only rules (applying to all apps, destinations, and ports), and prefilled details from connection menus.
- Enabled searching Recent Activity by connection details and full process identities, and added confirmed **Clear** buttons for Recent Activity and all rule sections.
- Added **Copy to Clipboard** to copy all connection details and full process identities on one line, and displayed unsanitized identities in rule/activity popups and selectors.
- Offered all six direction choices across App Rules, permission prompts, and Recent Activity menus, while allowing identical global-rule conditions in opposing directions and rejecting overlapping ones.
- Refined process display names by stripping the prefix through the first period along with all remaining `com.` and `org.` segments.
- Overhauled popup and rule row styling: increased action-row height, adjusted font sizing and centering, highlighted only selected rows with high-contrast checkmarks/text in light and dark modes, and matched **Add a Global Rule** to the system active-green accent.
- Automated version pulling from the control file in the build script and removed the Notifications section description.

# 2.3

- Added a unified **Add a Global Rule** editor at the top of Global Rules supporting multiple apps, comma-separated domains/IP ranges, remote/local ports, protocol selection (`UDP & TCP` / `UDP` / `TCP`), and validation requiring at least one condition before saving.
- Restyled rule editor selectors with native rounded controls, moved Action to the top, changed the default for new rules to **Allow** (renamed from *Allow In & Out*), and added a shared color-coded action picker across editors and Ask Me prompts.
- Replaced *Use Default Rule* with a red **Remove Rule** action, moved *Edit Rule* below it, capped global rule previews at 5 entries (`...`), and fixed swipe removal so removed apps stay hidden across refreshes and relaunches.
- Reorganized settings and footers: renamed *Advanced Settings* to **Reset Settings**, renamed reset actions to **Reset Settings & Filter**, grouped export/reset options cleanly, and expanded the *Allow network access?* sheet height by default.
- Updated app menus and saved rules to display shortened names while retaining exact iOS identities for filtering.
