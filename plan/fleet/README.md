# plan/fleet/

The fleet's tree-visible trust and service records. The tree is the trust
root: whoever can land on `linux-next` already defines the fleet.

Design: `openspec/changes/fleet-wan-rendezvous/design.md` Decision 6 (order
1548-cii8). Checker: `tillandsias fleet peers check [--peers DIR]`, which
exits 0 and prints `ok:fleet-peers:<n>-records`, or exits 1 printing one
`refused:fleet-peers:<record>:<name>` line per defect, each followed by
`  why:` and `  remedy:` lines.

## `peers/<host>.yaml`

One record per host; see `peers/README.md` for the fields `tillandsias
--msg-serve --mint` writes (1506-32k5) and keeps. The full schema:

| field | rule | refusal name |
|---|---|---|
| `host` | canonical DNS label (`cloudflare_names::normalize_label` leaves it unchanged; valid in `<host>.fleet.tlatoani.net`), equals the file name | `non-canonical-host:<host>:want:<label>`, `host-is-not-file-name:<host>` |
| `announce_pub` | Ed25519 public key, 64 lowercase hex | `missing-field:` / `malformed-field:announce_pub` |
| `noise_pub` | X25519 public key, 64 lowercase hex | `missing-field:` / `malformed-field:noise_pub` |
| `noise_fp` | BLAKE2s-128 of the `noise_pub` bytes, 32 lowercase hex | `noise-fp-mismatch` |
| `ssh_host_ca_pub`, `ssh_user_ca_pub` | OpenSSH public key line `<type> <base64> [comment]` | `missing-field:` / `malformed-field:<field>` |
| `class_declared`, `substrate` | non-empty string | `missing-field:<field>` |
| `admitted` | `{date: YYYY-MM-DD, by: <string>}` | `missing-field:admitted.date` etc. |
| `minted`, `lan_hints`, `mesh_ip`, anything else | optional; kept, never refused | |

Across a record: no value may contain an email address
(`email-in-field:<path>`; an SSH key comment is the usual culprit), and no
two records may share a `noise_pub` (`duplicate-noise-pub-of:<host>`). An
unreadable or non-mapping file is `unreadable` / `not-yaml` /
`not-a-mapping`; an empty directory is `no-records` (a check over nothing is
refused, not passed).

The fingerprint field is named `noise_fp`. The fleet-messaging design calls
it `fp`; that conflict is open (see `peers/README.md`) and no second name
exists in the record.

Enrollment (1548-ciq2) is what writes the CA, `announce_pub`, `admitted`
fields; until it lands a record carries them by hand.

## `owner.yaml`

`{github_user_id: <numeric>, cloudflare_user_sha256: <64 hex of
sha256(salt || user_id)>, salt: <hex, at least 16 characters>}`. Checked by
`fleet peers check` when present (`refused:fleet-peers:owner:<name>`); no
account id or email appears in a name.
