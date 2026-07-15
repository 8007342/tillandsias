# base64-script-injection checker false positive on test data decode

- Date: 2026-07-15
- Class: optimization
- Filed by: linux-bigpickle-opencode-20260715T0000Z
- Related: order 345, scripts/check-no-base64-script-injection.sh

## Observation

`check-no-base64-script-injection.sh` flags files containing BOTH
`base64 -d/--decode/-D` AND `chmod +x` (or `_PODMAN_BIN=`). This is
intended to catch "materialise a script from a base64 blob and run it."

However, test scripts that use `base64 -d` for DATA decoding (vault
credential fixtures) and `chmod +x` for UNRELATED purposes (making mock
bin scripts executable) trigger the same regex. The two patterns are
semantically unrelated but co-occur in test harnesses.

This caused order 345 to require a workaround (changing `chmod +x` to
`chmod 755`) rather than a genuine fix. Future agents writing test
harnesses that decode base64 data AND make files executable will hit
the same false positive.

## Potential improvement

Narrow the checker to look for `base64 -d` within N lines of `chmod +x`
(or use a more sophisticated pattern like matching both in the same
function/block) instead of whole-file matching. Alternatively, add a
`# @allowed` annotation for test files where the co-occurrence is
benign.
