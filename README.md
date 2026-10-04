<p align="center">
  <img src="docs/images/aether-icon.png" alt="Aether app icon" width="120">
</p>

Aether started as a fork of [Feather](https://github.com/claration/feather) by Samara. I liked its clean look and simplicity, but it was missing a few things I needed. I built Aether around my own workflow and tried to make the additions feel seamless.

- **Downloads:** Background queue with pause, resume, and retry, plus progress for exports.
- **Device:** View sideloaded apps, inspect details and entitlements, or uninstall them.
- **Install modes:** Switch from the Device header. Server installs through a locally hosted IPA; Local installs through a tunnel and pairing file.
- **Pairing:** Pair on-device on iOS 27, or import a pairing file.
- **Tunnelling:** Use the built-in tunnel or LocalDevVPN. Local mode connects automatically, with an option to turn the tunnel off in the background when idle.
- **Cellular Assist:** An optional Shortcut briefly turns Mobile Data off if it interferes with the in-app tunnel, then restores it.
- **Location spoofing:** Adapted from [Locus](https://github.com/ChrisMack32/Locus), with dynamic Remote Pairing port lookup.
- **UI:** Reworked navigation, app lists, details, and controls to fit how I use the app.

**Requires iOS 26+.** Aether's navigation and controls are built around iOS 26's Liquid Glass UI. Supporting older versions would mean keeping a separate UI path and testing both whenever those screens change—not just lowering the deployment target. This started as an app for my own use, so I chose one baseline I can actually test and maintain. Also, I'm lazy. Native iPad support was dropped too; I'm focusing on iPhone for now.

**Signing:** The built-in tunnel needs a paid certificate and the `packet-tunnel-provider` and `allow-vpn` entitlements.

## Building

Before opening the Xcode project for the first build, install Rust from [rustup.rs](https://rustup.rs) and run `make native`. This builds Aether's pinned, patched device library. See [native build details](IDeviceKitten/Native/README.md). Generated native binaries stay outside Git.

## Screenshots

<p align="center">
  <a href="docs/images/library.png"><img src="docs/images/library.png" alt="Library with downloads and signed apps" width="180"></a>
  <a href="docs/images/device-local.png"><img src="docs/images/device-local.png" alt="Device in Local mode" width="180"></a>
  <a href="docs/images/device-server.png"><img src="docs/images/device-server.png" alt="Device in Server mode" width="180"></a>
  <a href="docs/images/spoofing.png"><img src="docs/images/spoofing.png" alt="Location spoofing" width="180"></a>
</p>

<details>
  <summary>More screenshots</summary>
  <p align="center">
    <a href="docs/images/sources.png"><img src="docs/images/sources.png" alt="Apps in a source" width="180"></a>
    <a href="docs/images/app-details.png"><img src="docs/images/app-details.png" alt="App details" width="180"></a>
    <a href="docs/images/settings.png"><img src="docs/images/settings.png" alt="Settings" width="180"></a>
  </p>
</details>

## Download

Get the latest IPA from the [releases page](https://github.com/a-artho/Aether/releases).

## Acknowledgements

- [Feather](https://github.com/claration/feather) by Samara — the project Aether was originally forked from.
- [Locus](https://github.com/ChrisMack32/Locus) by ChrisMack32 — the original location-spoofing app that Aether's spoofing feature is adapted from.
- [idevice](https://github.com/jkcoxson/idevice) — device communication.
- [Vapor](https://github.com/vapor/vapor) — local HTTP server support.
- [Zsign](https://github.com/zhlynn/zsign) — on-device code signing support.
- [Nuke](https://github.com/kean/Nuke) — image loading and caching.

## License

Aether is licensed under the [GNU GPL v3.0](LICENSE). It builds on GPL-licensed Feather code, so the fork remains under the GPL rather than adding an MIT license for the whole app.
