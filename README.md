# Rokid Lyrics iOS

Native iOS companion for Rokid Lyrics.

This repository is intentionally set up for GitHub Actions IPA builds. The iOS version is a SwiftUI companion with Spotify currently-playing lookup, local synced playback preview, and shared protocol models that mirror the Android `shared-contracts` module.

## Screenshots

Redacted simulator captures. The displayed client ID, track ID, email, and provider credentials are placeholders.

| Runtime | Settings | Providers |
| --- | --- | --- |
| <img src="Docs/Images/readme-dashboard.png" alt="Rokid Lyrics runtime dashboard" width="260"> | <img src="Docs/Images/readme-settings-api.png" alt="Rokid Lyrics API settings with redacted values" width="260"> | <img src="Docs/Images/readme-settings-providers.png" alt="Rokid Lyrics provider settings with redacted values" width="260"> |

## What works now

- Spotify Web API OAuth PKCE login with currently-playing polling.
- Manual track lookup by title, artist, album, and optional duration.
- Lyrics provider chain for Spotify tracks: `Spotify color-lyrics -> LRCLIB -> Netease -> Musixmatch`.
- Manual title/artist lookup still uses `LRCLIB -> Netease -> Musixmatch`.
- Local timeline controls for play, pause, restart, and scrub.
- Swift models for the Android wire protocol (`snapshot`, `sync`, status, hello/ack).
- Rokid CXR-L client integration via CocoaPods `RGCxrClient`.
- GitHub Actions unsigned, resignable, and optional signed IPA artifacts.

## iOS constraint

iOS does not expose a system-wide media-session listener like Android notification access. Spotify support therefore uses Spotify's Web API after the user connects a Spotify account. This works for private/beta use, but Spotify Development Mode is limited to allowlisted users.

## Spotify setup

In the Spotify Developer Dashboard, add this redirect URI to your app:

```text
rokidlyrics://spotify-callback
```

Paste the Spotify Client ID into the app, then tap Connect. No client secret is used in the iOS app.

## Spotify lyrics source

The app has a separate `SPOTIFY LYRICS` panel for synced lyrics. The normal flow uses the existing Spotify Web API integration: connect Spotify, keep `MONITOR` enabled, and let the app read the currently playing track automatically. When the Spotify track changes, the current track ID from the now-playing payload is passed into the lyrics provider chain without requiring a manual fetch. `REFETCH CURRENT SPOTIFY` and the URL/ID field are manual debug/override paths.

Modes:

- `Backend`: recommended for prototypes. Run a private backend at the configured base URL. The app calls `GET {baseURL}/{trackId}` and expects either Spotify's raw `color-lyrics/v2` JSON or a wrapper with `lyrics.syncType` and `lyrics.lines`. The backend owns `sp_dc`, refreshes the bearer token through `https://open.spotify.com/api/token`, and calls `https://spclient.wg.spotify.com/color-lyrics/v2/track/{trackId}?format=json&market=from_token`.
- `Direct`: full local iOS mode. Paste your own `sp_dc` into the secure field. The value is stored in iOS Keychain only, then used to fetch a short-lived bearer token and Spotify color-lyrics JSON directly from the app. The Spotify OAuth login does not expose `sp_dc`; it is only used for currently-playing metadata.

Safety rules:

- Never hardcode `sp_dc`.
- Never commit `sp_dc`, bearer tokens, cookies, or request headers.
- Do not log secrets. The app logs only HTTP status, content type, `syncType`, token length, and line count.
- Do not extract `sp_dc` from Spotify iOS, jailbreak, MITM, or sandbox bypasses. The user must provide their own cookie explicitly.
- Spotify `spclient` and `color-lyrics` are internal APIs. They can change without notice and their use may violate Spotify terms, so keep this path private/prototype-only.

The current Rokid iOS SDK exposed by `RGCxrClient` provides `openCustomView/updateCustomView` and `sendCustomCmd`, but no dedicated subtitle API. This prototype keeps the existing custom-app helper path: iOS sends lyric snapshots/windows/sync over CXR-L custom commands or BLE, and the glasses helper owns text layout.

## Build

The project uses XcodeGen plus CocoaPods:

```bash
xcodegen generate
pod install
open RokidLyricsIOS.xcworkspace
```

The workflow builds on `macos-15` with XcodeGen:

```bash
xcodegen generate
pod install
xcodebuild -workspace RokidLyricsIOS.xcworkspace -scheme RokidLyricsIOS -configuration Release -sdk iphoneos -destination generic/platform=iOS CODE_SIGNING_ALLOWED=NO build
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
