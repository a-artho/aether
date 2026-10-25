# Aether repository notes

## User-specific iPhone debug builds

- Install debug builds to the user's iPhone with bundle identifier `com.anfear.aetherW24N5PLW37` and provisioning team identifier `W24N5PLW37`. Do not infer the team identifier from the Apple Development certificate's displayed suffix; use the matching provisioning profile's TeamIdentifier.
- These device debug installs must omit `AetherTunnel.appex` and VPN/network-extension entitlements. Keep any temporary no-VPN build changes out of the app's source project.
- Install only; do not launch unless the user explicitly asks. Do not create a release or IPA unless explicitly requested.
- Reuse the existing `AetherDebugNoVPN.xcodeproj` setup and its DerivedData cache for incremental device builds. Do not create a fresh DerivedData directory for routine installs; use a clean cache only if the existing one is missing or invalid.
