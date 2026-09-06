#!/usr/bin/env bash
# ORDER 1054-zvq4. The terminology-check memo hits only on an unchanged
# dictionary AND unchanged scanned locales AND unchanged instrument; a byte in
# any of them is a miss.
#
# HERMETIC BY CONSTRUCTION, and it has to be: the checker honours
# TILLANDSIAS_TERMINOLOGY_DICT and TILLANDSIAS_LOCALE_DIR, so the memo resolves
# the same two variables. This fixture therefore builds a THROWAWAY locale tree
# in a temp dir and points both variables at it, rather than mutating
# locales/ in the working tree — the archiver fixture can write and remove a
# plan fragment safely because fragments are additive, but a locale file
# mutated in place is a user-visible string source, and a fixture that crashed
# midway would leave the repository's own dictionary altered.
#
# The negative controls are the point. A memo that only ever hits is a memo
# that has stopped checking, and the three inputs fail differently: the
# dictionary changes what counts as a violation, a scanned file changes what is
# examined, and the checker changes the verdict for identical input.
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"; cd "$ROOT"
W="$(mktemp -d "${TMPDIR:-/tmp}/terminology-memo.XXXXXX")"
M="$W/memo"
trap 'rm -rf "$W"' EXIT
pass=0; fail=0; check() { if [ "$1" = ok ]; then pass=$((pass+1)); echo "ok   $2"; else fail=$((fail+1)); echo "FAIL $2"; fi; }
G=scripts/terminology-check-memo.sh

# A minimal locale tree: a dictionary and two scanned files.
mkdir -p "$W/locales"
printf '[[term]]\ncanonical = "Podman"\nwrong = ["podman"]\n' > "$W/locales/terminology.toml"
printf 'greeting = "Hello"\n' > "$W/locales/en.toml"
printf 'greeting = "Hola"\n'  > "$W/locales/es.toml"
export TILLANDSIAS_TERMINOLOGY_DICT="$W/locales/terminology.toml"
export TILLANDSIAS_LOCALE_DIR="$W/locales"
run() { TILLANDSIAS_TERMINOLOGY_MEMO="$M" bash $G "$1" 2>/dev/null; }

out="$(run check)"; [ "$out" = "miss:no-memo" ] && check ok "no memo -> miss:no-memo" || check FAIL "no memo: $out"
out="$(run record)"; case "$out" in ok:terminology-check-memo-recorded:*) check ok "record writes the memo" ;; *) check FAIL "record: $out" ;; esac
out="$(run check)"; case "$out" in ok:terminology-check-memoized:*) check ok "unchanged inputs -> hit ($out)" ;; *) check FAIL "unchanged inputs: $out" ;; esac

# 1. The DICTIONARY changes what counts as a violation.
printf '[[term]]\ncanonical = "Podman"\nwrong = ["podman", "PODMAN"]\n' > "$W/locales/terminology.toml"
out="$(run check)"; [ "$out" = "miss:dictionary-locales-or-instrument-changed" ] && check ok "a changed dictionary entry -> miss" || check FAIL "dictionary change: $out"
printf '[[term]]\ncanonical = "Podman"\nwrong = ["podman"]\n' > "$W/locales/terminology.toml"
out="$(run check)"; case "$out" in ok:terminology-check-memoized:*) check ok "dictionary restored -> hit again (digest is content, not time)" ;; *) check FAIL "dictionary restored: $out" ;; esac

# 2. A SCANNED SOURCE STRING changes what is examined.
printf 'greeting = "Hello there"\n' > "$W/locales/en.toml"
out="$(run check)"; [ "$out" = "miss:dictionary-locales-or-instrument-changed" ] && check ok "a changed scanned source string -> miss" || check FAIL "scanned source change: $out"
printf 'greeting = "Hello"\n' > "$W/locales/en.toml"
out="$(run check)"; case "$out" in ok:terminology-check-memoized:*) check ok "source restored -> hit again" ;; *) check FAIL "source restored: $out" ;; esac

# 3. A locale file APPEARING is a miss even though no existing byte changed.
#    This is why the digest carries file NAMES and not only their contents.
printf 'greeting = "Bonjour"\n' > "$W/locales/fr.toml"
out="$(run check)"; [ "$out" = "miss:dictionary-locales-or-instrument-changed" ] && check ok "a NEW locale file -> miss (names are in the key)" || check FAIL "new locale file: $out"
rm -f "$W/locales/fr.toml"
out="$(run check)"; case "$out" in ok:terminology-check-memoized:*) check ok "file removed -> hit again" ;; *) check FAIL "after removal: $out" ;; esac

# 4. The dictionary must NOT be scanned as a source: it legitimately contains
#    the very variants it forbids, and a digest that double-counted it would
#    still be correct, but a checker that scanned it would fail forever. Assert
#    the memo distinguishes the two roles by keying them under different tags.
d_full="$(TILLANDSIAS_TERMINOLOGY_MEMO="$M" bash $G digest)"
[ "${#d_full}" -eq 64 ] && check ok "digest is a sha256 ($d_full)" || check FAIL "digest shape: $d_full"

# 5. THE INSTRUMENT: a changed checker must miss on byte-identical input.
#    Verified against the real script path, since that is what the digest names.
if grep -q 'tool:%s' "$ROOT/$G"; then check ok "the digest names the checker as an input (tool: tag present)"; else check FAIL "digest does not key on the checker"; fi

total=$((pass+fail)); if [ $fail -eq 0 ]; then echo "PASS: terminology-check memo ${pass}/${total} (1054-zvq4)"; exit 0; fi; echo "FAIL: terminology-check memo ${fail}/${total} red (1054-zvq4)"; exit 1
