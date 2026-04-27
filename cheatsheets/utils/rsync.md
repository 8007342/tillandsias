---
tags: []  # TODO: add 3-8 kebab-case tags on next refresh
languages: []
since: 2026-04-25
last_verified: 2026-04-27
sources:
  - https://download.samba.org/pub/rsync/rsync.1
  - https://rsync.samba.org/documentation.html
authority: high
status: current

# v2 — tier classification (cheatsheets-license-tiered)
tier: pull-on-demand
summary_generated_by: hand-curated
bundled_into_image: false
committed_for_project: false
pull_recipe: see-section-pull-on-demand
---
# rsync

@trace spec:agent-cheatsheets

**Version baseline**: rsync 3.x (Fedora 43 package; current 3.2+).
**Use when**: copying files efficiently — local↔local or local↔remote (over ssh). Delta-transfer means only changed bytes traverse the wire.

## Provenance

- rsync man page (Samba project, official): <https://download.samba.org/pub/rsync/rsync.1> — complete flag reference
- rsync documentation index: <https://rsync.samba.org/documentation.html> — links to man pages and FAQ
- **Last updated:** 2026-04-25

Verified against the official rsync man page: `-a` = `-rlptgoD` (confirmed, with note that ACLs, xattrs, hardlinks are NOT included); `--delete` removes extraneous files on the receiving side (confirmed); trailing slash on source copies contents rather than directory itself (confirmed); `--partial` keeps partially transferred files enabling potential resume.

## Quick reference

| Op | Command | Notes |
|----|---------|-------|
| Archive copy | `rsync -avz src/ dst/` | `-a` = `-rlptgoD`; `-v` verbose; `-z` compress |
| Mirror (delete extras) | `rsync -avz --delete src/ dst/` | dst becomes byte-for-byte src |
| Dry run | `rsync -avzn src/ dst/` | `-n` / `--dry-run` shows what would happen |
| Progress | `rsync -avz --progress src/ dst/` | per-file progress; `--info=progress2` for total |
| Exclude pattern | `rsync -avz --exclude='*.tmp' src/ dst/` | glob, not regex |
| Exclude from file | `rsync -avz --exclude-from=.rsyncignore src/ dst/` | one pattern per line |
| Over ssh | `rsync -avz -e ssh src/ user@host:dst/` | `-e` selects transport |
| Custom ssh port | `rsync -avz -e 'ssh -p 2222' src/ user@host:dst/` | quote the whole `-e` arg |
| Resume large transfer | `rsync -avz --partial --append-verify src/ dst/` | survives interruption |
| Backup overwritten files | `rsync -avz --backup --backup-dir=../backup src/ dst/` | safety net before `--delete` |

## Common patterns

**Plain archive copy (most common):**
```bash
rsync -avz /path/src/ /path/dst/        # preserve perms/times/owner/group
```

**Safe mirror with dry-run first:**
```bash
rsync -avzn --delete src/ dst/          # PREVIEW: shows what --delete would remove
rsync -avz  --delete src/ dst/          # then run for real
```

**Exclude build artifacts:**
```bash
rsync -avz --exclude='target/' --exclude='node_modules/' --exclude='*.log' src/ dst/
```

**Push to remote host over ssh:**
```bash
rsync -avz -e ssh --progress ./build/ deploy@host:/srv/app/
```

**Mirror with safety backup of overwritten/deleted files:**
```bash
rsync -avz --delete --backup --backup-dir="../backup-$(date +%F)" src/ dst/
```

## Common pitfalls

- **Trailing slash on source changes meaning**: `src/` copies the *contents* of src into dst; `src` (no slash) copies the *directory* src into dst (so you get `dst/src/...`). One slash difference = double-nested directory or missing parent.
- **`--delete` is destructive and irreversible**: it removes files on dst that don't exist on src. Always pair with `-n` first. Combine with `--backup-dir` if the dst has any value.
- **`--exclude` is glob, not regex**: `*.tmp`, `build/`, `**/cache` work; `.*\.tmp` does not. Trailing `/` matters for directory-only matches.
- **`-a` includes `-ptgo` (perms/times/group/owner)**: this can clobber dst-side ownership or fail on filesystems that don't support it (FAT, some network mounts). Drop with `--no-perms --no-owner --no-group` when copying to "foreign" filesystems.
- **`--owner`/`--group` need root on dst**: as a non-root user, preserving uid/gid silently degrades to "preserve names if they exist, else current user". Run under `sudo` (or via root ssh) if uid preservation actually matters.
- **Default skip-newer behavior**: by default rsync skips files where dst is newer than src (mtime check). Use `--update`/`-u` to make this explicit, or `--ignore-times` / `-I` to force re-check by checksum, or `--checksum`/`-c` to ignore mtime entirely.
- **Not atomic**: rsync writes files in place (or via `.~tmp~` then rename per-file). A killed transfer leaves dst in a half-state. Use `--partial-dir=.rsync-partial` plus a separate "publish" step (e.g. atomic symlink swap) for production deploys.
- **Bandwidth blast on shared links**: rsync will saturate available bandwidth. Cap with `--bwlimit=10M` (10 MB/s) when running over a metered or shared connection.
- **`-z` over ssh double-compresses**: ssh already compresses if `Compression yes` is set in `ssh_config`. Pick one — rsync's `-z` is usually better tuned for the data.

## Pull on Demand

> This cheatsheet's underlying source is NOT bundled into the forge image.
> Reason: upstream license redistribution status not granted (or off-allowlist).
> See `cheatsheets/license-allowlist.toml` for the per-domain authority.
>
> When you need depth beyond the summary above, materialize the source into
> the per-project pull cache by following the recipe below. The proxy
> (HTTP_PROXY=http://proxy:3128) handles fetch transparently — no credentials
> required.

<!-- TODO: hand-curate the recipe before next forge build -->

### Source

- **Upstream URL(s):**
  - `https://download.samba.org/pub/rsync/rsync.1`
- **Archive type:** `single-html`
- **Expected size:** `~1 MB extracted`
- **Cache target:** `~/.cache/tillandsias/cheatsheets-pulled/$PROJECT/download.samba.org/pub/rsync/rsync.1`
- **License:** see-license-allowlist
- **License URL:** https://download.samba.org/pub/rsync/rsync.1

### Materialize recipe (agent runs this)

```bash
set -euo pipefail
TARGET="$HOME/.cache/tillandsias/cheatsheets-pulled/$PROJECT/download.samba.org/pub/rsync/rsync.1"
mkdir -p "$(dirname "$TARGET")"
curl --fail --silent --show-error \
  "https://download.samba.org/pub/rsync/rsync.1" \
  -o "$TARGET"
```

### Generation guidelines (after pull)

1. Read the pulled file for the structure relevant to your project.
2. If the project leans on this tool/topic heavily, generate a project-contextual
   cheatsheet at `<project>/.tillandsias/cheatsheets/utils/rsync.md` using
   `cheatsheets/TEMPLATE.md` as the skeleton.
3. The generated cheatsheet MUST set frontmatter:
   `tier: pull-on-demand`, `summary_generated_by: agent-generated-at-runtime`,
   `committed_for_project: true`.
4. Cite the pulled source under `## Provenance` with `local: <cache target above>`.

## See also

- `utils/ssh.md` — for the `-e ssh` transport, key auth, and port/jumphost config
- `utils/git.md` — for source-controlled file movement (preferred over rsync for code)
