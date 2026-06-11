# Release Updates

Relay Runner ships two release artifacts:

- `RelayRunner.dmg` is the first-install artifact for GitHub Releases.
- `RelayRunner.zip` is the Sparkle update archive for installed-app updates.

The app is configured with:

- `SUFeedURL`: `https://github.com/matthewthomas94/relay-runner/releases/latest/download/appcast.xml`
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

Pull requests and normal `main` pushes do not require these secrets. They build ad-hoc package artifacts so packaging regressions still surface, but they do not generate or publish an appcast.

## Feed Hosting

The tag workflow attaches `RelayRunner.dmg`, `RelayRunner.zip`, and `appcast.xml` to the GitHub Release. Installed apps read the feed through GitHub's stable latest-release asset URL:

```text
https://github.com/matthewthomas94/relay-runner/releases/latest/download/appcast.xml
```

When generating a tagged release, CI sets `SPARKLE_DOWNLOAD_URL_PREFIX` to that tag's release download URL:

```text
https://github.com/matthewthomas94/relay-runner/releases/download/<tag>/
```

That keeps old appcast entries stable even after a newer release becomes `latest`. Do not rename `RelayRunner.zip` after appcast generation because Sparkle signs the archive URL, length, and archive content into the feed.

If Relay Runner later moves to a branded update domain, change `SUFeedURL`, `SPARKLE_APPCAST_URL`, and `SPARKLE_DOWNLOAD_URL_PREFIX` together and keep the old feed URL live long enough for installed apps to cross the bridge.

## Version Monotonicity

Sparkle compares `CFBundleVersion`, not `CFBundleShortVersionString`. Every public update must increase `CFBundleVersion` before tagging. Do not republish a different `RelayRunner.zip` for the same `CFBundleVersion`; bump the build number and regenerate the appcast instead.

`CFBundleShortVersionString` can follow product versioning, but it must not be used as the monotonic update key.

## Signing And Notarization

`scripts/build-dmg.sh` signs the nested Sparkle framework, helper binaries, main executable, and outer app bundle before creating `RelayRunner.zip`. When `SIGN_IDENTITY` and `NOTARY_PROFILE` are set, CI submits both `RelayRunner.dmg` and `RelayRunner.zip` to Apple notary service.

For the old-version to new-version update checklist, service lifecycle checks, Codex/Claude active-session behavior, and TCC attribution checks, see `docs/verification/RR-68-ota-update-lifecycle.md`.

The current workflow submits notarization asynchronously. Before promoting a release broadly, check:

```bash
xcrun notarytool history --keychain-profile relay-runner-notary
```

If the DMG is accepted and you need offline-friendly first install, staple the DMG before redistributing it:

```bash
xcrun stapler staple dist/RelayRunner.dmg
```

## Sparkle Key Rotation

Rotate Sparkle keys as a two-release process:

1. Generate a new EdDSA key pair with Sparkle's `generate_keys`.
2. Ship a bridge release that updates `SUPublicEDKey` to the new public key, but sign that release with the old private key so installed apps can verify it.
3. After the bridge release is installed, update `SPARKLE_ED_PRIVATE_KEY` to the new private key and sign future appcasts with it.

Do not change `SUPublicEDKey` and sign the same update only with the new private key; already-installed apps still verify the update with the old public key. Do not move `SUFeedURL` in the same bridge release unless the old feed remains available long enough for installed apps to cross the bridge.
