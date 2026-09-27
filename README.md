# NetShield 2.0.0

Control app internet access on rootless iOS 16. NetShield uses an OS content filter, saved app rules and actionable notifications. Tested by the owner on iOS 16.1.1 with Dopamine 3.0.10, including background permission decisions.

## Get started

1. Install the deb and open NetShield. No respring is required.
2. Turn on **Firewall** and accept the iOS permissions. Leave **New apps** set to **Ask me** to decide as apps connect. Existing rules are kept when upgrading or toggling the firewall.
3. Enable banners under **Notification settings**. If you use **Do Not Disturb**, allow NetShield in **Settings > Focus > Do Not Disturb > Apps**. Other Focus modes need their own exception.
4. When a new app connects, touch and hold its NetShield notification and choose **Allow app** or **Keep blocking**. Tapping the notification body opens NetShield instead.

Unanswered connections are blocked after 30 seconds. You can decide later in **Waiting for your decision**, then retry the app. To ask again for a previously decided app, tap its rule and select **Use new-app setting** while New apps is Ask me.

## Options

- **Firewall:** on/off; turning it off keeps your rules.
- **New apps:** Ask me, Allow or Block for apps without an explicit rule.
- **App rules:** change saved decisions. Changes apply to new connections; close/reopen an app to end existing connections.
- **Notifications:** notification settings and instructions for banners and Do Not Disturb.
- **Advanced & support:** unidentified connections, manual rules, Copy notification diagnostics, Reset NetShield, and Prepare for uninstall.
- **Recent activity:** the latest 20 events from a rolling 300-event record. Data counts arrive when connections close; permission events are not traffic totals.

**Reset NetShield** clears rules, requests and history, restores Ask me and allows unidentified connections, then leaves Firewall off. iOS notification permission is retained.

Before uninstalling, use **Advanced & support > Prepare for uninstall** to remove the system filter. Then uninstall using your package manager.

## Build and final device check

Upload the complete source tree, including `.github`, and run **Actions > Build NetShield**. Download **NetShield-2.0.0-iOS16-rootless** for `com.eolnmsuk.netshield_2.0.0_iphoneos-arm64.deb`. CI validates metadata, runs policy/permission tests and builds with pinned Theos and iOS SDK versions.

For an upgrade, turn off the old filter and close NetShield before installation; then turn on the new Firewall switch. Check the [short release checklist](Tests/RELEASE_CHECKLIST.md).

The package uses the existing custom icon for the Home Screen and its `Icon` metadata. The local icon becomes available after installation. A first-time deb opened from Mail may show Sileo's generic icon before unpacking. A repository can supply a publicly hosted icon URL in its package metadata to show it before installation; no icon hosting is configured here.

## Coverage

Rules apply to new connections delivered by iOS, not every raw packet or OS-exempt path. Unidentified connections have their own rule. Direction rules refer to who initiates a connection, not reply packets. No VPN server entry is needed: this is a content filter, not a VPN tunnel.

This jailbreak deployment retains the existing development configuration entitlement required by the working setup; it is not an App Store deployment. Behavior on other iOS/jailbreak versions still needs testing. See [developer notes](Tests/BUILD_VALIDATION.md) for validation limits.

MIT License. Copyright 2026 EolnMsuk.
