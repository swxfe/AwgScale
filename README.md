# AwgScale

AwgScale is a third-party iOS client compatible with Tailscale. It serves a similar role to `tailscale-ios`, embeds an AmneziaWG-capable fork of the open source Go networking backend through gomobile, and runs the data plane inside an iOS Packet Tunnel Network Extension.

This project is not affiliated with, sponsored by, endorsed by, or approved by Tailscale Inc. The Tailscale name is used in this repository only where needed to identify upstream open source components, service compatibility, protocol behavior, or legal notices.

## Backend

AwgScale builds `Libtailscale.xcframework` from the fork at https://github.com/LiuTangLei/tailscale, which keeps Tailscale-compatible control-plane behavior while replacing the standard WireGuard transport with an AmneziaWG-Go-based `wireguard-go` fork (`github.com/LiuTangLei/wireguard-go`).

AWG parameters are optional. When no AWG-specific parameters are configured, the tunnel uses standard WireGuard-compatible behavior and can interoperate with standard Tailscale clients using the normal WireGuard transport. If you only need the standard path and do not need AWG controls, the official Tailscale iOS app is usually the simpler choice.

## Status

AwgScale is experimental software. It is intended for development, testing, and self-managed distribution workflows where you can inspect the source and the built IPA yourself.

Implemented today:

- SwiftUI app with login, machine authorization polling, profile management, settings, diagnostics, and connection state.
- Packet Tunnel extension backed by a gomobile-built `Libtailscale.xcframework`.
- Login before VPN startup, including custom control server URLs for Headscale-compatible deployments.
- Exit node selection, LAN access preference, and iOS route exclusions for underlay gateways and peer endpoints so direct UDP can keep working while a default route is active.
- DNS display, MagicDNS/split-DNS state display, and an exit-node DNS fallback path for service-resolver-only configurations.
- Subnet route viewing and consumption of routes advertised by other devices.
- Taildrop file receive/share UI and send UI through the LocalAPI paths available in the backend.
- Tailnet Lock status/signing UI through the TKA LocalAPI endpoints.
- MDM policy display for the compatible managed-configuration keys.
- Amnezia-WG preference editing, local status display, and peer-to-local AWG config sync through custom LocalAPI endpoints in the patched backend.
- Bug report export with app state, health state, network state, and sanitized diagnostics.
- TrollStore/ldid-ready unsigned IPA packaging script.

Not implemented or still rough:

- App Store distribution and production provisioning profiles.
- Route-advertising/provider mode. The current iOS target consumes exit-node and subnet routes; it does not advertise this device as an exit node or subnet router. The concrete provider target is Apple TV/tvOS exit-node support, matching the upstream shape of a tvOS Network Extension plus the standard exit-node route-advertising prefs path; it still needs a tvOS target, entitlements, UI, and device validation.
- Keychain-backed state-store hardening. The Go state store already routes through `GoAppContext` Keychain helpers with a preferences fallback, but migration, access-group fallback behavior, and stale App Group repair need more focused tests before treating it as production-grade credential storage.
- Apple TV/tvOS packaging. There is no macOS UI target planned. A tvOS build should share as much SwiftUI and Packet Tunnel code as possible, but the install/signing/provisioning path and tvOS-specific Network Extension behavior still need design work.
- Tighter NetworkExtension workarounds. Several Apple VPN-framework quirks (e.g. settings-churn near manual disconnect, DNS scoping during exit-node DNS fallback, IPv6 route handling) are handled ad hoc and would benefit from a single documented compatibility layer.
- MDM policy coverage. We display the policy keys we currently consume, but the upstream managed-configuration surface is larger; we should enumerate and gate-test every key we honor, and explicitly reject ones we do not.
- Diagnostics and reproducibility. There is no CI yet, no signed-IPA reproducibility check, and no automated cross-check that the embedded `Libtailscale.xcframework` matches the patched backend revision committed under `build/tailscale-patched/`.

## Roadmap

- Better route-advertising support on platforms that can safely expose it.
- Continue hardening the typed Swift LocalAPI client with tests, naming cleanup, and coverage for new endpoints before views or state logic call the raw bridge directly.
- CI builds for Go tests, Swift tests, and device-target validation builds.
- More focused tests around profile switching, Taildrop, AWG sync, MDM policy locks, and tunnel shutdown races.

## Project Layout

```text
App/                   SwiftUI app and app assets
PacketTunnel/          Network Extension provider
Shared/                Shared Swift models, IPC, LocalAPI, VPN, and Go bridge code
libtailscale/          Go gomobile package wrapping the networking backend
Tests/                 Swift unit tests
build_go.sh            Builds Libtailscale.xcframework with gomobile
build_unsigned_ipa.sh  Builds a TrollStore/ldid-ready IPA
project.yml            XcodeGen source for AwgScale.xcodeproj
AwgScale.xcodeproj/    Generated Xcode project kept for convenience
```


## Build Requirements

- macOS with Xcode and iOS SDK.
- Go and gomobile for rebuilding `Libtailscale.xcframework`.
- XcodeGen if regenerating `AwgScale.xcodeproj` from `project.yml`.
- A signing or installation path that can provide the Packet Tunnel Network Extension entitlement. Normal ad-hoc signing alone is not enough for a working VPN extension on stock iOS.

## Build

Run these commands from the repository root.

Build the Go framework when Go code or the patched backend changes:

```sh
./build_go.sh --all
```

This rebuilds `Libtailscale.xcframework` from the forked backend. The IPA packaging script uses the framework already on disk and does not rebuild Go for you.

Regenerate the Xcode project after editing `project.yml` or changing the file layout:

```sh
xcodegen generate --spec project.yml --project .
```

Run a device-target validation build without code signing:

```sh
xcodebuild \
  -project AwgScale.xcodeproj \
  -scheme AwgScale \
  -configuration Debug \
  -sdk iphoneos \
  -derivedDataPath build/validation-derived \
  CODE_SIGNING_ALLOWED=NO \
  CODE_SIGNING_REQUIRED=NO \
  CODE_SIGN_IDENTITY='' \
  build
```

Build a TrollStore/ldid-ready IPA:

```sh
./build_unsigned_ipa.sh
```

The IPA is written to `build/unsigned-ipa/AwgScale-trollstore.ipa`.

## Distribution Notes

AwgScale currently targets self-managed installation flows such as TrollStore. The packaging script embeds the app-group, keychain, and packet-tunnel entitlements into an ad-hoc signed IPA so TrollStore can inspect them. TrollStore or the target device still needs the required CoreTrust/ldid-side support to install and run it.

Publishing only an IPA does not remove the obligations attached to the open source licenses. Binary redistribution must keep the required copyright notices, license text, patent notice, and disclaimers available with the distribution.

## Legal And Trademark Notes

AwgScale includes and links against open source code from `tailscale.com` and related repositories under the BSD 3-Clause license and the accompanying PATENTS grant. Keep [LICENSE](LICENSE) and [PATENTS](PATENTS) with source and binary redistributions.

The BSD 3-Clause license allows redistribution and modification in source and binary form, but it requires retaining the copyright notice, license conditions, and disclaimer. It also forbids using the name of Tailscale Inc. or its contributors to endorse or promote derived products without prior written permission.

WireGuard is a registered trademark of Jason A. Donenfeld. Amnezia-WG belongs to its respective upstream project. Other names may be trademarks of their owners.

## Safety

This is network software. Review source changes and built artifacts before installing it on devices that carry sensitive traffic. In particular, review control server URLs, auth-key handling, MDM policy behavior, and diagnostics before sharing logs or bug reports.
