#!/usr/bin/env bash
# @trace spec:transparent-https-caching
set -euo pipefail

IMAGE="${TILLANDSIAS_FORGE_IMAGE:-localhost/tillandsias-forge:latest}"
podman image exists "$IMAGE" || {
    echo "FAIL: required forge image is absent: $IMAGE" >&2
    exit 1
}

for command in openssl python3 git curl; do
    command -v "$command" >/dev/null || {
        echo "FAIL: required host command is absent: $command" >&2
        exit 1
    }
done

tmp="$(mktemp -d)"
server_pid=""
cleanup() {
    [ -z "$server_pid" ] || kill "$server_pid" 2>/dev/null || true
    [ -z "$server_pid" ] || wait "$server_pid" 2>/dev/null || true
    rm -rf "$tmp"
}
trap cleanup EXIT

openssl req -x509 -newkey rsa:2048 -nodes -days 1 \
    -subj '/CN=Tillandsias Runtime Test CA' \
    -addext 'basicConstraints=critical,CA:TRUE' \
    -addext 'keyUsage=critical,keyCertSign,cRLSign' \
    -keyout "$tmp/ca.key" -out "$tmp/ca.crt" >/dev/null 2>&1
openssl req -newkey rsa:2048 -nodes -subj '/CN=127.0.0.1' \
    -keyout "$tmp/server.key" -out "$tmp/server.csr" >/dev/null 2>&1
printf 'subjectAltName=IP:127.0.0.1\nextendedKeyUsage=serverAuth\nkeyUsage=critical,digitalSignature,keyEncipherment\n' >"$tmp/server.ext"
openssl x509 -req -days 1 -in "$tmp/server.csr" \
    -CA "$tmp/ca.crt" -CAkey "$tmp/ca.key" -CAcreateserial \
    -extfile "$tmp/server.ext" -out "$tmp/server.crt" >/dev/null 2>&1

mkdir -p "$tmp/seed" "$tmp/web"
git -C "$tmp/seed" init --quiet
git -C "$tmp/seed" config user.name Fixture
git -C "$tmp/seed" config user.email fixture@example.test
printf 'runtime trust\n' >"$tmp/seed/README"
git -C "$tmp/seed" add README
git -C "$tmp/seed" commit --quiet -m initial
git clone --quiet --bare "$tmp/seed" "$tmp/web/upstream.git"
git --git-dir="$tmp/web/upstream.git" update-server-info

port="$(python3 -c 'import socket; s=socket.socket(); s.bind(("127.0.0.1", 0)); print(s.getsockname()[1]); s.close()')"
python3 - "$tmp/web" "$tmp/server.crt" "$tmp/server.key" "$port" <<'PY' &
import http.server
import os
import ssl
import sys

root, cert, key, port = sys.argv[1:]
os.chdir(root)
server = http.server.ThreadingHTTPServer(("127.0.0.1", int(port)), http.server.SimpleHTTPRequestHandler)
context = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
context.load_cert_chain(cert, key)
server.socket = context.wrap_socket(server.socket, server_side=True)
server.serve_forever()
PY
server_pid=$!

ready=""
for _ in $(seq 1 40); do
    if curl --noproxy '*' --cacert "$tmp/ca.crt" -fsS \
        "https://127.0.0.1:$port/upstream.git/HEAD" >/dev/null 2>&1; then
        ready=1
        break
    fi
    sleep 0.1
done
[ -n "$ready" ] || {
    echo "FAIL: local TLS fixture did not become ready" >&2
    exit 1
}

podman run --rm \
    --network=host \
    --cap-drop=ALL \
    --security-opt=no-new-privileges \
    --security-opt=label=disable \
    --userns=keep-id \
    --env HTTP_PROXY= --env HTTPS_PROXY= --env ALL_PROXY= \
    --env NO_PROXY=127.0.0.1,localhost \
    --mount "type=bind,source=$tmp/ca.crt,target=/run/tillandsias/ca-chain.crt,readonly=true" \
    --entrypoint /bin/bash \
    "$IMAGE" -euc '
        source /usr/local/lib/tillandsias/lib-common.sh
        for name in GIT_SSL_CAINFO SSL_CERT_FILE REQUESTS_CA_BUNDLE NODE_EXTRA_CA_CERTS; do
            test -z "${!name:-}" || { echo "FAIL: forbidden CA override: $name" >&2; exit 1; }
        done
        test "${NODE_USE_SYSTEM_CA:-}" = 1
        test "$(grep -c "BEGIN CERTIFICATE" /etc/ssl/cert.pem)" -gt 2
        url="https://127.0.0.1:'"$port"'"
        curl -fsS "$url/upstream.git/HEAD" >/dev/null
        git ls-remote "$url/upstream.git" HEAD >/dev/null
        python3 -c "import urllib.request; urllib.request.urlopen(\"$url/upstream.git/HEAD\", timeout=5).read()"
        node -e "fetch(process.argv[1]).then(r => { if (!r.ok) throw Error(String(r.status)); }).catch(e => { console.error(e); process.exit(1); })" "$url/upstream.git/HEAD"
    '

printf 'not a certificate\n' >"$tmp/malformed-ca.crt"
if malformed_output="$(podman run --rm \
    --cap-drop=ALL \
    --security-opt=no-new-privileges \
    --security-opt=label=disable \
    --userns=keep-id \
    --mount "type=bind,source=$tmp/malformed-ca.crt,target=/run/tillandsias/ca-chain.crt,readonly=true" \
    --entrypoint /bin/bash \
    "$IMAGE" -euc 'source /usr/local/lib/tillandsias/lib-common.sh' 2>&1)"; then
    echo "FAIL: malformed runtime CA did not fail startup" >&2
    exit 1
fi
grep -Fq '[trust] ERROR: runtime proxy CA is not a PEM certificate' <<<"$malformed_output"

vendor_output="$(podman run --rm \
    --cap-drop=ALL \
    --security-opt=no-new-privileges \
    --security-opt=label=disable \
    --userns=keep-id \
    --entrypoint /bin/bash \
    "$IMAGE" -euc '
        source /usr/local/lib/tillandsias/lib-common.sh
        test "$(grep -c "BEGIN CERTIFICATE" /etc/ssl/cert.pem)" -gt 2
    ' 2>&1)"
grep -Fq '[trust] WARNING: runtime proxy CA is not mounted; using vendor roots only' <<<"$vendor_output"

echo "PASS: rootless forge runtime CA trust uses system defaults"
