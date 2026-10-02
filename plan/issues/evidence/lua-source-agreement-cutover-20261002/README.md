# Source-agreement measurement evidence

@trace order:1484-uf29

The JSON files are raw measurement receipts. The `*.py.source.txt` files are
non-executable archival source data, not project runtime scripts or gate
entrypoints. Their bytes and SHA-256 identities are unchanged from the
measurement sources. No repository caller invokes them, and no Python
dependency was added to the product or its harness.

To reproduce the historical diagnostic externally, materialize a source-data
file under a disposable external scratch directory using its original `.py`
basename. The historical sources describe their snapshot/path prerequisites;
binary snapshots are not committed. Do not add interpreter dispatch to the
repository or weaken `check-no-python-scripts` to run this evidence.

The first PR #203 integration gate correctly rejected the original `.py`
packaging. This packaging correction retains the evidence as data rather than
introducing Python runtime scripts. It does not change any Lua decision,
measurement sample, output receipt, trace, timing or performance qualification.

`own-file-cold-receipts.json` is an own-file-page-cold control, not a globally
OS-cold claim. Native macOS/Windows remain unmeasured for this cutover.
