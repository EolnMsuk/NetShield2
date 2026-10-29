# NetShield2 ⛨

A customizable firewall & live network monitor with actionable notifications for jailbroken iOS 15 16 17 18 devices. Unlike the original [NetShield](https://github.com/EolnMsuk/NetShield) and paid [NetFence](https://havoc.app/package/netfence), the new [**NetShield2**](https://github.com/EolnMsuk/NetShield2/) is a system wide content filter, which does not require app injection to function.

<img width="1280" height="1689" alt="ALL" src="https://github.com/user-attachments/assets/8762df84-bfc0-464a-a8fa-aaa5aa70cdd3" />

## Get started

1. Install the (rootless or roothide or rootful) deb from the [latest release](https://github.com/EolnMsuk/NetShield2/releases/latest) page. No respring is required.
2. Open NetShield2 from the homescreen and switch on the main **Firewall** toggle, accept the iOS Notification and allow **Filter Network Content**, enter passcode. To confirm the filter has been added, re-open Settings > General > VPN & Device Management > Content Filter > NetShield2... Running.
3. Recommended: return to NetShield2, tap **Notification Settings** and switch Banner Style from Temporary to **Persistent**. If you use **Do Not Disturb**, allow NetShield2 in **Settings > Focus > Do Not Disturb > Apps**.
4. When a new app connects, touch and hold the NetShield2 notification banner and choose **Allow Outgoing** / **Block Outgoing**, or **Allow Incoming** / **Block Incoming**, according to the connection direction. Tapping the notification body (instead of long pressing) will open NetShield2 where you can also assign rules to any pending requests.

Unanswered connections are blocked after 30 seconds. The latest 64 expired requests remain in **Waiting for your decision**, where you can decide later and retry the app. Older requests are removed as history fills. To force a process to request again, open its App Rules/System Rules row and select Remove Rule (or swipe left on that row).

## Options

- **Firewall:** on/off; enables/disables the content filter and rules.
- **Filter System Sockets:** when enabled, the firewall is capable of filtering network for all apps and processes. Disable only if an app is crashing on launch.
- **Allow all iOS system processes:** when enabled, processes starting with `com.apple` are allowed without prompts or permission notifications.
- **Unidentified:** Allowed by default, set to blocked to prevent unknown processes from accessing network (not recommended).
- **Default Rule:** Ask me by default, changing this to Allow or Block will prevent prompting / notifications and block or allow any new requests.
- **Notifications:** notification settings and instructions for banners and Do Not Disturb.
- **Support:** Export Rules and Recent Activity, Reset Rules & History, Reset ALL Settings, Check for Update, GitHub Link, and Support Developer Links.
- **Advanced Settings:** manual app identity, IP/domain and local/remote port rules.
- **Global Rules:** use the Add Global Rule button to add a custom rule (direction, process, domain/ip, remote/local port, udp/tcp etc).
- **App Rules / System Rules:** each identity has one row with independent incoming and outgoing decisions. Tap the row to review all active checkmarks. Selections save immediately and Done closes the editor; tapping a checked rule does nothing. Both-directions actions replace individual selections. Unset directions follow the Default Rule. Swipe left on a saved app or global rule and tap **Remove** to delete it.
- **Recent Activity:** the rolling 300-event record grouped by process, IP/domain, remote port, direction and allowed/blocked outcome.

Existing directional block rules now cover only their named direction; the opposite direction follows the Default Rule. App and System Rules use the same behavior. Connection sheets show applicable choices, the full app/process identity, Copy details, and connection details in that order.

## Coverage

Rules apply to new connections delivered by iOS, not every raw packet or OS-exempt path. Direction rules refer to who initiates a connection. No VPN server entry is needed: it uses a content filter, not a VPN tunnel.

## Support the Developer

[Venmo](https://venmo.com/u/rustonrails) | Bitcoin: `31uHLpioo1TbxAmo9kM7rrKcLz3wvcoZaL`
