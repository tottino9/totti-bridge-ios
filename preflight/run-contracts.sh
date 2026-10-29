#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
variant="${AUDIO_VARIANT:?AUDIO_VARIANT must be legacy or duplex}"
flags=(-D TOTTI_CONTRACT_TEST)
case "$variant" in
 legacy) ;;
 duplex) flags+=(-D TOTTI_EXPERIMENTAL_DUPLEX) ;;
 *) echo 'Unknown audio variant' >&2; exit 2 ;;
esac
mkdir -p "build/contracts-$variant"
for name in History Vision HFP Duplex Delivery AudioGate; do
 case "$name" in
  History|Vision) files=(RokidLyricsIOS/TottiIntegration.swift RokidLyricsIOS/TottiVisionPolicy.swift);;
  HFP) files=(RokidLyricsIOS/TottiPCMBuffer.swift RokidLyricsIOS/TottiHFPInputPolicy.swift);;
  Duplex) files=(RokidLyricsIOS/TottiPCMBuffer.swift RokidLyricsIOS/TottiDuplexPolicy.swift RokidLyricsIOS/TottiDeliveryPolicy.swift RokidLyricsIOS/TottiWireCodec.swift scripts/TottiLegacySegmenterForChecks.swift);;
  Delivery) files=(RokidLyricsIOS/TottiDeliveryPolicy.swift);;
  AudioGate) files=(RokidLyricsIOS/TottiAudioGate.swift);;
 esac
 output="build/contracts-$variant/$name"
 swiftc "${flags[@]}" -parse-as-library "${files[@]}" "scripts/Totti${name}Checks.swift" -o "$output" > "$output-build.txt" 2>&1
 "$output" > "$output-results.txt" 2>&1
 printf 'PASS contract executable: %s (%s)\n' "$name" "$variant"
done
