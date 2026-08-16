# DECISION: `images/default/cheatsheets/` stays TRACKED — it is an embedded build input, not a stray copy

- **Date:** 2026-08-16 · **Host:** linux-immutable (yoga) · **Agent:** linux-yoga-claude-20260816t185912z
- **Operator directive:** justify the `.gitignore` rule's stay or its removal; the
  cheatsheet system and the expert system are tightly coupled, so every moving
  part needs justification and the methodology must back the procedure.
- **Verdict:** **KEEP the tracking. Remove the advice to drop it.** The tooling's
  own advisory (`git rm -r --cached images/default/cheatsheets`) would break
  `tillandsias --init` for every curl-installed user.

## 1. What is actually true (the archaeology)

**The `.gitignore` rule never flip-flopped — not once.** `git log -G
'images/default/cheatsheets' --all` returns exactly ONE commit in all of
history, on all refs: `35ba3d3f4` (2026-07-04). The rule was written once and
never touched, including through the 2026-08-12 `.gitignore` hardening pass
that reordered everything around it. All four platform branches agree: 231
tracked files, 1 ignore line.

**The ignore was added AFTER the tracking, and gitignore is inert against
already-tracked paths.** 224 files were committed on 2026-05-28 (`c373f12a6`),
6 more by 2026-07-03 — all against a path that carried no ignore rule at the
time. When `35ba3d3f4` added `images/default/cheatsheets/` on 2026-07-04, 230
files were already in the index. Only **2 of 231** files were ever a true
force-add (`67b79ef89`, 2026-07-14). So "someone force-added a gitignored
tree" is not what happened; the tree was tracked first and ignored afterwards.

**The stated reason for the rule is four words.** `35ba3d3f4`'s subject is
`feat(forge): wire Antigravity as a first-class forge agent`; the rule appears
in the last clause of the last bullet: *".gitignore generated dirs and
build-*.log"*. No commit message anywhere records why the derived tree was
committed — `c373f12a6`'s body is empty, `67b79ef89`'s is a bare subject.

**What DID flip-flop is the recorded BELIEF**, three times in 21 days, inside
packet 448 (`cheatsheet-image-copy-drift-prevention`): the tree is committed
(2026-07-20T06:20Z) → *"CORRECTION: it is GITIGNORED (build-generated), not
committed"* (06:30Z, ten minutes later, **false** — 231 files were tracked at
that instant) → "the durable fix is to stop committing the derived tree"
(2026-07-29) → "the committed image copy remains build-generated and
re-drifts" (2026-08-10). That single false correction is why no untrack was
ever attempted, and it propagated verbatim into
`scripts/stage-image-cheatsheets.sh` and
`openspec/litmus-tests/litmus-cheatsheet-host-image-sync.yaml`, both of which
still describe the tree as if untracked.

**Separately:** `c38e91f83` (2026-07-03), whose message says only ".gitignore:
add mock-release/", silently rewrote the whole file (+62/−76), alphabetically
sorting it and orphaning ~30 explanatory comments from the rules they
documented. The cheatsheet rule postdates that sort by one day, so the sort is
not why *this* rule lacks rationale — but it is why most other rules in that
file now read as arbitrary. Filed separately.

## 2. Why it must STAY (the decisive evidence)

The tracked copy has a consumer, and it is not the developer build:

1. **`crates/tillandsias-headless/build.rs` embeds `images/` recursively into
   the binary at cargo-build time.** Cheatsheets are not excluded. The
   generated `runtime_assets_generated.rs` contains 233
   `images/default/cheatsheets/...` asset paths.
2. **`./build.sh` never stages cheatsheets** — the string "cheatsheet" does not
   appear in it, and it never calls `build-image.sh`. So `cargo build` embeds
   whatever is on disk; on a fresh clone or in CI that is exactly the tracked
   231 files.
3. **The end-user lane cannot stage at all.** `resolve_runtime_asset_root`
   materializes the EMBEDDED assets to
   `~/.local/share/tillandsias/runtime/<version>/` and builds the image from
   that root. It contains no authored `cheatsheets/` and no
   `stage-image-cheatsheets.sh`, so staging is impossible there by
   construction.
4. **A unit test already depends on it.**
   `every_containerfile_copy_source_exists_in_embedded_assets` asserts every
   `COPY` source resolves to an embedded asset;
   `Containerfile:44 COPY cheatsheets/ /opt/cheatsheets-image/` therefore
   hard-requires a non-empty embedded tree. A bare `git rm -r --cached` turns
   that test RED on a fresh clone and makes `tillandsias --init` fail at the
   `COPY` for every curl-installed user.

**The sibling asymmetry is fully explained, and it is the clincher.**
`images/default/skills/` was untracked in March and is safe *because
`build.rs:199` explicitly excludes it from asset collection*. Same ignore
commit, three sibling rules, three outcomes — the difference is not policy, it
is whether the binary embeds the tree. Cheatsheets are embedded; skills are
not. Any argument from the `skills/` precedent must account for that line.

## 3. What is genuinely broken (and it is not "drift")

The advisory calls the tracked copy "a second, **drifting** copy". Content
drift is measurably false: at every sampled ref the shared files are
byte-identical (229/229, 231/231). The real defect is **incompleteness**:

- `git diff HEAD:cheatsheets HEAD:images/default/cheatsheets` → **5 files, 851
  deletions**. The tracked tree is the authored tree *minus*
  `architecture/enclave-service-catalog-research.md`,
  `architecture/transport-overhead.md`,
  `concurrent-git/crdt-ledger-fragments.md`,
  `concurrent-git/git-mirror-managed-alternatives.md`,
  `runtime/forge-loss-on-shutdown-window.md`.
- **All five are advertised in the shipped `INDEX.md`.** The image therefore
  ships an index promising five cheatsheets whose files are absent — the exact
  failure mode that makes an expert unsound: it can cite what it cannot open.
- One of them, `concurrent-git/crdt-ledger-fragments.md`, is a **ground-truth
  fixture path** (`groundtruth.rs:702/:723`).

**Why no gate caught it.** No provenance gate reads the derived tree at all
(`grep -c 'images/default/cheatsheets' crates/tillandsias-policy/src/main.rs`
= 0). The one check that touches it, `litmus:cheatsheet-host-image-sync`, runs
`--verify`, which **regenerates the working tree with `rm -rf` + `cp -rp`
BEFORE comparing** and reports `regenerated` — a PASS pattern. It repairs the
working tree and leaves the *index* stale, silently. That blind spot is why a
real inversion survived three days: `79b3e82da` (2026-07-21) edited **only the
derived copy** of `runtime/codex-agent-entrypoints.md`, giving the tracked tree
`last_verified: 2026-07-21` while its own authored source still said
`2026-05-20`; the next `./build.sh` silently reverted it. Attribution flowed
backwards, and nothing noticed.

## 4. The rule going forward

1. `cheatsheets/` is the **sole authoring surface**. Never hand-edit
   `images/default/cheatsheets/` — an edit there is either reverted by the next
   stage or, worse, ships attribution its source does not carry.
2. `images/default/cheatsheets/` is a **tracked derived build input**, not a
   convenience copy. It is committed because the binary embeds it and the
   end-user image build has no other source. It is regenerated only by
   `scripts/stage-image-cheatsheets.sh`.
3. The tracked copy MUST equal the authored tree at every commit. This is now
   checked against the INDEX, not just the working tree.
4. Attribution (`tier`, `sources`, `authority`, `last_verified`,
   `bundled_into_image`, `committed_for_project`) is read from the authored
   frontmatter by every gate. The derived tree inherits it by copy and is never
   an independent source of provenance.

## 5. Residue (filed separately)

- `cheatsheets/TEMPLATE.md` carries **no YAML frontmatter**, while
  `methodology/cheatsheets.yaml:142-147` requires frontmatter on every
  cheatsheet — the template authors copy cannot satisfy the canon.
- `cheatsheets/runtime/forge-loss-on-shutdown-window.md` uses HTML-comment
  provenance instead of frontmatter, making it invisible to every
  frontmatter-parsing gate.
- `.gitignore`'s ~30 comments were orphaned from their rules by `c38e91f83`.
- Packet 448's false 2026-07-20 correction should be corrected in the ledger so
  the next reader does not re-derive the wrong conclusion.
