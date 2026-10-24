# Tasks — local-coding-experts-delegation-ladder

Packet orders are in brackets. The parent story is 1831-74sf. Each task closes on the fixture named in its packet; write the fixture first and show it failing on today's code.

## 1. Tier

- [ ] 1.1 Add `local` to the implementer_tier vocabulary, the methodology routing rule and the selector, with the haiku fallback [1832-5a9z]

## 2. Bench (can run alongside 1)

- [ ] 2.1 Tool-call round-trip arm in bench-inference-floor.sh [1835-v7vx]
- [ ] 2.2 Replay set of 20 landed size:S packets, plus verify-set.sh [1835-v7vx]
- [ ] 2.3 Results for Qwen3-Coder-30B-A3B Q5 on macuahuitl and Devstral Small 2 on a Mac, each recorded with its regime [1835-v7vx]

## 3. Delegate

- [ ] 3.1 `scripts/local-delegate.sh` (no jq, no python, no commit):
  - bounded tool loop
  - edits limited to owned_files, enforced by a diff check
  - closure run once at the end
  - one verdict line

  [1833-ytbe]

## 4. Ledger and ladder

- [ ] 4.1 `delegate-outcome.sh local-record` token, and `local-delegate-ladder.sh` rung arithmetic [1834-ujsf]
- [ ] 4.2 Re-tag the qualifying haiku rows as `local` with set-field fragments [1836-pfh4]

## 5. Close

- [ ] 5.1 R1 or better for at least one model over at least 20 replay outcomes, recorded on 1831-74sf
- [ ] 5.2 (deferred) SFT/QLoRA, only if R3 stalls below 80% [1837-t4ry]
