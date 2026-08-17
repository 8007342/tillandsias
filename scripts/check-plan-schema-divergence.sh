#!/bin/sh
# @trace order:744-agyy (order 440, order 720-24u6)
# Plan/schema status vocabulary divergence check (order 440, 744-agyy).
# Exits 0 if plan/index.yaml default_status_values and plan/schema.yaml statuses
# are identical. Emits a one-line verdict:
#   ok:status-vocab-in-sync
#   blocked:status-vocab-diverges: <details>
#   blocked:index-load-failed: <file>: <parser message>
# and exits 0 or 1 accordingly.
#
# WHY THE THIRD VERDICT EXISTS (order 720-24u6, 2026-08-13)
# --------------------------------------------------------
# `tillandsias-plan compact` is byte-preserving by design, so it folds fragment
# text into the base verbatim. On 2026-08-13 a fold carried 231 bare-scalar
# timestamps (`ts: 2026-08-12T15:31:54Z`) into plan/index.yaml. Ruby's
# safe_load resolves a bare ISO-8601 scalar to Time, a disallowed class, so
# YAML.load_file raised before either vocabulary was ever read — and this script
# reported `blocked:status-vocab-diverges`, naming a divergence that did not
# exist. The vocabularies were identical; the file would not load.
#
# A failing gate that names the wrong cause is worse than a silent one: it sends
# the reader to diff two lists that already match. Load failure and divergence
# are different facts and now get different verdicts.
#
# ORDER 744-agyy (2026-08-15):
# ----------------------------
# Rewritten from ruby to yq (the forge container has no ruby, but documents yq
# present; python3 is forbidden under tlatoani_hard_no_python).
#
# ORDER 746-* (2026-08-15, same day): THAT REWRITE MOVED THE BREAKAGE, IT DID
# NOT REMOVE IT. Measured across the three environments this gate actually runs
# in:
#
#                     yq        ruby      jq
#   forge             present   ABSENT    present
#   host (Silverblue) ABSENT    ABSENT    present
#   builder toolbox   ABSENT    present   present
#
# Ruby broke the forge. yq then broke the host AND the builder toolbox, where
# `./build.sh --check` runs on every Linux cycle — the pre-push gate started
# refusing with `blocked:index-load-failed: … yq: commande introuvable`, so a
# green tree could not be pushed at all. Neither interpreter is universal, and
# picking one and hoping is what produced two outages in one day.
#
# So: TRY EACH IN TURN, and fail with a verdict that names what is missing
# instead of a parser error that reads like a corrupt ledger. jq is the only
# tool present everywhere but cannot read YAML, so it is not a candidate here —
# a universal reader is the real fix and is filed separately.
set -eu

INDEX="${1:-plan/index.yaml}"
SCHEMA="${2:-plan/schema.yaml}"

if [ ! -f "$INDEX" ] || [ ! -f "$SCHEMA" ]; then
  echo "blocked:status-vocab-diverges: could not read $INDEX or $SCHEMA"
  exit 1
fi

# read_seq <file> <yq-path> <ruby-expr> -> space-joined sequence on stdout.
# Returns non-zero and leaves the reader's message on stdout when the file will
# not load, so the caller can report it verbatim.
read_seq() {
  _rs_file="$1"; _rs_yq="$2"; _rs_rb="$3"
  if command -v yq >/dev/null 2>&1; then
    yq eval "$_rs_yq" "$_rs_file" 2>&1
    return $?
  fi
  if command -v ruby >/dev/null 2>&1; then
    # -rdate: the exprs name Date in permitted_classes. Rubies >= 3.x reach it
    # because psych itself requires date; macOS system ruby (2.6) does not, so
    # without the explicit require the constant is uninitialized and this
    # reader reports index-load-failed on a perfectly loadable index
    # (762-8yna, found blocking the macOS pre-push gate 2026-08-16).
    ruby -ryaml -rdate -e "$_rs_rb" "$_rs_file" 2>&1
    return $?
  fi
  # TOOLBOX TIER (methodology multi_host_development.toolbox_first_scripts,
  # order 777-amku): host tool preferred, toolbox as the fallback. `ruby` is in
  # the tillandsias-builder init set, so a Silverblue host with no host ruby
  # can still read the ledger instead of refusing. This is STRICTLY ADDITIVE —
  # it is reached only where the two tiers above already gave up and the next
  # line was a hard refusal. No `ensure_toolbox.sh` include here on purpose:
  # this script is #!/bin/sh (no BASH_SOURCE), and a check has no business
  # CREATING a toolbox — it uses one that already exists, or it refuses.
  if command -v toolbox >/dev/null 2>&1 &&
     toolbox run --container "${TILLANDSIAS_BUILDER_TOOLBOX:-tillandsias-builder}" \
        true >/dev/null 2>&1; then
    toolbox run --container "${TILLANDSIAS_BUILDER_TOOLBOX:-tillandsias-builder}" \
        ruby -ryaml -rdate -e "$_rs_rb" "$_rs_file" 2>&1
    return $?
  fi
  echo "no YAML reader on PATH (tried yq, ruby, toolbox ruby)"
  return 2
}

# safe_load(File.read(...)) rather than safe_load_file: the latter is psych 4
# (ruby >= 3.1) only, while this form parses identically on every psych >= 3.1
# — macOS system ruby 2.6 included (762-8yna, same gate-blocking incident as
# the -rdate require above).
RB_INDEX='d=YAML.safe_load(File.read(ARGV[0]), permitted_classes: [Time, Date]); puts((d.dig("plan_index","default_status_values") || []).join(" "))'
RB_SCHEMA='d=YAML.safe_load(File.read(ARGV[0]), permitted_classes: [Time, Date]); puts((d["statuses"] || []).join(" "))'

# Load index
if ! idx_raw=$(read_seq "$INDEX" '.plan_index.default_status_values // [] | join(" ")' "$RB_INDEX"); then
  first_err=$(printf '%s\n' "$idx_raw" | head -n 1)
  echo "blocked:index-load-failed: $INDEX: $first_err"
  exit 1
fi

# Load schema
if ! sch_raw=$(read_seq "$SCHEMA" '.statuses // [] | join(" ")' "$RB_SCHEMA"); then
  first_err=$(printf '%s\n' "$sch_raw" | head -n 1)
  echo "blocked:index-load-failed: $SCHEMA: $first_err"
  exit 1
fi

if [ "$idx_raw" != "$sch_raw" ]; then
  echo "blocked:status-vocab-diverges: $INDEX=($idx_raw) vs $SCHEMA=($sch_raw)"
  exit 1
fi

echo "ok:status-vocab-in-sync"
