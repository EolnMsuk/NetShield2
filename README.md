# NetShield2 ⛨

A firewall & live network filter for jailbroken iOS 16 devices. Installation is enabled for rootless iOS 15–18; **iOS 15, 17 and 18 are untested** and require device testing. NetShield2 uses an OS content filter, saved app rules and actionable notifications. Unlike the original [NetShield](https://github.com/EolnMsuk/NetShield) and paid [NetFence](https://havoc.app/package/netfence), the new [**NetShield2**](https://github.com/EolnMsuk/NetShield2/) is system wide and does not require app injection to function.

![NetShield2 banner](App/Resources/banner.png)

## Get started

1. Install the deb from the releases section. No respring is required.
2. Open NetShield2 and turn on **Firewall** + accept the iOS Notification and enter passcode, then close the VPN settings. Leave **Default Rule** set to **Ask me** to decide as apps connect. Existing rules are saved when upgrading or toggling the firewall.
3. If not already done by step 2, enable banners under **Notification settings**. If you use **Do Not Disturb**, allow NetShield2 in **Settings > Focus > Do Not Disturb > Apps**.
4. When a new app connects, touch and hold its NetShield2 notification and choose **Allow app** or **Keep blocking**. Tapping the notification body opens NetShield2 instead where you can also allow or block through prompts.

Unanswered connections are blocked after 30 seconds. You can decide later in **Waiting for your decision**, then retry the app. To ask again for a previously decided app, tap its rule and select **Use Default Rule**.

## Options

- **Firewall:** on/off; turning it off keeps your rules.
- **Allow all iOS system processes:** off by default. When enabled, processes starting with `com.apple` are allowed without prompts or permission notifications, overriding saved rules.
- **Default Rule:** Ask me, Allow or Block for apps without an explicit rule.
- **Notifications:** notification settings and instructions for banners and Do Not Disturb.
- **Advanced Settings:** manual rules, Reset NetShield2 and Prepare for uninstall.
- **App rules:** change saved decisions. Changes apply to new connections; close/reopen an app to end existing connections.
- **Recent activity:** the latest 20 events from a rolling 300-event record.

**Reset NetShield2** clears rules, requests and history, restores Ask me and allows unidentified connections, then leaves Firewall off. iOS notification permission is retained.

Before uninstalling, use **Advanced Settings > Prepare for uninstall** to remove the system filter. Then uninstall NetShield2 using your package manager.

## Coverage

Rules apply to new connections delivered by iOS, not every raw packet or OS-exempt path. Direction rules refer to who initiates a connection, not reply packets. No VPN server entry is needed: this is a content filter, not a VPN tunnel.

## Support Developer

[Venmo](https://venmo.com/u/rustonrails) | Bitcoin: `31uHLpioo1TbxAmo9kM7rrKcLz3wvcoZaL`
