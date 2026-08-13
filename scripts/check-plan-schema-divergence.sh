#!/bin/sh
# Plan/schema status vocabulary divergence check (order 440).
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

set -eu

INDEX="plan/index.yaml"
SCHEMA="plan/schema.yaml"

if [ ! -f "$INDEX" ] || [ ! -f "$SCHEMA" ]; then
  echo "blocked:status-vocab-diverges: could not read $INDEX or $SCHEMA"
  exit 1
fi

# Rewritten from python3 (tlatoani_hard_no_python). Ruby is the methodology's
# sanctioned YAML fallback and this script runs HOST-side, where ruby exists.
ruby -ryaml -e '
  def load_or_report(path)
    YAML.load_file(path)
  rescue => e
    # One line, first line of the parser message only: a 20-line Psych backtrace
    # buries the verdict the caller greps for.
    puts "blocked:index-load-failed: #{path}: #{e.message.to_s.lines.first.to_s.strip}"
    exit 1
  end
  idx = load_or_report(ARGV[0])
  sch = load_or_report(ARGV[1])
  idx_list = (idx["plan_index"] || {})["default_status_values"] || []
  sch_list = sch["statuses"] || []
  if idx_list != sch_list
    puts "blocked:status-vocab-diverges: plan/index.yaml=(#{idx_list.join(" ")}) vs plan/schema.yaml=(#{sch_list.join(" ")})"
    exit 1
  end
  puts "ok:status-vocab-in-sync"
' "$INDEX" "$SCHEMA"
