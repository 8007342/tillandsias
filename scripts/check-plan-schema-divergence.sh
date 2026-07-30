#!/bin/sh
# Plan/schema status vocabulary divergence check (order 440).
# Exits 0 if plan/index.yaml default_status_values and plan/schema.yaml statuses
# are identical. Emits a one-line verdict:
#   ok:status-vocab-in-sync
#   blocked:status-vocab-diverges: <details>
# and exits 0 or 1 accordingly.

set -eu

INDEX="plan/index.yaml"
SCHEMA="plan/schema.yaml"

if [ ! -f "$INDEX" ] || [ ! -f "$SCHEMA" ]; then
  echo "blocked:status-vocab-diverges: could not read $INDEX or $SCHEMA"
  exit 1
fi

python3 -c "
import yaml, sys

with open('$INDEX') as f:
    idx = yaml.safe_load(f)
with open('$SCHEMA') as f:
    sch = yaml.safe_load(f)

idx_list = idx.get('plan_index', {}).get('default_status_values', [])
sch_list = sch.get('statuses', [])

if idx_list != sch_list:
    i = ' '.join(idx_list)
    s = ' '.join(sch_list)
    print('blocked:status-vocab-diverges: plan/index.yaml=(' + i + ') vs plan/schema.yaml=(' + s + ')')
    sys.exit(1)

print('ok:status-vocab-in-sync')
sys.exit(0)
"
