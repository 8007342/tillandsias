#!/bin/sh
# @trace spec:git-mirror-service
# @trace order:1310-rec6
#
# healthcheck.sh — the git mirror's container HEALTHCHECK.
#
# WHY NOT `nc -w 1 127.0.0.1 9418`, which is what this replaced. A bare TCP
# probe opens a connection and closes it without a git request, and
# git-daemon (running --verbose) logs `fatal: the remote end hung up
# unexpectedly` for every one. At a 2 s interval that was 23,209 fatal lines
# in one lenovinha container log (2026-09-29), every one of them the
# healthcheck and none of them a relay failure: a healthy mirror's log was
# indistinguishable from a failing one, which is 1310-rec6's first step.
#
# WHY NOT A REAL GIT REQUEST EITHER. Measured in the tillandsias-git image
# against a verbose daemon: `git ls-remote git://127.0.0.1/<repo> HEAD` still
# leaves the fatal on ~1% of runs with protocol v0 and ~3% with v2 (a daemon
# side teardown race), and every run adds a `Connection from` line. Any probe
# that CONNECTS writes to the daemon's log.
#
# So this probe does not connect. It asks the kernel whether a socket is
# LISTENING on the daemon port (/proc/net/tcp and tcp6, state 0A). That is the
# same proof the old `nc` gave (the port answers), it fails the moment the
# daemon dies, and it writes nothing to any log.
PORT_HEX="$(printf '%04X' "${GIT_DAEMON_PORT:-9418}")"
for table in /proc/net/tcp /proc/net/tcp6; do
    [ -r "$table" ] || continue
    # columns: sl local_address rem_address st ...; local_address is IP:PORT in hex
    if awk -v p=":$PORT_HEX" '$4 == "0A" && substr($2, length($2) - 4) == p { found = 1 } END { exit found ? 0 : 1 }' "$table"; then
        exit 0
    fi
done
exit 1
