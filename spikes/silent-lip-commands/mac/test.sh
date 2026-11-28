#!/bin/bash
# One-shot silent-speech signal test on this Mac.
#   ./test.sh [word ...]        default: stop cancel play replay
# Builds LipCapture, records 10 hands-free takes per word (spoken cues, mouth the
# word silently after "3, 2, 1"), then runs the leave-one-out + permutation test.
set -euo pipefail
cd "$(dirname "$0")"
WORDS=("$@"); [ ${#WORDS[@]} -eq 0 ] && WORDS=(stop cancel play replay)
TAKES=${TAKES:-10}
export LIPSPIKE_DATASET=${LIPSPIKE_DATASET:-$HOME/.lipspike/dataset-$(date +%Y%m%d-%H%M).json}

swift build -c release 2>&1 | tail -3
BIN=.build/release/LipCapture
echo "camera:"; $BIN --list-devices
echo "dataset: $LIPSPIKE_DATASET"
echo "Face the camera, good light, arm's length. Mouth each word SILENTLY after the 3-2-1 cue."
for w in "${WORDS[@]}"; do
  $BIN record --label "$w" --takes "$TAKES" --seconds 1.5 --countdown
done
echo; echo "==== evaluate"; $BIN evaluate --perms 500 | tee "$LIPSPIKE_DATASET.eval.txt"
echo; echo "Results saved next to the dataset. Paste the evaluate block back into the session."
