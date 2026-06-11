# Release Updates

Relay Runner ships two release artifacts:

- `RelayRunner.dmg` is the first-install artifact for GitHub Releases.
- `RelayRunner.zip` is the Sparkle update archive for installed-app updates.

The app is configured with:

- `SUFeedURL`: `https://updates.relayrunner.app/appcast.xml`
- `SUPublicEDKey`: `LORldNflpZEdwXs4OhcYDo+bpUKPmzXmJjI2fr3n97c=`

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

The tag workflow attaches `RelayRunner.dmg`, `RelayRunner.zip`, and `appcast.xml` to the GitHub Release. The update host must also publish these files at the stable feed origin:

```text
https://updates.relayrunner.app/appcast.xml
https://updates.relayrunner.app/RelayRunner.zip
```

Keep `SPARKLE_DOWNLOAD_URL_PREFIX` set to `https://updates.relayrunner.app/` when generating the appcast. Do not rename `RelayRunner.zip` after appcast generation because Sparkle signs the archive URL, length, and archive content into the feed.

## Version Monotonicity

Sparkle compares `CFBundleVersion`, not `CFBundleShortVersionString`. Every public update must increase `CFBundleVersion` before tagging. Do not republish a different `RelayRunner.zip` for the same `CFBundleVersion`; bump the build number and regenerate the appcast instead.

`CFBundleShortVersionString` can follow product versioning, but it must not be used as the monotonic update key.

## Signing And Notarization

`scripts/build-dmg.sh` signs the nested Sparkle framework, helper binaries, main executable, and outer app bundle before creating `RelayRunner.zip`. When `SIGN_IDENTITY` and `NOTARY_PROFILE` are set, CI submits both `RelayRunner.dmg` and `RelayRunner.zip` to Apple notary service.

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
