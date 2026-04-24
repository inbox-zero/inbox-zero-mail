# Direct Releases

This project uses Sparkle for direct-download updates distributed outside the Mac App Store.

## One-time setup

1. Generate a Sparkle signing keypair on your Mac.
2. Export the private key for GitHub Actions.
3. Add the public key to the app build settings.
4. Add Developer ID + notarization secrets to GitHub.
5. Enable GitHub Pages for the `gh-pages` branch.

## Generate the Sparkle keypair

Clone Sparkle and build the `generate_keys` tool:

```bash
git clone --depth 1 --branch 2.9.1 https://github.com/sparkle-project/Sparkle /tmp/Sparkle
xcodebuild \
  -scheme generate_keys \
  -project /tmp/Sparkle/Sparkle.xcodeproj \
  -configuration Release \
  -derivedDataPath /tmp/SparkleDerivedData \
  build

/tmp/SparkleDerivedData/Build/Products/Release/generate_keys
```

The tool prints the public Ed25519 key. Put that value in:

- `Config/LocalSecrets.xcconfig` for local testing
- GitHub secret `SPARKLE_PUBLIC_ED_KEY` for release builds

Export the private key for CI:

```bash
/tmp/SparkleDerivedData/Build/Products/Release/generate_keys -x /tmp/sparkle-private-key.txt
```

Store the file contents as GitHub secret `SPARKLE_PRIVATE_KEY`.

## GitHub secrets

Add these repository secrets before pushing a release tag:

- `SPARKLE_PUBLIC_ED_KEY`
- `SPARKLE_PRIVATE_KEY`
- `DEVELOPER_ID_APPLICATION_CERT_BASE64`
- `DEVELOPER_ID_APPLICATION_CERT_PASSWORD`
- `BUILD_KEYCHAIN_PASSWORD`
- `APPLE_API_KEY_ID`
- `APPLE_API_ISSUER_ID`
- `APPLE_API_PRIVATE_KEY_BASE64`

Notes:

- `DEVELOPER_ID_APPLICATION_CERT_BASE64` is your Developer ID Application `.p12`, base64-encoded.
- `APPLE_API_PRIVATE_KEY_BASE64` is your App Store Connect API private key (`.p8`), base64-encoded.

## Release notes

Optional release notes files live in `release-notes/` and should be named either:

- `v1.2.3.md`
- `1.2.3.md`

If neither exists, the workflow publishes a minimal placeholder note.

## Shipping a release

1. Set `MARKETING_VERSION` in Xcode to the version you want to ship.
2. Increment `CURRENT_PROJECT_VERSION`.
3. Commit the version bump.
4. Tag the commit with the same marketing version, prefixed by `v`.
5. Push the tag.

Example:

```bash
git tag v1.0.0
git push origin v1.0.0
```

The `Direct Release` workflow will:

- archive the app
- sign it with your Developer ID certificate
- verify Sparkle's sandbox installer plist key and mach-lookup entitlements
- notarize it
- staple the notarization ticket
- upload the zipped app to GitHub Releases
- generate a Sparkle `appcast.xml`
- publish `appcast.xml` and release note files to `gh-pages`

## Broken updater recovery

Versions 0.1.0 through 0.1.2 shipped without Sparkle's sandbox installer
configuration in the signed release artifact. Those builds can detect an update
but cannot launch the installer. Users on those versions need to download the
latest release and replace the app manually once; subsequent direct-download
releases can update through Sparkle.

## Feed URL

Release builds point Sparkle at:

```text
https://<github-user>.github.io/<repo>/appcast.xml
```

That URL is injected by the release workflow and should also be used in local testing if you want to test against production appcasts.
