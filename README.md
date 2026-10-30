# NetShield2 ⛨

A customizable firewall & live network monitor with actionable notifications for jailbroken iOS 15 16 17 18 devices. Unlike the original [NetShield](https://github.com/EolnMsuk/NetShield) and paid [NetFence](https://havoc.app/package/netfence), the new [**NetShield2**](https://github.com/EolnMsuk/NetShield2/) is a system wide content filter, which does not require app injection to function.

<img width="1280" height="1689" alt="ALL" src="https://github.com/user-attachments/assets/8762df84-bfc0-464a-a8fa-aaa5aa70cdd3" />

## Get started

1. Download the (rootless or roothide or rootful) deb from the [latest release](https://github.com/EolnMsuk/NetShield2/releases/latest) page, open / install with Sileo or Zebra.
2. Open NetShield2 from the homescreen and switch on the main **Firewall** toggle, accept the iOS Notification and allow **Filter Network Content**, enter passcode.
3. Recommended: return to NetShield2, tap **Notification Settings** and switch Banner Style from Temporary to **Persistent**. If you use **Do Not Disturb**, allow NetShield2 in **Settings > Focus > Do Not Disturb > Apps**.
4. When a new app connects, touch and hold the NetShield2 notification banner and choose **Allow Outgoing** / **Block Outgoing**, or **Allow Incoming** / **Block Incoming**. Tapping the notification body (instead of long pressing) will open NetShield2 where you can also assign rules to any pending requests.

## Options

- **Firewall:** on/off; enables/disables the content filter and rules.
- **Filter System Sockets:** when enabled, the firewall is capable of filtering network for all apps and processes. Disable only if an app is crashing on launch.
- **Allow all iOS system processes:** when enabled, processes starting with `com.apple` are allowed without prompts or permission notifications.
- **Unidentified:** Allowed by default, set to blocked to prevent unknown processes from accessing network (not recommended).
- **Default Rule:** Ask me by default, changing this to Allow or Block will prevent prompting / notifications and block or allow any new requests.
- **Notifications:** notification settings and instructions for banners and Do Not Disturb.
- **Support:** Export Rules and Recent Activity, Reset Rules & History, Reset ALL Settings, Check for Updates, GitHub Link, and Support Developer Links.
- **Advanced Settings:** manual app identity, IP/domain and local/remote port rules.
- **Global Rules:** use the Add Global Rule button to add a custom rule (direction, process, domain/ip, remote/local port, udp/tcp etc).
- **App Rules / System Rules:** Tapping a checked rule clears it; clearing the last checkmark restores **Default Rule**. Unset directions follow the default policy, subject to global rules and the iOS system allowance.
- **Recent Activity:** the rolling 300-event record grouped by process, IP/domain, remote port, direction and allowed/blocked outcome.

## Coverage

Rules apply to new connections delivered by iOS, not every raw packet or OS-exempt path. Direction rules refer to who initiates a connection. No VPN server entry is needed: it uses a content filter, not a VPN tunnel.

## Support the Developer

[Venmo](https://venmo.com/u/rustonrails) | Bitcoin: `31uHLpioo1TbxAmo9kM7rrKcLz3wvcoZaL`
