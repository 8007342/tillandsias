# plan/fleet/peers/

One file per fleet host, `<host>.yaml`. A host is a fleet-messaging peer if
and only if its record is in this directory on the checkout a daemon runs
from: the tree is the trust root, and whoever can land on `linux-next`
already defines the fleet. There is no fleet CA, and mDNS never adds a peer.

Design: `openspec/changes/fleet-messaging-poc/design.md` Decision 4 (order
1506-32k5); the full record is extended by
`openspec/changes/fleet-wan-rendezvous/design.md` Decision 6 (order
1548-cii8, which owns the schema and `tillandsias fleet peers check`).

## Fields written by `tillandsias --msg-serve --mint` (1506-32k5)

| field       | value                                                          |
|-------------|----------------------------------------------------------------|
| `host`      | the host label; MUST equal the file name without `.yaml`       |
| `noise_pub` | the X25519 static public key, 64 lowercase hex characters      |
| `noise_fp`  | BLAKE2s-128 (16-byte digest) of the 32 key bytes, 32 lowercase hex |
| `minted`    | UTC time of the mint, `YYYY-MM-DDTHH:MM:SSZ`                   |

Optional, read by later rungs: `lan_hints: [ip:port, ...]` (1506-7tq4) and
`mesh_ip` (1506-t97c). Every other key (`announce_pub`, the SSH CA public
keys, `class_declared`, `substrate`, `admitted`, from 1548-cii8) is kept
when `--mint --rotate` rewrites the four fields above.

The private half never leaves the host: it lives at
`secret/fleet/msg/static` in that host's own Vault, which no forge policy can
read.

## How a record is used

A daemon loads every `*.yaml` here. A record is NOT trusted — its key reads
as unknown — when its file name is not a host label, `host` differs from the
file name, `noise_pub` is not 64 lowercase hex, `noise_fp` does not hash
`noise_pub`, or its key duplicates an earlier record. After the Noise XX
handshake (`Noise_XX_25519_ChaChaPoly_BLAKE2s`) each end looks the other's
static key up here; an unknown key is `refused:msg:unknown-peer:<fp>` and
the connection closes before any envelope byte is read.

## Joining and rotating

```bash
tillandsias --msg-serve --mint            # once per host; again prints skip:msg:key-exists
tillandsias --msg-serve --mint --rotate   # new key; every peer needs the rewritten record
```

Then land `plan/fleet/peers/<host>.yaml` by the normal flow. A refusal names
the fingerprint, so the remedy for `refused:msg:unknown-peer:<fp>` is to land
(or merge) the record whose `noise_fp` is `<fp>`.

## Open naming conflict

1506-32k5's title and the fleet-messaging design and spec delta call the
fingerprint field `fp`; 1548-cii8 and fleet-wan-rendezvous Decision 6 call
it `noise_fp`. The code writes and reads `noise_fp`, the name used by the
packet that owns the schema. The fleet-messaging design and spec delta still
say `fp` and need reconciling before that delta is synced. The mDNS TXT key
stays `fp=`, as the design names it.
