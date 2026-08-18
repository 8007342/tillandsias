#!/usr/bin/env bash
# @trace order:801-kqme, spec:nix-cache-service
#
# nix-cache-service.sh — serve the persistent host nix store (order 795-h8er)
# to the enclave as a real nix BINARY CACHE, so a disposable forge lands on a
# warm cache without any host path being mounted into it.
#
# STORAGE DOES NOT NEED A CONTAINER; SERVING DOES.
#
# 795-h8er already gave this host a persistent, rooted, GC-bounded store under
# $HOME. That store keeps serving host-side builds directly and is untouched by
# this script. What was missing is a way for a container that is NOT allowed to
# see host paths to benefit from it.
#
# WHY NOT JUST BIND-MOUNT THE STORE INTO THE FORGE (order 801-kqme, and the
# operator asked this exact question):
#
#   1. It punches through the property the forge exists to have. Forge
#      containers are enclave-only by spec (forge-offline); the host mount is a
#      deliberate opt-in guard (order 437) precisely BECAUSE it is a boundary
#      violation. Making the fast path require it inverts the default.
#   2. Nix validity is not bytes on disk. A read-only /nix/store without the
#      SQLite db yields paths nix does not consider valid. Making it work means
#      either sharing a WRITABLE db across concurrent forges — a lock-contention
#      and corruption surface with N forges — or --store gymnastics that the
#      790-mbk9 logical-vs-physical trap already bit us on once.
#   3. It couples every forge to a host path layout, which is exactly what makes
#      one image behave differently on macOS and Windows.
#
# A substituter is nix's own protocol for this: read-only by construction,
# content-addressed, safe under concurrent readers, no shared mutable db. When
# 790-6n2k eventually picks a remote cache, that becomes an UPSTREAM substituter
# of this one rather than a second mechanism.
#
# TWO TRUST MECHANISMS, NOT ONE. This is the correction to the framing that a
# trusted CA alone is enough, and it must not be collapsed:
#
#   TRANSPORT  the stack CA (/tmp/tillandsias-ca) mints a leaf for `nix-cache`,
#              exactly as vault_bootstrap.rs does for `vault`. This proves you
#              are talking to OUR cache and not something else on the network.
#   CONTENT    nix verifies an ed25519 signature on every path against
#              `trusted-public-keys`. This proves the BYTES are ones our store
#              signed, independent of who served them.
#
# They are different properties and both are load-bearing. The tempting
# shortcut — listing the cache in `trusted-substituters` so signatures are
# skipped — means "accept whatever this host sends" and throws away the
# integrity property that makes a shared cache safe under concurrency. We do
# not take it. The secret key is generated on the host, lives outside the repo
# and outside every image, and never enters a container that is not this
# service.
#
# WHY harmonia AND NOT nix-serve — measured on macuahuitl 2026-08-17, not
# assumed (the packet asked for a measurement):
#
#   harmonia 3.2.0    67 MiB closure,   7 store paths
#   nix-serve 0.2    231 MiB closure, 177 store paths   (Perl and its deps)
#
# and, decisively, harmonia-cache serves a fully READ-ONLY store — it needs no
# write access to the WAL SQLite db, so the host keeps building into the same
# store while this serves it, with no shared mutable state at all. Note that the
# `harmonia` dispatcher binary shells out to a `nix` CLI that is not in the
# image; `harmonia-cache` is the actual server and needs no nix at all. That is
# why this script execs harmonia-cache directly.
#
# WHERE THE BINARY COMES FROM. The service mounts the store read-only anyway, so
# harmonia is taken FROM that store and pinned with a GC root rather than baked
# into an image. This reuses 795-h8er's pin mechanism as the delivery mechanism
# and keeps the image contentless. The trade-off is that the served version
# tracks the host store rather than an image tag; see the ledger for 801-kqme.
#
# GRAMMAR (exactly one line on stdout)
#   ok:nix-cache-key:<generated|present>:pubkey=<name:base64>
#   ok:nix-cache:<started|already-running>:endpoint=<url>:pinned=<n>
#   ok:nix-cache-status:<running|stopped|absent>:endpoint=<url>
#   ok:nix-cache-stop:<stopped|absent>
#   skip:nix-cache:<no-nix|no-store>
#   blocked:nix-cache:<no-harmonia|no-ca|no-enclave|start-failed|unhealthy>
#
# Exit 0 on ok/skip, 1 on blocked.
#
# USAGE
#   scripts/nix-cache-service.sh keygen             # create the signing keypair
#   scripts/nix-cache-service.sh pubkey             # print trusted-public-keys value
#   scripts/nix-cache-service.sh ensure             # mint TLS, pin, start
#   scripts/nix-cache-service.sh status             # is it up and answering?
#   scripts/nix-cache-service.sh stop               # stop and remove
#   scripts/nix-cache-service.sh substituter-args   # nix flags, only if reachable

set -uo pipefail

CONTAINER_NAME="${TILLANDSIAS_NIX_CACHE_CONTAINER:-tillandsias-nix-cache}"
CHROOT_STORE="${TILLANDSIAS_NIX_CHROOT_STORE:-$HOME/.local/share/tillandsias/nix-store}"
STATE_DIR="${TILLANDSIAS_NIX_CACHE_STATE:-$HOME/.local/share/tillandsias/nix-cache}"
ENCLAVE_NET="${TILLANDSIAS_ENCLAVE_NET:-tillandsias-enclave}"
CA_DIR="${TILLANDSIAS_CA_DIR:-/tmp/tillandsias-ca}"
SERVICE_ALIAS="nix-cache"
IN_PORT=5000
HOST_PORT="${TILLANDSIAS_NIX_CACHE_HOST_PORT:-5111}"
BASE_IMAGE="${TILLANDSIAS_NIX_CACHE_BASE_IMAGE:-registry.fedoraproject.org/fedora-minimal:44}"
KEY_NAME="${TILLANDSIAS_NIX_CACHE_KEY_NAME:-tillandsias-nix-cache-1}"

SECRET_KEY="$STATE_DIR/cache-priv.key"
PUBLIC_KEY="$STATE_DIR/cache-pub.key"
TLS_CRT="$STATE_DIR/nix-cache.crt"
TLS_KEY="$STATE_DIR/nix-cache.key"
CA_BUNDLE="$STATE_DIR/ca-bundle.crt"
HARMONIA_CONF="$STATE_DIR/harmonia.toml"

NIX_FEATURES=(--extra-experimental-features "nix-command flakes")
PIN_SUBDIR="nix/var/nix/gcroots/tillandsias"

# The enclave proxy only resolves while the enclave runs; neutralize it for
# registry traffic rather than starting the whole stack to pull one image.
# (Same reasoning as scripts/nix-toolbox.sh.)
_podman() { env http_proxy= https_proxy= HTTP_PROXY= HTTPS_PROXY= podman "$@"; }

have_nix() { command -v nix >/dev/null 2>&1; }
store_present() { [ -d "$CHROOT_STORE/nix/store" ]; }

# nix reports LOGICAL /nix/store paths even for a chroot store. A GC root that
# targets the PHYSICAL path is not recognized (790-mbk9 generalizes), so every
# root target must be forced logical.
_logical() {
    case "$1" in
        /nix/store/*) printf '%s\n' "$1" ;;
        "$CHROOT_STORE"/nix/store/*) printf '/nix/store/%s\n' "${1#"$CHROOT_STORE"/nix/store/}" ;;
        */nix/store/*) printf '/nix/store/%s\n' "${1#*/nix/store/}" ;;
        *) printf '%s\n' "$1" ;;
    esac
}

# Resolve harmonia in the persistent store, building it there if absent.
resolve_harmonia() {
    nix "${NIX_FEATURES[@]}" build --store "$CHROOT_STORE" --no-link \
        --print-out-paths nixpkgs#harmonia 2>/dev/null | head -1
}

pin_harmonia() { # <logical-path>
    local p="$1" dir="$CHROOT_STORE/$PIN_SUBDIR"
    mkdir -p "$dir" 2>/dev/null || return 1
    ln -sfn "$p" "$dir/nix-cache-harmonia" 2>/dev/null || return 1
    return 0
}

pinned_count() {
    local dir="$CHROOT_STORE/$PIN_SUBDIR"
    [ -d "$dir" ] || { echo 0; return; }
    find "$dir" -maxdepth 1 -type l 2>/dev/null | wc -l | tr -d '[:space:]'
}

ensure_keypair() {
    mkdir -p "$STATE_DIR" 2>/dev/null || return 1
    chmod 700 "$STATE_DIR" 2>/dev/null
    if [ -s "$SECRET_KEY" ] && [ -s "$PUBLIC_KEY" ]; then
        return 0
    fi
    rm -f "$SECRET_KEY" "$PUBLIC_KEY"
    nix-store --generate-binary-cache-key "$KEY_NAME" "$SECRET_KEY" "$PUBLIC_KEY" >/dev/null 2>&1 || return 1
    chmod 600 "$SECRET_KEY" 2>/dev/null
    return 0
}

# Mint a leaf for `nix-cache` off the stack CA, the same way vault's leaf is
# minted. SANs cover the in-enclave DNS name and the host loopback publication.
ensure_tls_leaf() {
    [ -s "$CA_DIR/intermediate.crt" ] && [ -s "$CA_DIR/intermediate.key" ] || return 1
    mkdir -p "$STATE_DIR" 2>/dev/null || return 1
    if [ -s "$TLS_CRT" ] && [ -s "$TLS_KEY" ]; then
        # Still valid for at least a day, and issued by the CURRENT CA?
        if openssl x509 -in "$TLS_CRT" -noout -checkend 86400 >/dev/null 2>&1 \
           && openssl verify -CAfile "$CA_DIR/intermediate.crt" "$TLS_CRT" >/dev/null 2>&1; then
            return 0
        fi
    fi
    local cnf="$STATE_DIR/leaf.cnf"
    cat >"$cnf" <<EOF
[req]
distinguished_name = dn
req_extensions = v3
prompt = no
[dn]
CN = ${SERVICE_ALIAS}
O = Tillandsias
[v3]
subjectAltName = DNS:${SERVICE_ALIAS},DNS:localhost,IP:127.0.0.1
extendedKeyUsage = serverAuth
EOF
    openssl req -new -newkey rsa:2048 -nodes \
        -keyout "$TLS_KEY" -out "$STATE_DIR/leaf.csr" -config "$cnf" >/dev/null 2>&1 || return 1
    openssl x509 -req -in "$STATE_DIR/leaf.csr" \
        -CA "$CA_DIR/intermediate.crt" -CAkey "$CA_DIR/intermediate.key" -CAcreateserial \
        -out "$TLS_CRT" -days 30 -extensions v3 -extfile "$cnf" >/dev/null 2>&1 || return 1
    chmod 600 "$TLS_KEY" 2>/dev/null
    rm -f "$STATE_DIR/leaf.csr"
    return 0
}

# nix on the HOST trusts the system bundle, which does not include the stack CA.
# Emit a combined bundle so the host lane can verify the leaf too, rather than
# turning verification off.
ensure_ca_bundle() {
    local sys=""
    for c in /etc/pki/ca-trust/extracted/pem/tls-ca-bundle.pem \
             /etc/ssl/certs/ca-certificates.crt \
             /etc/ssl/cert.pem; do
        [ -r "$c" ] && { sys="$c"; break; }
    done
    [ -s "$CA_DIR/intermediate.crt" ] || return 1
    : >"$CA_BUNDLE" || return 1
    [ -n "$sys" ] && cat "$sys" >>"$CA_BUNDLE"
    cat "$CA_DIR/intermediate.crt" >>"$CA_BUNDLE"
    return 0
}

write_harmonia_conf() {
    # `workers` MUST be explicit: harmonia derives 0 in this container and dies
    # with "workers must be greater than 0" (measured 2026-08-17).
    # priority 30 beats cache.nixos.org's 40, so local wins when both have a path.
    cat >"$HARMONIA_CONF" <<EOF
bind = "0.0.0.0:${IN_PORT}"
workers = 4
max_connection_rate = 256
priority = 30
sign_key_paths = ["/run/nix-cache/cache-priv.key"]
tls_cert_path = "/run/nix-cache/nix-cache.crt"
tls_key_path = "/run/nix-cache/nix-cache.key"
EOF
}

container_running() {
    [ "$(_podman inspect -f '{{.State.Running}}' "$CONTAINER_NAME" 2>/dev/null)" = "true" ]
}

container_exists() {
    _podman container exists "$CONTAINER_NAME" >/dev/null 2>&1
}

enclave_exists() {
    _podman network exists "$ENCLAVE_NET" >/dev/null 2>&1
}

endpoint_host() { printf 'https://127.0.0.1:%s\n' "$HOST_PORT"; }
endpoint_enclave() { printf 'https://%s:%s\n' "$SERVICE_ALIAS" "$IN_PORT"; }

probe_ready() {
    curl -sS -m 8 --cacert "$CA_BUNDLE" \
        "$(endpoint_host)/nix-cache-info" 2>/dev/null | grep -q '^StoreDir: /nix/store'
}

do_ensure() {
    have_nix || { echo "skip:nix-cache:no-nix"; return 0; }
    store_present || { echo "skip:nix-cache:no-store"; return 0; }
    enclave_exists || { echo "blocked:nix-cache:no-enclave"; return 1; }
    ensure_keypair || { echo "blocked:nix-cache:no-ca"; return 1; }
    ensure_tls_leaf || { echo "blocked:nix-cache:no-ca"; return 1; }
    ensure_ca_bundle || { echo "blocked:nix-cache:no-ca"; return 1; }

    local harmonia logical
    harmonia="$(resolve_harmonia)"
    [ -n "$harmonia" ] || { echo "blocked:nix-cache:no-harmonia"; return 1; }
    logical="$(_logical "$harmonia")"
    pin_harmonia "$logical" || { echo "blocked:nix-cache:no-harmonia"; return 1; }
    [ -x "$CHROOT_STORE${logical}/bin/harmonia-cache" ] || { echo "blocked:nix-cache:no-harmonia"; return 1; }

    if container_running && probe_ready; then
        echo "ok:nix-cache:already-running:endpoint=$(endpoint_enclave):pinned=$(pinned_count)"
        return 0
    fi

    write_harmonia_conf
    _podman rm -f "$CONTAINER_NAME" >/dev/null 2>&1

    # label=disable: the store is a shared 6.5 GiB host directory. `:Z` would
    # RELABEL it, which would disrupt every other consumer of the same store.
    # Refusing to relabel a shared host path is the right call here.
    _podman run -d --name "$CONTAINER_NAME" \
        --network "$ENCLAVE_NET" \
        --network-alias "$SERVICE_ALIAS" \
        --hostname "$SERVICE_ALIAS" \
        --cap-drop=ALL \
        --security-opt=no-new-privileges \
        --security-opt label=disable \
        --pids-limit=256 \
        --read-only \
        --tmpfs /tmp:rw,nosuid,nodev,size=64m \
        -p "127.0.0.1:${HOST_PORT}:${IN_PORT}" \
        -v "$CHROOT_STORE/nix:/nix:ro" \
        -v "$SECRET_KEY:/run/nix-cache/cache-priv.key:ro" \
        -v "$TLS_CRT:/run/nix-cache/nix-cache.crt:ro" \
        -v "$TLS_KEY:/run/nix-cache/nix-cache.key:ro" \
        -v "$HARMONIA_CONF:/run/nix-cache/harmonia.toml:ro" \
        -e CONFIG_FILE=/run/nix-cache/harmonia.toml \
        --entrypoint "${logical}/bin/harmonia-cache" \
        "$BASE_IMAGE" >/dev/null 2>&1 \
        || { echo "blocked:nix-cache:start-failed"; return 1; }

    local i=0
    while [ "$i" -lt 40 ]; do
        probe_ready && { echo "ok:nix-cache:started:endpoint=$(endpoint_enclave):pinned=$(pinned_count)"; return 0; }
        i=$((i + 1))
        sleep 0.25
    done
    echo "blocked:nix-cache:unhealthy"
    return 1
}

cmd="${1:-status}"
shift || true

case "$cmd" in
    keygen)
        have_nix || { echo "skip:nix-cache:no-nix"; exit 0; }
        if [ -s "$SECRET_KEY" ] && [ -s "$PUBLIC_KEY" ]; then
            echo "ok:nix-cache-key:present:pubkey=$(cat "$PUBLIC_KEY")"
            exit 0
        fi
        ensure_keypair || { echo "blocked:nix-cache:no-ca"; exit 1; }
        echo "ok:nix-cache-key:generated:pubkey=$(cat "$PUBLIC_KEY")"
        ;;
    pubkey)
        [ -s "$PUBLIC_KEY" ] || { echo "blocked:nix-cache:no-ca"; exit 1; }
        cat "$PUBLIC_KEY"
        ;;
    ensure)
        do_ensure
        exit $?
        ;;
    status)
        if ! container_exists; then
            echo "ok:nix-cache-status:absent:endpoint=$(endpoint_enclave)"
            exit 0
        fi
        if container_running && probe_ready; then
            echo "ok:nix-cache-status:running:endpoint=$(endpoint_enclave)"
        else
            echo "ok:nix-cache-status:stopped:endpoint=$(endpoint_enclave)"
        fi
        ;;
    stop)
        if container_exists; then
            _podman rm -f "$CONTAINER_NAME" >/dev/null 2>&1
            echo "ok:nix-cache-stop:stopped"
        else
            echo "ok:nix-cache-stop:absent"
        fi
        ;;
    substituter-args)
        # Only emit flags when the cache is actually answering. A dead
        # substituter in a build's flag list is worse than no substituter: nix
        # retries it on every path. Silence here means "build as you did before".
        [ -s "$PUBLIC_KEY" ] || exit 0
        probe_ready || exit 0
        printf '%s\n' \
            --substituters "$(endpoint_host)" \
            --trusted-public-keys "$(cat "$PUBLIC_KEY")" \
            --ssl-cert-file "$CA_BUNDLE"
        ;;
    *)
        echo "usage: $0 [keygen|pubkey|ensure|status|stop|substituter-args]" >&2
        exit 2
        ;;
esac
