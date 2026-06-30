# Optimization: Archive Closed Plan Packets

## Issue
`plan/index.yaml` grew to almost 8000 lines, with over 130 closed packets. 
This was slowing down the advance-work loop, inflating merge diffs, and polluting agent context.

## Solution
Created a Ruby script `scripts/archive-plan-packets.rb` and bash wrapper `scripts/archive-plan-packets.sh` that moves `status: completed|done|obsoleted` packets out of the active index.
- Packets are partitioned by month into `plan/archive/packets-YYYY-MM.yaml` based on completion date.
- The script uses exact `packet_id` regex boundaries to cleanly extract packets without losing their YAML structure.
- `--check` flag ensures idempotency, running safely on PRs.

## Validation
- `tillandsias-policy validate-yaml` cleanly parses `plan/index.yaml` and all `plan/archive/packets-*.yaml`.
- `plan/index.yaml` is now reduced to ~450 lines.
