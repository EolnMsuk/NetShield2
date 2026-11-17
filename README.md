# NetShield2 ⛨

A customizable firewall & live network monitor with actionable notifications for jailbroken iOS 15 16 17 18 devices. Unlike [NetFence](https://havoc.app/package/netfence), the new [**NetShield2**](https://github.com/EolnMsuk/NetShield2/) is a system wide content filter, which does not require app injection to function.

<img width="600" alt="SS" src="https://github.com/user-attachments/assets/0dd2fb6c-1b08-4e95-810f-6fb6af3266a4" />

## Get started

1. Download the (rootless or roothide or rootful) deb from the [latest release](https://github.com/EolnMsuk/NetShield2/releases/latest) page, open / install with Sileo or Zebra.
2. Open NetShield2 from the homescreen and switch on the main **Firewall** toggle, accept the iOS Notification and allow **Filter Network Content**, enter passcode.
3. Recommended: return to NetShield2, tap **Notification Settings** and switch Banner Style from Temporary to **Persistent**. If you use **Do Not Disturb**, allow NetShield2 in **Settings > Focus > Do Not Disturb > Apps**.
4. When a new app connects, touch and hold the NetShield2 notification banner and choose **Allow Outgoing** / **Block Outgoing**, or **Allow Incoming** / **Block Incoming**. Tapping the notification body (instead of long pressing) will open NetShield2 where you can also assign rules to any pending requests.

## Options

- **Firewall:** Enables/disables the content filter and rules.
- **Filter System Sockets:** When enabled, it allows filtering for all apps and processes (instead of just browsers).
- **Allow iOS system traffic:** Allows known iOS system traffic without prompting the user.
- **Block iOS system telemetry:** Blocks known iOS telemetrics & logging processes.
- **Unidentified:** Allowed by default, set to blocked to prevent unknown processes from accessing network (not recommended).
- **Default Rule:** Ask me by default, changing this to Allow or Block will prevent prompting / notifications and block or allow any new requests.
- **Notifications:** Notification settings and instructions for banners and Do Not Disturb.
- **Configuration:** Export Rules and Recent Activity, Reset Rules & History,  Settings, Check for Updates, GitHub Link, and Support Developer Links.
- **Check for Updates:** Choose Check Now, Check at Launch, Check Daily (the default) or Disable Updates. Check Now always remains available.
- **Global Rules:** use the Add Custom Rule button to add a global rule (direction, process, domain/ip, remote/local port, udp/tcp etc).
- **App Rules / System Rules:** Tapping an unlocked checked rule clears it; clearing the last checkmark restores **Default Rule**.
- **Recent Activity:** The rolling 300-event record grouped by process, IP/domain, remote port, direction and allowed/blocked outcome.

## Known Issues

- **Rebuild Icon Cache:** Using "Rebuild Icon Cache" while not jailbroken will disable the Firewall, remaining off until re-enabled from the NetShield2 settings (while jailbroken).
- **Coverage Gap:** When a user enables the firewall / filter sockets, then reboots userspace, the first 10-30 seconds will allow all processes to access internet (while NetShield2 loads). This behavior is intentional, fixing it would cause regression to non jailbroken states.

## Support the Developer

[Venmo](https://venmo.com/u/EolnMsuk) | Bitcoin: `31uHLpioo1TbxAmo9kM7rrKcLz3wvcoZaL`
