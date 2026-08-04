# Notarize

A native macOS GUI for Apple's notarization workflow. Drop an app or an installer package on Notarize and it runs the full pipeline - sign, submit to Apple's notary service, wait for the result, staple the ticket, and assess the result - or run any single step on its own. Notary credentials are set up once through a guided wizard and reused across every target.

**Requires macOS 14.6 (Sonoma) or later.**

---

## Overview

Notarize wraps the Apple toolchain (`codesign`, `productsign`, `xcrun notarytool`, `stapler`) in a single document window: drop or open a `.app` bundle or a `.pkg` installer package, pick a credential profile, and click **Notarize**. Each target gets its own window; a secondary sheet handles credential setup.

The two kinds of target take the same route through the window but differ at every step that touches a signature or an upload, and Notarize picks the right one for you:

| | Application bundle | Installer package |
|---|---|---|
| File | `.app` | flat `.pkg` |
| Certificate | Developer ID Application | Developer ID **Installer** |
| Signed with | `codesign`, hardened runtime, entitlements | `productsign` |
| Uploaded as | a `ditto` zip | the package itself |
| Gatekeeper check | `spctl --type execute` | `spctl --type install` |
| Stapled with | `stapler staple` | `stapler staple` |

Old bundle-style packages (a `.pkg` that is a folder) are rejected with an explanation: the notary service only accepts flat packages, which is what `productbuild` produces. A flat `.mpkg` is accepted too, but only by dropping it on the window - the file panels filter on the flat-package type, which `.mpkg` does not claim.

---

## Requirements

| Requirement | Notes |
|---|---|
| macOS 14.6+ | Sonoma minimum |
| Xcode Command Line Tools | Provides `notarytool` and `stapler`. Install with `xcode-select --install` (or a full Xcode). |
| Apple Developer ID Application certificate | In your keychain, for signing apps. Only needed if you want Notarize to sign them; an app already signed elsewhere can be notarized without one. |
| Apple Developer ID Installer certificate | In your keychain, for signing installer packages. Only needed if you notarize `.pkg` files and want Notarize to sign them; a package already signed elsewhere can be notarized without one. |
| App Store Connect credentials | An Apple ID with an app-specific password (and team ID), or an App Store Connect API key. Stored once as a notary keychain profile (see below). |

Notarize bundles no binaries of its own; it drives the system tools (`codesign`, `productsign`, `pkgutil`, `ditto`, `spctl`, `security`, `xar`) and the Xcode notary tools.

---

## Workflows

### Notarize (main flow)

The **Notarize** button runs the full pipeline on the loaded target:

1. **Copy** to the output folder, when one is set, so release signing never happens on your development copy.
2. **Sign** it: an app (with its nested frameworks and helper tools) with `codesign` and the hardened runtime, using the selected identity and optional entitlements; a package with `productsign` and a Developer ID Installer identity. Skipped when the existing signature already matches every setting in the window - see below.
3. **Prepare the upload**: an app is zipped with `ditto`; a package is uploaded as it is.
4. **Submit** to Apple with `notarytool submit --wait` and wait for the verdict.
5. **Log** the notary results on failure (fetched with `notarytool log`).
6. **Staple** the ticket with `stapler` once accepted.
7. **Assess** the result with `spctl`.

The flow refuses to start if no credential profile is selected and points you at the credentials wizard.

The pipeline does not sign something that is already signed the way you asked. Before signing it compares the existing signature against the window: the certificate, the secure timestamp, the hardened runtime, and the entitlements. If all of them already match, signing is skipped and the log says so and why. Anything that differs - a different certificate, a missing hardened runtime, changed entitlements - is reported as the reason and the target is signed. This only applies to the full pipeline; **Sign Only** in the Actions menu always signs.

The comparison covers nested code, not just the outer bundle. A valid outer signature says nothing about a helper signed ad-hoc or an unsigned `.dylib` sitting in `Resources`: both pass `codesign --verify --deep --strict` and are then rejected by the notary service. Notarize checks the same set it would sign, so those are named in the log and the target is signed rather than uploaded.

You can also decline signing outright. The signing identity picker ends with a **Don't Code-sign** row, and choosing it sends the target to the notary service exactly as it arrived. It is worth having because re-signing is not always harmless: an app assembled by a build system this window cannot reproduce - nested code signed with entitlements of its own, a designated requirement that has to survive - can come out of a re-sign subtly different from what was tested. That call belongs to you, not to a guess made here. The choice is remembered for that target alone and is never adopted as a global default, so the next app you drop in still defaults to being signed.

A missing certificate is not a dead end either. Notarizing requires the target to be signed, not for Notarize to be the one that signed it, so with no certificate of the required class in your keychain the picker opens on **Don't Code-sign** and the pipeline checks the existing signature, carrying on if the notary service would accept it and stopping with an explanation if it would not. A package built and signed on another machine can be notarized here as it is.

Either way the log says which of the two applies - that you asked for it, or that there was no certificate to use - and **Sign Only** in the Actions menu tells you the same rather than appearing to ignore the button.

Signing a package replaces it atomically: `productsign` writes a hidden neighbour that is then renamed into place, so an interrupted run leaves either the old package or the new one, never a half-written file.

### Entitlements

The entitlements field is filled in automatically when a `.entitlements` file sits next to the app, so you can see what will be applied before anything is signed. What is in that field is exactly what gets used - nothing hidden is ever picked up from the surrounding folder.

Leave it empty and the app keeps the entitlements it already has. This matters more than it sounds: signing replaces a signature rather than amending it, so re-signing an app with no entitlements strips every entitlement it had. A sandboxed app would come out unsandboxed, correctly signed, and accepted by the notary service - broken in a way nothing downstream would flag. Notarize reads the existing entitlements out of the signature and re-applies them, and logs how many it carried over.

The same applies inside the bundle. Nested frameworks, helper tools and XPC services are re-signed too, and each keeps its own entitlements - an XPC helper does not lose `allow-jit` because the app around it was re-signed. The entitlements field governs the outer bundle only; nested code always carries over what it already had.

Settings are remembered per target, keyed by bundle identifier for an app and by package identifier for a package, so they follow the product rather than a file name carrying a version number.

### Credentials setup (one time)

Opened from the **Credentials...** button, a guided wizard creates and validates a notary keychain profile with `notarytool store-credentials`, choosing Apple ID or API-key authentication. It does not require an app to be loaded. Set credentials up once, then notarize many apps.

An existing profile is never replaced without asking. `notarytool store-credentials` treats its profile name as one "to create or update" and overwrites a matching profile in place, with no prompt and no way to recover what was there - the credentials it replaces cannot be read back out of the keychain by anything, including this app. That is easy to walk into: the wizard suggests a name, and the suggestion survives backing out and choosing a different authentication method, so an API-key save can land on the name an Apple ID profile is already using. So the wizard flags a name it already knows as soon as you type it, and confirms before it writes over anything - cancelling leaves the stored credentials exactly as they were.

Profiles created outside this app are checked too. They cannot be listed - `notarytool` keeps them in Apple's data protection keychain, where `security find-generic-password` cannot see them - so the wizard asks `notarytool` about the one name you typed. A name it has never registered and `notarytool` reports as absent is treated as free; anything else, including a profile whose credentials have expired or a notary service that cannot be reached, is treated as in use. Being wrong in that direction costs a confirmation you did not need. Being wrong the other way destroys credentials without asking.

---

## Individual Actions

The **Actions** menu runs any single step without the full pipeline:

| Action | Tool for an app | Tool for a package |
|---|---|---|
| Sign Only | `codesign` | `productsign` |
| Check Signature | `codesign -dv`, `codesign --verify`, `spctl --assess --type execute` | `pkgutil --check-signature`, `spctl --assess --type install` |
| Submit | `ditto` then `notarytool submit` | `notarytool submit` |
| View Log | `notarytool log` | `notarytool log` |
| Staple | `stapler staple` | `stapler staple` |
| Validate | `stapler validate`, `spctl` | `stapler validate`, `spctl` |

---

## Underlying Tools

| Tool | Role |
|---|---|
| `codesign` | Sign an app and its nested code; verify signatures |
| `productsign` | Sign an installer package |
| `pkgutil` | Report a package's signature and notarization ticket |
| `xar` | Read a package's identifier from its metadata, without expanding the payload |
| `ditto` | Copy to the output folder; zip an app for submission |
| `xcrun notarytool` | Store credentials, submit, poll, and fetch logs |
| `xcrun stapler` | Staple and validate the notarization ticket |
| `spctl` | Gatekeeper assessment |
| `security` | Resolve signing identities in the keychain |

---

## Architecture

Notarize is an OMC 5.1 applet. The OMC framework handles the app lifecycle, the per-target document window, file dialogs, drag-and-drop, and the credential sheet. The UI is defined declaratively in ActionUI JSON. All business logic runs as POSIX shell scripts in `Contents/Resources/Scripts/`, with shared functions in `lib.notarize.sh` and command routing declared in `Contents/Resources/Command.json`. Per-target settings (identity, entitlements, credential profile, output folder) are remembered between runs.

Everything that differs between an app and a package is decided by one function, `target_kind_of`, which returns `app` or `pkg` for a path; the handlers branch on that rather than each guessing from the extension. The two kinds keep separate default identities in preferences, because a Developer ID Application certificate and a Developer ID Installer certificate are not interchangeable - and an installer certificate is not even valid for the `codesigning` keychain policy, so the two are looked up under different policies.

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
