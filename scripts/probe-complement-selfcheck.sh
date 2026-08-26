#!/usr/bin/env bash
# 853-6gz3 complement self-check, FIVE pairs instead of one.
#
# My earlier claim — "the bare two-framing complement is degenerate at every
# size" — rested on ONE passage/question pair. Having just retracted a different
# over-read from two data points, that is not good enough. Five pairs, each with
# a passage that DOES answer and one that does NOT, both framings, same model
# ladder. A SOUND judge answers YES/NO on the answering passage and NO/YES on
# the non-answering one; anything else is a self-contradiction.
set -uo pipefail

# ORDER 799-tb7q — resolve `jq` through the shared host-preferred /
# toolbox-fallback dispatch instead of assuming the host has it.
# shellcheck source=scripts/lib/tool-dispatch.sh
# Resolve the lib by WALKING UP, not by a fixed depth (order 914-ahsy). The
# fixed form `dirname "${BASH_SOURCE[0]}"/lib/...` is correct only for a caller
# sitting directly in scripts/. From scripts/refusal-calibration/ it points at a
# lib that does not exist, the `|| true` swallows the miss, and the tool variable
# silently falls back to the bare name — a conversion that passes review, passes
# the suite, and changes nothing.
_td_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" 2>/dev/null && pwd)"
while [ -n "$_td_dir" ] && [ "$_td_dir" != "/" ] && [ ! -f "$_td_dir/lib/tool-dispatch.sh" ]; do
    _td_dir="$(dirname "$_td_dir")"
done
if [ -f "$_td_dir/lib/tool-dispatch.sh" ]; then
    . "$_td_dir/lib/tool-dispatch.sh" 2>/dev/null || true
fi
if command -v resolve_tool >/dev/null 2>&1; then
    JQ="$(resolve_tool jq || printf 'jq')"
else
    JQ="jq"   # lib unavailable: preserve the previous behaviour exactly
fi

EP=http://127.0.0.1:11434
M="${1:?usage: complement-probe.sh <model>}"

ask() { # $1 passage  $2 framing
  curl -fsS --max-time 900 "$EP/api/generate" -H 'Content-Type: application/json' \
    -d "$("$JQ" -Rn --arg m "$M" --arg p "Passage:
$1

Question: $2 Answer with exactly one word, YES or NO." '{model:$m,prompt:$p,stream:false,options:{num_predict:6,temperature:0}}')" \
  | "$JQ" -r '.response' | tr -d '\n' | grep -oiE 'yes|no' | head -1 | tr '[:lower:]' '[:upper:]'
}

Q1="which branch does macOS checkpoint to"
A1="Linux checkpoints to linux-next. Windows checkpoints to windows-next. macOS checkpoints to osx-next."
Q2="what is the default build timeout in seconds"
A2="TILLANDSIAS_BUILD_TIMEOUT_SECS bounds each podman build and defaults to 1800 seconds."
Q3="how many cores does the N150 have"
A3="The Intel N150 has 4 Alder Lake-N cores with no SMT and a 3.6 GHz maximum turbo."
Q4="what does the stable channel URL resolve to"
A4="The README install URLs use /releases/latest/download, which resolves to the newest non-prerelease."
Q5="which file records the active release"
A5="The active release is named by the ## ACTIVE RELEASE heading in plan/loop_status.md."

N1="Flexbox aligns items along a main axis. justify-content controls spacing between them."
N2="A binary search halves the interval each step, so lookup is logarithmic in the array length."
N3="Sourdough starter is flour and water colonised by wild yeast; feed it daily at room temperature."
N4="The mitochondrion generates ATP through oxidative phosphorylation across the inner membrane."
N5="In chess, a knight moves in an L: two squares along one axis and one along the other."

printf 'model=%s\n' "$M"
printf '%-4s %-26s %-7s %-7s %s\n' PAIR PASSAGE ANSWERS? MISSING? VERDICT
sound=0; contra=0; wrong=0
for i in 1 2 3 4 5; do
  eval "Q=\$Q$i; A=\$A$i; N=\$N$i"
  # the passage that DOES answer: sound judge says YES / NO
  a=$(ask "$A" "does the passage answer '$Q'?"); b=$(ask "$A" "is the passage MISSING the answer to '$Q'?")
  if [ "$a" = "$b" ]; then v="CONTRADICTION"; contra=$((contra+1))
  elif [ "$a" = "YES" ] && [ "$b" = "NO" ]; then v="sound"; sound=$((sound+1))
  else v="inverted"; wrong=$((wrong+1)); fi
  printf '%-4s %-26s %-7s %-7s %s\n' "$i" "DOES answer" "$a" "$b" "$v"
  # the passage that does NOT: sound judge says NO / YES
  a=$(ask "$N" "does the passage answer '$Q'?"); b=$(ask "$N" "is the passage MISSING the answer to '$Q'?")
  if [ "$a" = "$b" ]; then v="CONTRADICTION"; contra=$((contra+1))
  elif [ "$a" = "NO" ] && [ "$b" = "YES" ]; then v="sound"; sound=$((sound+1))
  else v="inverted"; wrong=$((wrong+1)); fi
  printf '%-4s %-26s %-7s %-7s %s\n' "$i" "does NOT answer" "$a" "$b" "$v"
done
printf '\n%s: sound=%s contradiction=%s inverted=%s (of 10)\n' "$M" "$sound" "$contra" "$wrong"
echo "PROBE-COMPLETE"
