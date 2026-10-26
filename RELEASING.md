# Releasing Starnotch

Everything is prepared except your Apple Developer credentials. These steps are done once; after that, a release is one tag.

## Once: the Apple side

1. Join the Apple Developer Program (Account Holder, 99 USD per year).
2. In Xcode › Settings › Accounts, add the Apple ID, then **Manage Certificates › + › Developer ID Application**. Or create it at developer.apple.com › Certificates.
3. Check that it is there:
   ```sh
   security find-identity -v -p codesigning
   # "Developer ID Application: Your Name (TEAMID)"
   ```
4. Create an app-specific password at appleid.apple.com › Sign-In and Security › App-Specific Passwords.
5. Store the notarization credentials in your Keychain under a profile name. The scripts use `starnotch-notary`:
   ```sh
   xcrun notarytool store-credentials starnotch-notary \
     --apple-id you@example.com --team-id TEAMID --password <app-specific password>
   ```

## Once: updates (Sparkle 2)

1. Download Sparkle's release tools (the `.tar.xz` at github.com/sparkle-project/Sparkle/releases) and unpack them. You need the `bin/` folder.
2. Create the EdDSA key pair. The private key goes into your Keychain:
   ```sh
   ./bin/generate_keys            # prints the public key
   ./bin/generate_keys -x sparkle-private.key   # export, only for the CI secret; then delete the file
   ```
3. The public key goes into release builds through `SPARKLE_PUBLIC_KEY`. The feed URL is `https://starnotch.app/appcast.xml`: downloads and feed live in the public site repository (`juliokoelle/starnotch-site`), so updates keep working while this repository is private.

No key is in this repository.

## A release by hand

```sh
export VERSION=0.2.0
export STARNOTCH_SPARKLE=1
export SPARKLE_FEED_URL=https://starnotch.app/appcast.xml
export SPARKLE_PUBLIC_KEY=<public key from generate_keys>
export DEVELOPER_ID="Developer ID Application: Your Name (TEAMID)"
export NOTARY_PROFILE=starnotch-notary

./scripts/build-app.sh                              # build/Starnotch.app, with Sparkle
./scripts/release/sign-and-notarize.sh build/Starnotch.app
./scripts/release/make-dmg.sh build/Starnotch.app "$VERSION"   # prints the sha256
mkdir -p build/releases && mv build/starnotch-$VERSION.dmg build/releases/
SPARKLE_BIN=~/Downloads/Sparkle/bin \
  DOWNLOAD_URL_PREFIX=https://github.com/juliokoelle/starnotch/releases/download/v$VERSION/ \
  ./scripts/release/appcast.sh build/releases
gh release create v$VERSION build/releases/starnotch-$VERSION.dmg build/releases/appcast.xml --generate-notes
```

## A release from GitHub Actions

`.github/workflows/release.yml` runs the same steps when a tag `v*` is pushed. First add these repository secrets (Settings › Secrets and variables › Actions):

| Secret | What |
|---|---|
| `DEVELOPER_ID_P12` | `base64 -i DeveloperID.p12` (export the certificate with its key from Keychain Access) |
| `DEVELOPER_ID_P12_PASSWORD` | the export password |
| `DEVELOPER_ID` | `Developer ID Application: Your Name (TEAMID)` |
| `APPLE_ID`, `APPLE_TEAM_ID`, `APPLE_APP_PASSWORD` | for notarytool |
| `SPARKLE_PRIVATE_KEY` | contents of `sparkle-private.key` |
| `SPARKLE_PUBLIC_KEY` | the public key |
| `SITE_TOKEN` | a fine-grained personal access token for `juliokoelle/starnotch-site` with Contents: read and write (github.com › Settings › Developer settings › Fine-grained tokens) |

The workflow puts the DMG into a release of the site repository (also as `Starnotch.dmg`, so `https://github.com/juliokoelle/starnotch-site/releases/latest/download/Starnotch.dmg` always is the newest) and commits `appcast.xml` to the site.

Then:

```sh
git tag v0.2.0 && git push origin v0.2.0
```

## Homebrew

`packaging/homebrew/starnotch.rb` is the cask. Fill in `version` and `sha256` (from `make-dmg.sh`). Then either:
- open a pull request at Homebrew/homebrew-cask (it needs a notarized release and some usage), or
- keep it in a tap of your own (`juliokoelle/homebrew-tap`).

## Checks before a tag

- `./scripts/test.sh` and `integrations/claude-code/tests/test-hook.sh` are green.
- On a second Mac, the downloaded DMG opens without a Gatekeeper warning.
- "Check for Updates…" appears in the menu and finds the new version.
