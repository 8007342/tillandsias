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
  check-cdi-classification-arms)
    # ORDER 665-zddn. BEHAVIOURAL, not a source-shape grep (634-39ik): run the
    # real classifier against the real measured stderr and require the arms to
    # pass.
    #
    # THE COUNT IS THE POINT. `cargo test -- <filter>` exits 0 when the filter
    # matches NOTHING, so a renamed or deleted test leaves this green while
    # pinning nothing at all — an arm green over an empty selection. Assert how
    # many ran before trusting that they passed.
    out="$(cargo test -q -p tillandsias-podman --lib -- \
             a_stale_nvidia_cdi_spec_is_classified_at_the_oci_runtime_exit_status \
             an_unresolvable_cdi_device_names_both_causes_of_the_identical_message \
             the_stale_driver_version_parser_refuses_rather_than_guesses \
             an_unrecognized_oci_runtime_failure_still_falls_through 2>&1)" || {
      echo "FAIL: CDI classification arms did not pass"; echo "$out" | tail -20; exit 1; }
    ran="$(printf '%s\n' "$out" | sed -n 's/^test result: ok\. \([0-9]*\) passed.*/\1/p' | head -1)"
    [ -n "$ran" ] || { echo "FAIL: could not read a test-result count"; echo "$out" | tail -20; exit 1; }
    [ "$ran" -eq 4 ] || { echo "FAIL: expected 4 CDI classification arms, $ran ran (renamed or deleted?)"; exit 1; }
    echo "ok: cdi-classification-arms:4 passed"
    ;;
  check-launch-breadcrumb-wired)
    # ORDER 665-zddn EC4. The breadcrumb helper is only worth anything if the
    # failure path CALLS it. A helper with no caller is the exact defect this
    # packet's own EC1 arm nearly shipped: code that reads complete and never
    # runs. The unit tests cover the helper's behaviour; this covers the wire.
    awk '/async fn format_observed_launch_failure/{in_fn=1} in_fn&&/write_launch_breadcrumb\(/{found=1; exit} /^    }$/&&in_fn{exit} END{if(found)print "ok: write_launch_breadcrumb called from format_observed_launch_failure"; else{print "FAIL: the launch breadcrumb has no caller in format_observed_launch_failure"; exit 1}}' crates/tillandsias-podman/src/client.rs
    ;;
  help|*)
    echo "Usage: $0 {check-run_opencode_mode-ordering|check-run_observatorium_mode-ordering|check-ensure_enclave_for_project-ordering|check-ensure_enclave_network-present|check-format_observed_launch_failure-classifier|check-cdi-classification-arms|check-launch-breadcrumb-wired}"
    exit 2
    ;;
esac
