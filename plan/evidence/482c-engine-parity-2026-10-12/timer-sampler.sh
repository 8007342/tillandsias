#!/usr/bin/env bash
# Read-only: while run 5 runs, sample user systemd units named for a container id
# and report any that do not belong to an operator container (= a scratch healthcheck timer).
D=/tmp/claude-1000/-var-home-lenovinha-claudia-tillandsias/fa3e1fe9-5776-4474-8079-5af7f1b35379/scratchpad/482c
podman ps -a -q --no-trunc > "$D/op-ids.txt"
samples=0; foreign=0
until grep -q '^verdicts:' "$D/run5.out" 2>/dev/null; do
  systemctl --user list-units --all --no-legend --plain > "$D/units.now" 2>/dev/null
  while read -r unit _; do
    id="${unit%%.*}"; id="${id%%-*}"
    [[ "$id" =~ ^[0-9a-f]{64}$ ]] || continue
    grep -q "^$id\$" "$D/op-ids.txt" || { foreign=$((foreign+1)); echo "foreign unit: $unit" >> "$D/timer-sampler.log"; }
  done < "$D/units.now"
  samples=$((samples+1)); sleep 3
done
echo "samples=$samples foreign_healthcheck_units=$foreign operator_ids=$(wc -l < "$D/op-ids.txt")" >> "$D/timer-sampler.log"
