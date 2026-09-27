# Alpha 6: isolated notification diagnostic

Install alpha 6 and restart providers using Enable filter with current rules. Keep your rules; do not reset again. This is an evidence-gathering build, not a confirmed banner-delivery fix.

1. Tap Test notification (5 seconds), go to the Home Screen, and wait ten seconds. Do not open a network app for this test.
2. Return to NetShield and tap Copy notification diagnostics. Paste the copied report into the support conversation.
3. Report separately whether you saw a banner or found the test in Notification Center. Do not dismiss it before collecting diagnostics if present.

The status should show control build 20006. The content filter's enabled state and OS flow reports are the operational evidence; it is not a VPN tunnel and does not require a VPN server entry. In-app prompts are not evidence that iOS delivered notifications.

The previous reset/feature walkthrough follows for reference; repeating reset is not required for this diagnostic.

# NetShield alpha 5: installation, permissions and tests

Target reported by owner: iOS 16.1.1, Dopamine 3.0.10, rootless.

## Recover from a missing Notifications Settings entry

1. Disable the old filter and close NetShield. Build/install the **alpha 5** deb from the complete source archive. The installer refreshes the app's registration using the new local-notification metadata.
2. Open NetShield and choose **Reset NetShield and restart setup...**, then **Reset and restart setup**. This erases all NetShield decisions/history and restarts Ask setup. Accept any iOS consent dialogs that appear; iOS may retain an earlier notification decision and show no new dialog.
3. Tap **Notification permission**. Check whether NetShield now appears in Settings > Notifications; enable notifications and banners if available. If it still does not appear, report that specific result. Do not repeatedly reset unrelated iOS settings.
4. Run **Test notification (5 seconds)** and immediately switch to another app. Check for the test banner. Then close/reopen a test app and request fresh network content. Long-press its real permission banner for Allow app / Keep blocking.
5. Check NetShield shows **Control build 20005**. If registration still fails, report the notification authorization/alerts row and whether the test banner appeared; if the test works but real banners fail, report the provider notification result in Status.

Reset clears NetShield's state, not the iOS notification database. The package refreshes registration without a forced respring/userspace reboot; there is no new injected component. This release has compiled successfully but notification registration/delivery and reset still need device verification.

## What the prompt looks like

A NetShield notification banner appears over the app you are using. **Touch and hold the banner** to expose **Allow app** and **Keep blocking**. These buttons save the rule in the background. Tapping the notification body opens NetShield instead. Unlocking is required for decisions made from the Lock Screen. This is an actionable iOS notification, not a dialog injected into the requesting app.

Allow and Keep blocking each save a persistent rule for the exact identity iOS reported. Ignoring the banner blocks the unanswered connections after 30 seconds, without creating a permanent rule. Existing allowed connections are not revoked when a rule changes.

## Install or upgrade

1. Upload the entire alpha 5 source tree, including hidden `.github` and all three `Resources/Info.plist` files. Run GitHub Actions **Build NetShield 2 experimental** on that commit. Download the `NetShield-2-experimental-iOS16-rootless` artifact and extract `com.eolnmsuk.netshield_2.0.0~alpha5_iphoneos-arm64.deb`.
2. If upgrading, open the installed NetShield and tap **Disable filter**, then close NetShield from the app switcher. Filtering is off during the upgrade. Install the new deb using your package manager.
3. Open NetShield. The package registers the app/extensions with `uicache`. **Alpha 5 does not require a respring or userspace reboot:** it contains no SpringBoard injection. The next step restarts the providers through NetworkExtension. Do not reboot merely to fix denied notifications.
4. Tap **Start permission prompts > Enable**. If iOS requests notification permission, choose **Allow**. After this request finishes, NetShield saves/enables the filter; accept the system's filter consent if shown. This sequence retains existing rules and changes Apps without a rule to `ask`.
5. Return to NetShield if iOS opened Settings. The filter is a **content filter**, not a VPN tunnel: no VPN server, credentials, profile download or Connect button is needed. The app contains no command to open VPN Settings. An empty VPN page is not evidence of failure or success. In NetShield check the control build is **20005** and the status is **Filter enabled: no recent traffic** or **Filtering active**. A missing heartbeat, older build or save error means stop here and report the exact Status text.
6. Tap **Notification permission**. If already asked, this now opens NetShield's iOS notification settings. Enable **Allow Notifications**, **Banners**, **Notification Center** and **Sounds**. Choose **Persistent** banners for easier testing. Temporarily turn Focus off and exclude NetShield from Scheduled Summary. Return to NetShield; its notification row should show authorization allowed and alerts on. Returning requests another delivery attempt for pending requests.

An upgrade preserves explicit app rules. An app with an existing Allow or Block rule will not ask. Do not reset all rules just to test one app.

## Test A: ordinary notification delivery

1. Tap **Test notification (5 seconds)** and immediately switch to another app.
2. Expect a NetShield test banner after about five seconds. It has no permission actions and changes no rules.
3. If absent, check Notification Center and NetShield's notification settings. Report whether it appeared as a banner, only in Notification Center, or nowhere. Also report the authorization/alerts row and any test error.

This tests the containing app's delivery only. It does not establish that iOS accepts notifications submitted by the filter extension.

## Test B: permission banner and background Allow

1. Choose a nonessential app that loads fresh online content. In NetShield select its observed identity under **Apps and OS identities**, then choose `use-default` if it has a rule. Leave **Apps without a rule** set to `ask`. If the identity is not listed, simply use an app you have never allowed or blocked.
2. Close that test app from the app switcher to close existing connections. Leave NetShield normally using the Home gesture; do not force-quit it for this initial test.
3. Open the test app and refresh/load new online content. Cached content is not evidence of network access.
4. Expect a **Network access requested** banner naming the OS identity. Long-press it, then tap **Allow app** within 30 seconds. The requesting app should remain on screen. Retry its refresh if it already timed out.
5. Later open NetShield. The identity should have an `allow` rule. Close/reopen the test app and request fresh content again: it should work without another permission banner.
6. If no banner, open NetShield and record whether the request is in **Permission requests** and copy the Status text, especially the notification result. A working Test A plus a pending request with failed Test B isolates the extension notification path. A provider message saying accepted by iOS is scheduling acknowledgement, not proof of display. Answer in the inbox to recover access if necessary.

## Test C: Keep blocking

1. Set that identity to `use-default`, close the test app, then open it and generate new traffic.
2. Long-press its banner and choose **Keep blocking**. The requesting app should remain on screen and its fresh network request should fail.
3. Check the stored rule is `block`. Reopening the test app should stay blocked without another banner.

## Test D: timeout and retry

1. Restore `use-default`, close/reopen the test app and generate fresh traffic. Ignore the permission banner for at least 35 seconds.
2. The request should fail; NetShield should list a timed-out request. Repeated attempts from that identity do not generate repeated banners automatically.
3. Tap **Retry pending notifications**, switch back to the test app and use the reissued banner to Allow. If it appears before you switch, find it in Notification Center. A late decision saves the rule but cannot revive the expired flow: refresh again.

## Test E: delivery after settings changes and cold start

1. With a pending request, disable NetShield notifications in iOS Settings. Expect no banner and unanswered traffic to be denied. Re-enable notifications, return to NetShield and tap **Retry pending notifications** if necessary. Check for the reissued notification in Notification Center.
2. Separately, with a genuine permission banner already delivered, remove NetShield from the app switcher and then long-press the banner and choose an action. Check whether the rule is saved while your current app stays visible. Report this separately from Test B; background launch behavior must be verified on this jailbreak.
3. Remove the filter configuration, then try an old delivered notification if one remains. It must not save a rule when the provider is stopped/stale. A failure notification explains rejected decisions.

## Other feature checks

- **Explicit/default rules:** with a fresh connection each time, confirm explicit Allow overrides default Block; explicit Block overrides default Allow; `use-default` follows the default. Default Block denies without prompting; only Ask prompts.
- **In-app fallback:** while a request is pending, open NetShield and answer its dialog or inbox row. Confirm the rule persists across reopening NetShield.
- **Monitoring:** generate and close a connection, then check identity, decision, timestamp and flow-close byte counts. Permission events have zero byte counts; they are not traffic totals. At most 300 events are retained per provider session.
- **Wi-Fi/cellular:** repeat B and C on each interface. A cached page or an existing session is not a valid new-flow test.
- **Direction rules:** `block-outbound` blocks newly initiated outgoing connections. `block-inbound` concerns newly initiated incoming connections, not replies/downloads in an outgoing connection. Test inbound only with a known listening app and another device initiating the connection; ordinary browsing cannot prove it.
- **Unattributed traffic:** leave Allow initially. The separate Block option affects flows for which iOS supplies no app identity; these cannot have a reliable named-app prompt. Test only when ready to restore Allow if services stop working.
- **Disable:** tap Disable filter and verify a formerly blocked app can make a new connection. Enable with current rules restarts the providers and retains decisions. Confirm build 20005 and a current heartbeat again.
- **Reset rules:** this clears all explicit decisions, restores Ask and allows unattributed flows; it does not enable/disable the filter. Use only if you want those changes.
- **Uninstall:** tap Remove filter configuration, verify Filter off, then uninstall. The removal script unregisters the app but cannot independently remove saved NE configuration. If uninstalled first, reinstall NetShield and remove its configuration.

## Report back

Copy and fill in:

- Installed package: alpha 5; control build shown:
- Status text (including notification result):
- Notification authorization / alerts:
- A: banner / Notification Center only / absent:
- B: banner appeared? buttons visible on long-press? stayed in requesting app? rule saved? fresh request allowed?
- C: stayed in requesting app? rule saved? fresh request blocked?
- D: blocked after timeout? retry notification appeared? late Allow worked after refresh?
- E: settings recovery / cold-start result:
- Interface and test app's exact OS identity:
- Other feature failures:

Background banner delivery is not yet verified on this device. Alpha 5 corrects the foreground-only action behavior, overlapping setup prompts, missing denied-permission Settings path and inability to retry notifications. It does not claim that notification delivery or every network path has been proved by compiling the code.
