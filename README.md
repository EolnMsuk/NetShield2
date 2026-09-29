# NetShield2 ⛨

A firewall & live network filter for jailbroken iOS 15 - 18 devices. NetShield2 uses an OS content filter, saved app rules and actionable notifications. Unlike the original [NetShield](https://github.com/EolnMsuk/NetShield) and paid [NetFence](https://havoc.app/package/netfence), the new [**NetShield2**](https://github.com/EolnMsuk/NetShield2/) is system wide and does not require app injection to function.

<img width="4242" height="5114" alt="screenshots" src="https://github.com/user-attachments/assets/252b7bb8-e007-4896-81c4-7c5f73602629" />

## Get started

1. Install the deb from the releases section (roothide users must convert rootless deb with patcher before installing). No respring is required.
2. Open NetShield2 and turn on **Firewall** + accept the iOS Notification and Allow content filter / type passcode, then close the VPN settings.
3. Recommended: Within NetShield2 tap **Notification Settings** and enable **Persistent Banners**. If you use **Do Not Disturb**, allow NetShield2 in **Settings > Focus > Do Not Disturb > Apps**.
4. When a new process requests internet, NetShield2's notification banner will appear, long press it to choose **Allow In & Out**, **Block Incoming**, **Keep blocking**. Tapping the notification body instead opens NetShield2 where you can also assign rules to the pending requests.

Unanswered connections are blocked by default. The latest 64 expired requests remain in **Waiting for your decision**, where you can decide later and retry the app. Older requests are removed as history fills; retry an app to request a new decision if it is no longer listed. To ask again for a previously decided app, tap its rule and select **Use Default Rule**.

## Options

- **Firewall:** on/off; turning it off keeps your rules.
- **Filter System Sockets:** when enabled, the firewall is capable of filtering network for all apps and processes. Disable only if an app is crashing on launch.
- **Allow all iOS system processes:** when enabled, processes starting with `com.apple` are allowed without prompts or permission notifications, overriding saved rules.
- **Unidentified:** Allow by default, set to block to prevent unknown processes from accessing network.
- **Default Rule:** Ask me by default, set to Allow or Block for apps without an explicit rule.
- **Notifications:** notification settings and instructions for banners and Do Not Disturb.
- **Advanced Settings:** manual rules, Reset Rules & History and Reset ALL Settings.
- **App rules:** change saved decisions. Changes apply to new connections; close/reopen an app to end existing connections.
- **Recent activity:** the latest 20 events from a rolling 300-event record.

## Coverage

Rules apply to new connections delivered by iOS, not every raw packet or OS-exempt path. Direction rules refer to who initiates a connection, not reply packets. No VPN server entry is needed: this is a content filter, not a VPN tunnel.

## Support Developer

[Venmo](https://venmo.com/u/rustonrails) | Bitcoin: `31uHLpioo1TbxAmo9kM7rrKcLz3wvcoZaL`
