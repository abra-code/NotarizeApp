# Notarize

A native macOS GUI for Apple's notarization workflow. Drop an app on Notarize and it runs the full pipeline — code-sign, submit to Apple's notary service, wait for the result, staple the ticket, and package for distribution — or run any single step on its own. Notary credentials are set up once through a guided wizard and reused across every app.

**Requires macOS 14.6 (Sonoma) or later.**

---

## Overview

Notarize wraps the Apple toolchain (`codesign`, `xcrun notarytool`, `stapler`) in a single document window: drop or open a `.app`, pick a credential profile, and click **Notarize**. Each app being notarized gets its own window; a secondary sheet handles credential setup.

Notarize is built on the [OMC](https://abracode.com) framework with an ActionUI declarative UI engine. The UI is defined in `Contents/Resources/Base.lproj/`; all logic runs as POSIX shell scripts in `Contents/Resources/Scripts/`, shelling out to the system signing and notary tools. Notary output (JSON or plist) is parsed natively by OMC's `plister` tool, so no embedded interpreter is needed.

---

## Requirements

| Requirement | Notes |
|---|---|
| macOS 14.6+ | Sonoma minimum |
| Xcode Command Line Tools | Provides `notarytool` and `stapler`. Install with `xcode-select --install` (or a full Xcode). |
| Apple Developer ID Application certificate | In your keychain, for code-signing the app. |
| App Store Connect credentials | An Apple ID with an app-specific password (and team ID), or an App Store Connect API key. Stored once as a notary keychain profile (see below). |

Notarize bundles no binaries of its own; it drives the system tools (`codesign`, `ditto`, `spctl`, `security`) and the Xcode notary tools.

---

## Workflows

### Notarize (main flow)

The **Notarize** button runs the full pipeline on the loaded app:

1. **Sign** the app (and its nested frameworks and helper tools) with `codesign`, hardened runtime enabled, using the selected identity and optional entitlements.
2. **Zip** the signed app with `ditto` into a notarization archive.
3. **Submit** to Apple with `notarytool submit --wait` and wait for the verdict.
4. **Log** the notary results on failure (fetched with `notarytool log`).
5. **Staple** the ticket to the app with `stapler` once accepted.
6. **Re-zip** the stapled app for distribution.

The flow refuses to start if no credential profile is selected and points you at the credentials wizard.

### Credentials setup (one time)

Opened from the **Credentials...** button, a guided wizard creates and validates a notary keychain profile with `notarytool store-credentials`, choosing Apple ID or API-key authentication. It does not require an app to be loaded. Set credentials up once, then notarize many apps.

---

## Individual Actions

The **Actions** menu runs any single step without the full pipeline:

| Action | Tool |
|---|---|
| Sign Only | `codesign` |
| Check Signature | `codesign --verify`, `spctl --assess` |
| Submit | `notarytool submit` |
| View Log | `notarytool log` |
| Staple | `stapler staple` |
| Validate | `stapler validate`, `spctl` |

---

## Underlying Tools

| Tool | Role |
|---|---|
| `codesign` | Sign the app and its nested code; verify signatures |
| `ditto` | Package the app into a zip for submission and distribution |
| `xcrun notarytool` | Store credentials, submit, poll, and fetch logs |
| `xcrun stapler` | Staple and validate the notarization ticket |
| `spctl` | Gatekeeper assessment |
| `security` | Resolve signing identities in the keychain |

---

## Architecture

Notarize is an OMC 5.1 applet. The OMC framework handles the app lifecycle, the per-app document window, file dialogs, drag-and-drop, and the credential sheet. The UI is defined declaratively in ActionUI JSON. All business logic runs as POSIX shell scripts in `Contents/Resources/Scripts/`, with shared functions in `lib.notarize.sh` and command routing declared in `Contents/Resources/Command.json`. Per-app settings (identity, entitlements, credential profile) are remembered between runs.

---

## Building and Signing

The app runs as-is; it invokes system tools and bundles nothing to build. After changing scripts or UI JSON, re-sign the bundle so the signature stays valid:

```bash
./codesign_applet.sh Notarize.app -                                    # ad-hoc (local use)
./codesign_applet.sh Notarize.app "Developer ID Application: ..."       # for distribution
```

(And yes — you can notarize Notarize with itself.)

---

## License

Notarize is licensed under the Apache License 2.0 — see [LICENSE](LICENSE).
