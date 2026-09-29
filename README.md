# NetShield2 â›¨

A firewall & live network filter for jailbroken iOS 15 - 18 devices. NetShield2 uses an OS content filter, saved app rules and actionable notifications. Unlike the original [NetShield](https://github.com/EolnMsuk/NetShield) and paid [NetFence](https://havoc.app/package/netfence), the new [**NetShield2**](https://github.com/EolnMsuk/NetShield2/) is system wide and does not require app injection to function.

![NetShield2 banner](App/Resources/banner.png)

## Get started

1. Install the deb from the releases section. No respring is required.
2. Open NetShield2 and turn on **Firewall** + accept the iOS Notification and enter passcode, then close the VPN settings. Leave **Default Rule** set to **Ask me** to decide as apps connect.
3. If not already done by step 2, enable banners under **Notification Settings**. If you use **Do Not Disturb**, allow NetShield2 in **Settings > Focus > Do Not Disturb > Apps**.
4. When a new app connects, touch and hold its NetShield2 notification and choose **Allow In & Out**, **Block Incoming**, or **Keep Blocking**. Tapping the notification body opens NetShield2 instead where prompts offer **Allow In & Out**, **Block Incoming**, **Block Outgoing**, **Block In & Out**, and **Not Now**.

Unanswered connections are blocked after 30 seconds. The latest 64 expired requests remain in **Waiting for your decision**, where you can decide later and retry the app. Older requests are removed as history fills; retry an app to request a new decision if it is no longer listed. To ask again for a previously decided app, tap its rule and select **Use Default Rule**.

## Options

- **Firewall:** on/off; turning it off keeps your rules.
- **Filter System Sockets:** when enabled, the firewall is capable of filtering network for all apps and processes. Disable only if an app is crashing on launch.
- **Allow all iOS system processes:** when enabled, processes starting with `com.apple` are allowed without prompts or permission notifications, overriding saved rules. These identities are hidden from **App rules** while enabled, but remain visible in **Recent activity**.
- **Unidentified:** Allow by default, set to block to prevent unknown processes from accessing network.
- **Default Rule:** Ask me by default, set to Allow or Block for apps without an explicit rule.
- **Notifications:** notification settings and instructions for banners and Do Not Disturb.
- **Advanced Settings:** manual rules, Reset Rules & History and Reset ALL Settings.
- **App rules:** change saved decisions. Changes apply to new connections; close/reopen an app to end existing connections.
- **Recent activity:** the rolling 300-event record grouped by process, IP/domain, direction and allowed/blocked outcome. Each row shows the latest time, connection count and combined received/sent data in MB (1,000,000 bytes), rounded to one decimal place. Tap a process to change its rule. Rows are green for allowed activity and red for blocked activity; **Block Incoming** App Rules are orange, **Block Outgoing** and **Block In & Out** rules are red, and **Allow In & Out** rules are green.

## Coverage

Rules apply to new connections delivered by iOS, not every raw packet or OS-exempt path. Direction rules refer to who initiates a connection, not reply packets. No VPN server entry is needed: this is a content filter, not a VPN tunnel.

## Support Developer

[Venmo](https://venmo.com/u/rustonrails) | Bitcoin: `31uHLpioo1TbxAmo9kM7rrKcLz3wvcoZaL`