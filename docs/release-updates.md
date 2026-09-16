# Release Updates

Relay Runner ships two release artifacts:

- `RelayRunner.dmg` is the first-install artifact for GitHub Releases.
- `RelayRunner.zip` is the Sparkle update archive for installed-app updates.

The app is configured with:

- `SUFeedURL`: `https://github.com/matthewthomas94/relay-runner-updates/releases/latest/download/appcast.xml`
- `SUPublicEDKey`: `a7hLtPfE0+/AM/igmohxiCV/GXonRJKUPuAzScAeXPo=`

`SPARKLE_ED_PRIVATE_KEY` must match the committed `SUPublicEDKey`. Before the first OTA release, generate the production key pair with Sparkle's `generate_keys`, commit the public key in `Info.plist`, and store the exported private key in GitHub Actions as `SPARKLE_ED_PRIVATE_KEY`.

## GitHub Secrets

Tagged releases fail early unless all release secrets are present:

- `SIGN_CERT_P12`: base64-encoded Developer ID Application certificate.
- `SIGN_CERT_PASSWORD`: password for the imported `.p12`.
- `KEYCHAIN_PASSWORD`: temporary CI keychain password.
- `SIGN_IDENTITY`: Developer ID Application identity used by `codesign`.
- `NOTARY_APPLE_ID`: Apple ID for `notarytool`.
- `NOTARY_TEAM_ID`: Apple Developer Team ID.
- `NOTARY_PASSWORD`: app-specific password for `notarytool`.
- `SPARKLE_ED_PRIVATE_KEY`: Sparkle EdDSA private key that matches `SUPublicEDKey`.
- `UPDATE_REPO_TOKEN`: GitHub token with permission to publish releases to `matthewthomas94/relay-runner-updates`.

Pull requests and normal `main` pushes do not require these secrets. CI explicitly allows isolated ad-hoc package artifacts when signing credentials are unavailable, but these builds do not generate or publish an appcast and cannot replace the installed app.

## Feed Hosting

The tag workflow attaches `RelayRunner.dmg`, `RelayRunner.zip`, and `appcast.xml` to the public source repository release and to the public update-only repository release. Installed apps read the feed through the update repository's stable latest-release asset URL:

```text
https://github.com/matthewthomas94/relay-runner-updates/releases/latest/download/appcast.xml
```

When generating a tagged release, CI sets `SPARKLE_DOWNLOAD_URL_PREFIX` to that tag's release download URL:

```text
https://github.com/matthewthomas94/relay-runner-updates/releases/download/<tag>/
```

That keeps old appcast entries stable even after a newer release becomes `latest`. Do not rename `RelayRunner.zip` after appcast generation because Sparkle signs the archive URL, length, and archive content into the feed.

If Relay Runner later moves to a branded update domain, change `SUFeedURL`, `SPARKLE_APPCAST_URL`, and `SPARKLE_DOWNLOAD_URL_PREFIX` together and keep the old feed URL live long enough for installed apps to cross the bridge.

`scripts/generate-appcast.sh` passes `--maximum-versions 0` to Sparkle's `generate_appcast`. Sparkle's default is to preserve only three versions per branch point, which can force users on older builds to install several sequential updates. Relay Runner keeps the full appcast history so a manual or automatic update can jump directly to the newest compatible release.

## Version Monotonicity

Sparkle compares `CFBundleVersion`, not `CFBundleShortVersionString`. Every public update must increase `CFBundleVersion` before tagging. Do not republish a different `RelayRunner.zip` for the same `CFBundleVersion`; bump the build number and regenerate the appcast instead.

`CFBundleShortVersionString` can follow product versioning, but it must not be used as the monotonic update key.

## Signing And Notarization

`scripts/build-dmg.sh` signs the nested Sparkle framework, helper binaries, main executable, and outer app bundle, waits for app notarization, and staples the app before creating `RelayRunner.zip`. When `SIGN_IDENTITY` and `NOTARY_PROFILE` are set, CI also waits for DMG notarization and staples `RelayRunner.dmg` before publishing release assets.

### Preserve permissions across updates

Local builds automatically select the Developer ID Application certificate for Relay Runner's release team (`QK9K4AQRNH`). Without that certificate, the build stops before replacing anything. `SIGN_IDENTITY` can select a certificate explicitly, but the resulting app must still satisfy the release identity check. Certificate renewal within that team is supported; an app version or executable hash is never part of the release requirement.

`services/app_signing.py` validates the signed app and its compatibility with the installed app's designated requirement before a build refresh or preserving reinstall. Tagged release packaging also checks the release identity before creating archives. These checks apply equally to Codex and Claude because the app owns their Relay permissions.

Ad-hoc builds require `RELAY_ALLOW_ADHOC_SIGNING=1` (and `SIGN_IDENTITY=-` to force one when a certificate is available). They are isolated test artifacts: the build skips `/Applications`, and the preserving installer rejects them. Replacing an earlier ad-hoc install with a Developer ID build may need one final macOS permission grant; subsequent signed updates retain the same identity.

macOS stores the app's designated requirement with a permission grant. A changing ad-hoc signature cannot preserve it. See [Apple's code signing requirements reference](https://developer.apple.com/documentation/technotes/tn3127-inside-code-signing-requirements).

For the old-version to new-version update checklist, service lifecycle checks, Codex/Claude active-session behavior, and TCC attribution checks, see `docs/verification/RR-68-ota-update-lifecycle.md`.

Before promoting a release broadly, confirm the tag workflow completed notarization and asset upload:

```bash
gh run list --workflow build-dmg.yml --limit 5
```

Downloaded artifacts should pass Gatekeeper assessment:

```bash
spctl -a -vv -t exec '/Applications/Relay Runner.app'
```

## Sparkle Key Rotation

Rotate Sparkle keys as a two-release process:

1. Generate a new EdDSA key pair with Sparkle's `generate_keys`.
2. Ship a bridge release that updates `SUPublicEDKey` to the new public key, but sign that release with the old private key so installed apps can verify it.
3. After the bridge release is installed, update `SPARKLE_ED_PRIVATE_KEY` to the new private key and sign future appcasts with it.

Do not change `SUPublicEDKey` and sign the same update only with the new private key; already-installed apps still verify the update with the old public key. Do not move `SUFeedURL` in the same bridge release unless the old feed remains available long enough for installed apps to cross the bridge.
