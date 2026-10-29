#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
case "${AUDIO_VARIANT:?}" in legacy|duplex) ;; *) exit 2;; esac
source_app="build/DerivedData-$AUDIO_VARIANT/Build/Products/Release-iphoneos/RokidLyricsIOS.app"
package_root="build/ipa-$AUDIO_VARIANT"
test -d "$source_app"
test ! -e "$package_root"
mkdir -p "$package_root/Payload"
cp -R "$source_app" "$package_root/Payload/"
app="$package_root/Payload/RokidLyricsIOS.app"
plist="$app/Info.plist"
test "$(/usr/libexec/PlistBuddy -c 'Print CFBundleIdentifier' "$plist")" = com.anezium.rokidlyrics
/usr/libexec/PlistBuddy -c 'Set :CFBundleVersion 1029' "$plist"
/usr/libexec/PlistBuddy -c "Add :TottiPreflightCommit string $GITHUB_SHA" "$plist"
/usr/libexec/PlistBuddy -c "Add :TottiAudioVariant string $AUDIO_VARIANT" "$plist"
if [ -d "$app/Frameworks" ]; then
  find "$app/Frameworks" -depth \( -name '*.framework' -o -name '*.dylib' \) -print0 |
    while IFS= read -r -d '' framework; do
      codesign --force --sign - --timestamp=none "$framework"
    done
fi
codesign --force --sign - --timestamp=none "$app"
codesign --verify --deep --strict --verbose=2 "$app"
output="Totti-preflight-$AUDIO_VARIANT-resignable.ipa"
(cd "$package_root" && zip -qry "../$output" Payload)
export TOTTI_IPA_PATH="build/$output"
python3 - <<'PY'
import hashlib, json, os, plistlib, zipfile
path = os.environ['TOTTI_IPA_PATH']
with zipfile.ZipFile(path) as z:
    assert z.testzip() is None
    p = plistlib.loads(z.read('Payload/RokidLyricsIOS.app/Info.plist'))
    assert p['CFBundleIdentifier'] == 'com.anezium.rokidlyrics'
    assert p['CFBundleVersion'] == '1029'
    assert p['TottiPreflightCommit'] == os.environ['GITHUB_SHA']
    assert p['TottiAudioVariant'] == os.environ['AUDIO_VARIANT']
with open(path, 'rb') as f:
    sha = hashlib.file_digest(f, 'sha256').hexdigest()
record = dict(file=os.path.basename(path), sha256=sha, bytes=os.path.getsize(path),
              sourceCommit=os.environ['GITHUB_SHA'], audioVariant=p['TottiAudioVariant'],
              bundleID=p['CFBundleIdentifier'], build=p['CFBundleVersion'],
              signing='ad-hoc only; owner re-signing required', installed=False,
              hfpTested=False, acousticAECTested=False, hudSynchronized=False)
with open(path + '.json', 'w') as f:
    json.dump(record, f, indent=2)
print(json.dumps(record, indent=2))
PY
