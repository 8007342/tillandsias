# osx-next work queue — 2026-08

One-line outcome rows per cycle (mirrors linux-next-work-queue-2026-05-25.md).
This host is the fleet's only macOS builder.

## Cycle rows

- 2026-08-09T23:25Z  e4792602  606-r42f dead VzLifecycle removed; cold-provision smoke PASS; pins added (Direction: v0.5 readiness under the EXPERTS milestone cycle)
- 2026-08-09T23:25Z  052d3a19  421 Gatekeeper hint quarantine-gated; spec delta amended; litmus pin added
- 2026-08-09T23:25Z  11c509d2  627-53gu batch selector runs on macOS at last (bash-3.2 argv guard, yq→jq, BSD-awk stream); 627-cx24 filed (priority projection gap, linux)
- 2026-08-09T23:25Z  7be4465d  492 PTY bootstrap slave dropped at split(); Darwin probe PINNED (termios resets on last-slave-close — retention was load-bearing); EOF→PtyClose wired; attach client re-raws
- 2026-08-09T23:25Z  493c21b8  628-yd8f --capabilities singleton-killed the live vsock server; one-line is_cli_mode fix + pin; verified live; probable killer of the 08-03 order-76 build
- 2026-08-09T23:25Z  3a8130b6  merge-surfaced cfg(macos) test conflict fixed (order-155 slice-2 test vs M5 loaded-flag semantics)
- 2026-08-09T23:25Z  (frag)    598-kibt: M1/M2/M4/M6 GREEN (M6 first-ever live macOS run of the b13151a1 write path: floods clean, byte-identical input, wedge kill-not-drop 143/15), M3 partial, M5 operator-gated; all six v0.4.260809.2 images built in-guest
- 2026-08-09T23:25Z  (frag)    624-q4jj: ALL FIVE STEPS PASS — order-455 macOS smoke for v0.4.260809.2 explicitly discharged; 635-bhkb filed (tray crate version never synced)
- 2026-08-09T23:25Z  (frag)    635-kagg filed: --bash forge lane wedges over exec wire post-vault (3 reproductions, absorbs SIGTERM) — blocks M3 in-container check, 349 closing run, 401 in-lane measurements
- 2026-08-09T23:25Z  (frag)    349 blocked on 635-kagg (criteria 1+2 still PASS from 07-16); 401 progress: tier:cpu verdict VERIFIED live (exit criterion 1)
- 2026-08-10T05:06Z  (frag)    644-7w89 v0.4.260810.1 curl smoke 5/5 PASS — no regressions vs .2; 421 over-warn GONE in published installer; 635-kagg narrowed (tray lane works, exec-wire-context-specific)
- 2026-08-10T06:12Z  cee23fb9  635-kagg ROOT CAUSE FIXED: podman exec -i + null stdin wedged conmon attach; six launcher execs de-i'd, pin added; bring-up now ~20s + fail-loud; remaining: foreground run -i attach over exec-wire PTY
- 2026-08-10T07:08Z  (frag)    tri-slice: 598-kibt M3 CLOSED (envelope byte-identity PASS via Config.Env); 349 token ABSENT -> blocked-on-operator --github-login; 401 OLLAMA ALIVE (0.32.6 self-install succeeded with egress up)
- 2026-08-10T08:15Z  (frag)    401 COMPLETED: cpu-ollama measured (52 tok/s warm; qwen2.5:0.5b), Modelfile expert built+answered via /api/create, tier:cpu verdict — lane decision cpu-ollama; llama.cpp gap pinned on 482b
- 2026-08-10T08:55Z  (frag)    648-dvzd ask#3 ANSWERED: 606-9wqd runtime repro CONCLUSIVE on this guest (controls 200; mirror dual-home = unrestricted internet; enclave isolation airtight) — unblocks 451 release-blocker-v0.5
- 2026-08-10T19:20Z  (frag)    657-* filed: five Apple Silicon experts packets (Metal sidecar flagship 657-s6g8, i8mm guest unlock 657-3mq5, aarch64 llama-server variant, VZ resource policy, accel-probe truthfulness) — grounded in 3-scout research + 401 baseline
- 2026-08-10T20:35Z  (frag)    663-acdw filed (github-login guest preflight wedge — blocks unattended re-seed + 349) + 663-69kp (unbounded one-shot boot hang after interrupted teardown); both hit repeatedly tonight
- 2026-08-10T22:20Z  (frag)    657-3mq5 slice 1: guest has i8mm+SME2 (M4-class); native llama.cpp build (65s) benches 190 tok/s tg / 1194 t/s pp on qwen0.5b Q4_0 — ~3.65x the ollama baseline
- 2026-08-10T23:50Z  (frag)    657-3mq5 slice 2: quant matrix — Q4_0 repack dominates (1220 pp / 187 tg vs Q4_K_M 355/151); lane guidance = Q4_0 for experts
- 2026-08-11T01:00Z  (frag)    657-3mq5 COMPLETED: recipe = native GGML_NATIVE build + Q4_0 repack -> 2.6x ollama decode (187 vs 71 tok/s), engine gap 2.1x isolated; ollama pinned 0.32.6
- 2026-08-11T02:15Z  (frag)    663-69kp signature refined: rapid sequential boots alone trigger the pre-breadcrumb hang (health-boot pattern indicted); loop switches to one-boot-per-iteration
- 2026-08-11T02:45Z  (frag)    663-69kp datum #4 (hang 15s after clean tray quit); 598-kibt next_action corrected (only M5 runtime remains, operator-gated)
- 2026-08-11T03:55Z  (frag)    663-69kp paired datum: success-in-45s then immediate-next hang 400s; console silent while rootfs.img mtime advances during hangs; 663-acdw parked (6 attempts)
- 2026-08-11T07:35Z  (frag)    245 revision slice DONE: 23/23 stale claims corrected in the NA audit doc (7-agent fact-check); re-verification by the 3 named agents remains the gate. Also repaired stranded 606-r42f/421 completions
