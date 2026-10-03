# 1533-ew3n retroactive parity receipt

The Bash implementations were deleted before the requested capture. This directory
therefore records a **retroactive** comparison pinned to immutable baseline
`8c7af38867886b7144a0c27a33eec2de4451ba46`; it must not be read as a
pre-cutover measurement. `reproduce.sh` materializes the three historical blobs
only below `/tmp/opencode` and never reintroduces a production Bash caller.

Required before landing: execute every guest (3), tray (6), and Podman (6) arm,
plus unreadable/missing, CRLF, and spaces controls; retain each raw `(rc, stdout
bytes, stderr bytes)` pair and enumerate mismatches. No path normalization is
permitted except a separately reported path-role difference.
