# NetShield2 ⛨

NetShield2 is a customizable firewall & live network monitor with actionable notifications for jailbroken iOS 15 16 17 18 devices. Unlike the original [NetShield](https://github.com/EolnMsuk/NetShield) and paid [NetFence](https://havoc.app/package/netfence), the new [**NetShield2**](https://github.com/EolnMsuk/NetShield2/) is a system wide content filter, which does not require app injection to function.

<img width="3857" height="5001" alt="1" src="https://github.com/user-attachments/assets/5ca44368-0cbb-4886-9b02-3822578cd90a" />

## Get started

1. Install the deb from the releases section. No respring is required.
2. Open NetShield2 from the homescreen and switch on the main **Firewall** toggle, accept the iOS Notification and allow **Filter Network Content**, enter passcode and close the VPN settings. To confirm the filter has been added, re-open Settings > General > VPN & Device Management > Content Filter > NetShield2... Running.
3. Recommended: return to NetShield2, tap **Notification Settings** and switch Banner Style from Temporary to **Persistent**. If you use **Do Not Disturb**, allow NetShield2 in **Settings > Focus > Do Not Disturb > Apps**.
4. When a new app connects, touch and hold the NetShield2 notification banner and choose **Allow In & Out**, **Block Incoming**, or **Keep Blocking**. Tapping the notification body (instead of long pressing) will open NetShield2 where you can also assign rules to any pending requests.

Unanswered connections are blocked after 30 seconds. The latest 64 expired requests remain in **Waiting for your decision**, where you can decide later and retry the app. Older requests are removed as history fills. To force a process to request again, tap its rule and select **Use Default Rule** and you will be notified the next time it requests the internet.

## Options

- **Firewall:** on/off; turning it off keeps your rules.
- **Filter System Sockets:** when enabled, the firewall is capable of filtering network for all apps and processes. Disable only if an app is crashing on launch.
- **Allow all iOS system processes:** when enabled, processes starting with `com.apple` are allowed without prompts or permission notifications.
- **Unidentified:** Allowed by default, set to blocked to prevent unknown processes from accessing network (not recommended).
- **Default Rule:** Ask me by default, changing this to Allow or Block will prevent prompting / notifications and block or allow any new requests.
- **Notifications:** notification settings and instructions for banners and Do Not Disturb.
- **Advanced Settings:** manual rules, Reset Rules & History and Reset ALL Settings.
- **Global Rules:** IP/domain and remote port rules apply across all processes.
- **App Rules:** change saved decisions. Changes apply to new connection requests only.
- **Recent Activity:** the rolling 300-event record grouped by process, IP/domain, remote port, direction and allowed/blocked outcome.

## Coverage

Rules apply to new connections delivered by iOS, not every raw packet or OS-exempt path. Direction rules refer to who initiates a connection. No VPN server entry is needed: it uses a content filter, not a VPN tunnel. To see the 

## Support Developer

[Venmo](https://venmo.com/u/rustonrails) | Bitcoin: `31uHLpioo1TbxAmo9kM7rrKcLz3wvcoZaL`
