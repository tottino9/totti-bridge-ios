# Rokid Lyrics iOS

Native iOS companion for Rokid Lyrics.

This repository is intentionally set up for GitHub Actions IPA builds. The iOS version is a SwiftUI companion with Spotify currently-playing lookup, local synced playback preview, and shared protocol models that mirror the Android `shared-contracts` module.

## What works now

- Spotify Web API OAuth PKCE login with currently-playing polling.
- Manual track lookup by title, artist, album, and optional duration.
- Lyrics provider chain: `Musixmatch -> Netease -> LRCLIB`.
- Local timeline controls for play, pause, restart, and scrub.
- Swift models for the Android wire protocol (`snapshot`, `sync`, status, hello/ack).
- GitHub Actions unsigned, resignable, and optional signed IPA artifacts.

## iOS constraint

iOS does not expose a system-wide media-session listener like Android notification access. Spotify support therefore uses Spotify's Web API after the user connects a Spotify account. This works for private/beta use, but Spotify Development Mode is limited to allowlisted users.

## Spotify setup

In the Spotify Developer Dashboard, add this redirect URI to your app:

```text
rokidlyrics://spotify-callback
```

Paste the Spotify Client ID into the app, then tap Connect. No client secret is used in the iOS app.

## Build

The workflow builds on `macos-15` with XcodeGen:

```bash
xcodegen generate
xcodebuild -project RokidLyricsIOS.xcodeproj -scheme RokidLyricsIOS -configuration Release -sdk iphoneos -destination generic/platform=iOS CODE_SIGNING_ALLOWED=NO build
```

From Windows, `builder-windows-amd64.exe` can trigger GitHub Actions:

```powershell
.\builder-windows-amd64.exe ios build --unsigned
```

## Signing

Local signing files are intentionally ignored by Git:

- `.signing/`
- `Developer/`
- `Distribution/`
- `*.p12`
- `*.mobileprovision`
- `builder*.exe`

Use `scripts/Set-GitHubSigningSecrets.ps1` to upload signing material into GitHub Secrets for this repo.

The workflow also accepts the secret names created by `builder signing setup`, but a `BUNDLE_ID` secret is still required so the generated Xcode project matches the provisioning profile.
