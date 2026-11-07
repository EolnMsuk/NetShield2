# NetShield2 ⛨

A customizable firewall & live network monitor with actionable notifications for jailbroken iOS 15 16 17 18 devices. Unlike the original [NetShield](https://github.com/EolnMsuk/NetShield) and paid [NetFence](https://havoc.app/package/netfence), the new [**NetShield2**](https://github.com/EolnMsuk/NetShield2/) is a system wide content filter, which does not require app injection to function.

<img width="1280" height="1689" alt="ALL" src="https://github.com/user-attachments/assets/8762df84-bfc0-464a-a8fa-aaa5aa70cdd3" />

## Get started

1. Download the (rootless or roothide or rootful) deb from the [latest release](https://github.com/EolnMsuk/NetShield2/releases/latest) page, open / install with Sileo or Zebra.
2. Open NetShield2 from the homescreen and switch on the main **Firewall** toggle, accept the iOS Notification and allow **Filter Network Content**, enter passcode.
3. Recommended: return to NetShield2, tap **Notification Settings** and switch Banner Style from Temporary to **Persistent**. If you use **Do Not Disturb**, allow NetShield2 in **Settings > Focus > Do Not Disturb > Apps**.
4. When a new app connects, touch and hold the NetShield2 notification banner and choose **Allow Outgoing** / **Block Outgoing**, or **Allow Incoming** / **Block Incoming**. Tapping the notification body (instead of long pressing) will open NetShield2 where you can also assign rules to any pending requests.

## Options

- **Firewall:** On/Off; enables/disables the content filter and rules.
- **Filter System Sockets:** When enabled, the firewall is capable of filtering network for all apps and processes. Disable only if an app is crashing on launch.
- **Allow all iOS system processes:** When enabled, processes starting with `com.apple` are allowed without prompts or permission notifications.
- **Unidentified:** Allowed by default, set to blocked to prevent unknown processes from accessing network (not recommended).
- **Default Rule:** Ask me by default, changing this to Allow or Block will prevent prompting / notifications and block or allow any new requests.
- **Notifications:** Notification settings and instructions for banners and Do Not Disturb.
- **Configuration:** Export Rules and Recent Activity, Reset Rules & History,  Settings, Check for Updates, GitHub Link, and Support Developer Links.
- **Check for Updates:** Choose Check Now, Check at Launch, Check Daily (the default) or Disable Updates. Check Now always remains available.
- **Global Rules:** use the Add Custom Rule button to add a global rule (direction, process, domain/ip, remote/local port, udp/tcp etc).
- **App Rules / System Rules:** Tapping a checked rule clears it; clearing the last checkmark restores **Default Rule**.
- **Recent Activity:** The rolling 300-event record grouped by process, IP/domain, remote port, direction and allowed/blocked outcome.

## Known Issues

- **Coverage Gap:** When a user enables the firewall, then reboots into non-jailbrokeen state, then re-jailbreaks, the first 10-30 seconds (after boot) will allow all processes to access internet (while the package loads). This is a side-effect from a previous fix, where users would not have internet while in a non jailbroken state if the firewall was left ON (before rebooting). That issue was fixed by allowing all network activity while the package is not loaded. The coverage gap is worth keeping vs the no-internet while not jailbroken issue imo. If a fix is found that doesn't conflict, I will update the readme / release.

## Coverage

Rules apply to new connections delivered by iOS. Direction rules refer to who initiates a connection. No VPN server entry is needed: it uses a content filter, not a VPN tunnel.

## Support the Developer

[Venmo](https://venmo.com/u/rustonrails) | Bitcoin: `31uHLpioo1TbxAmo9kM7rrKcLz3wvcoZaL`
