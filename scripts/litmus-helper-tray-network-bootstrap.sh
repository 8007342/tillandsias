#!/usr/bin/env bash
set -euo pipefail

MODE="${1:-help}"

case "$MODE" in
  check-run_opencode_mode-ordering)
    awk '/^fn run_opencode_mode/{in_fn=1} in_fn&&/ensure_router_running/{er=NR; in_fn=2} in_fn==2&&/run_container_observed/{rc=NR; exit} /^fn /&&in_fn&&!/run_opencode_mode/{exit} END{if(er&&rc&&er<rc)print "ok: ensure_router_running@"er" before run_container_observed@"rc; else{print "FAIL: ensure_router_running missing or after run_container_observed (er="er" rc="rc")"; exit 1}}' crates/tillandsias-headless/src/main.rs
    ;;
  check-run_observatorium_mode-ordering)
    awk '/^fn run_observatorium_mode/{in_fn=1} in_fn&&/ensure_router_running/{er=NR; in_fn=2} in_fn==2&&/run_container_observed/{rc=NR; exit} /^fn /&&in_fn&&!/run_observatorium_mode/{exit} END{if(er&&rc&&er<rc)print "ok: observatorium ensure_router_running@"er" before run_container_observed@"rc; else{print "FAIL: observatorium router-ordering wrong (er="er" rc="rc")"; exit 1}}' crates/tillandsias-headless/src/main.rs
    ;;
  check-ensure_enclave_for_project-ordering)
    awk '/fn ensure_enclave_for_project/{in_fn=1} in_fn&&/ensure_router_running/{er=NR; in_fn=2} in_fn==2&&/run_container_observed/{rc=NR; exit} /^fn /&&in_fn&&!/ensure_enclave_for_project/{exit} END{if(er&&rc&&er<rc)print "ok: ensure_enclave_for_project router@"er" before container@"rc; else{print "FAIL: ensure_enclave_for_project router-ordering wrong (er="er" rc="rc")"; exit 1}}' crates/tillandsias-headless/src/main.rs
    ;;
  check-ensure_enclave_network-present)
    for fn in run_opencode_mode run_observatorium_mode ensure_enclave_for_project; do
      awk -v want="$fn" '$0~"^(pub(\\(crate\\))? )?fn "want"\\(" {in_fn=1} in_fn&&/ensure_enclave_network/{found=1; exit} /^(pub(\\(crate\\))? )?fn /&&in_fn&&$0!~"^(pub(\\(crate\\))? )?fn "want"\\(" {exit} END{if(found)print "ok: "want" ensure_enclave_network present"; else{print "FAIL: "want" missing ensure_enclave_network"; exit 1}}' crates/tillandsias-headless/src/main.rs
    done
    ;;
  check-format_observed_launch_failure-classifier)
    awk '/async fn format_observed_launch_failure/{in_fn=1} in_fn&&/classify_typed_launch_failure/{found=1; exit} /^}$/&&in_fn{exit} END{if(found)print "ok: classify_typed_launch_failure threaded into format_observed_launch_failure"; else{print "FAIL: classify_typed_launch_failure missing from format_observed_launch_failure body"; exit 1}}' crates/tillandsias-podman/src/client.rs
    ;;
  help|*)
    echo "Usage: $0 {check-run_opencode_mode-ordering|check-run_observatorium_mode-ordering|check-ensure_enclave_for_project-ordering|check-ensure_enclave_network-present|check-format_observed_launch_failure-classifier}"
    exit 2
    ;;
esac
