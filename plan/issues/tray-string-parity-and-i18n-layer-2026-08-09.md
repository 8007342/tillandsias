# Tray string parity: one string table, three trays, and the railguards that force 1:1

Filed 2026-08-09 by `windows-claude-fable-metaorch-20260809t063000z` on `windows-next`,
at operator direction:

> *"They should all read from the same set of String resources, why aren't they?
> They MUST be 1:1 feature parity at all times. […] all the notifications and ux
> hygiene should be as close to 1:1 for all platforms, since they all share the
> idiomatic podman and vm layers, pretty printed messages and pretty printed ux
> menu items should be the same everywhere, this should be similar to i18n
> support."*

Deliverable for packets **628-c7qd, 628-h4nx, 628-r2vk, 628-w9sm, 628-p5tj**.

trace: spec:tray-ux, spec:tray-app, order 243 (parity matrix semantic split),
order 261 (ruby-free parity check), packet 626-r7kq, packet 627-m3vp,
openspec/tray-parity-matrix.yaml, locales/

---

## Answering the question directly: why aren't they?

Because there are **three separate string systems**, and the one that looks
canonical is wired to nothing.

### 1. `locales/*.toml` — the canonical corpus, dormant

Seventeen languages (`ar de en es fr hi it ja ko nah pt ro ru ta te zh-Hans
zh-Hant`). `locales/en.toml` is 228 lines with a documented key namespace:

```toml
# Keys use dot-notation matching code organisation:
#   menu.*           Tray menu labels
#   cli.*            CLI attach/runner output
#   init.*           `tillandsias --init` output
#   errors.*         Error messages
#   notifications.*  Desktop notifications
```

It already carries the strings in question, including:

```toml
sign_in_github = "🔑 GitHub Login"
```

**No Rust crate reads any of it.** `grep -rn "locales/" crates/` returns nothing.
A 17-language translation corpus, complete with a `notifications.*` namespace, is
sitting unused while three trays hardcode English literals.

### 2. `/etc/tillandsias/locales/*.sh` — a second, parallel corpus

The forge container shell has its own localisation, in a different format, read
by `images/default/lib-common.sh:78`, `lib-localized-errors.sh:19`, and
`forge-welcome.sh:31`. Same 17 languages, `.sh` instead of `.toml`. Two corpora,
no generator between them, no guarantee they agree.

### 3. Hardcoded literals in each tray

Every user-visible string in all three trays is an inline literal. That is where
the drift lives.

---

## The drift is already real and already shipped

| surface | Linux | Windows / macOS |
|---|---|---|
| sign-in row | `🔑 GitHubLogin` | `🔑 GitHub Login` |
| unobserved sign-in state | none — bool, renders an actionable row | `🔄 Checking your account…` (626-r7kq) |

The sign-in label differs by a space, in a string the canonical `en.toml` already
spells correctly. Nothing detects it.

Notification counts alone show the surface area: 19 balloon sites in
`crates/tillandsias-windows-tray/src/notify_icon.rs`, 31 notification sites in
`crates/tillandsias-macos-tray/src/action_host.rs`. None of them share a source.

---

## Why the existing railguard cannot catch this

The project **does** have a parity railguard, and it works — for what it measures:

- `openspec/tray-parity-matrix.yaml` — capability rows × `linux|macos|windows`
  columns, statuses `done`/`regressed`, `parity: required`.
- `litmus:tray-parity-matrix-complete` — per-host column gate at post-build
  (order 243 split: each host verifies its own column; ALL columns is the
  release gate in `skills/merge-to-main-and-release/SKILL.md`).
- `tillandsias-policy parity-matrix` — the checker (order 261 made it ruby-free
  so Windows can actually run it).

Two structural gaps:

1. **It is capability-grained, not string-grained.** The row *"GitHub login in
   popup terminal (never inline)"* is `done` on all three platforms — and it is,
   truthfully. The row cannot see that one platform spells the button
   `GitHubLogin` and the others spell it `GitHub Login`. Copy drift is invisible
   to it **by construction**.
2. **Nothing forces a NEW surface to acquire a row.** A feature can land on one
   platform with no matrix row at all, and every gate stays green, because the
   gates check the cells that exist.

There is also no row class for notifications, toasts, balloons, status-chip text,
or tooltips — the "UX hygiene" half of the operator's ask.

---

## The structural enabler: there are TWO menu builders

- `crates/tillandsias-host-shell/src/menu_state.rs` → `build()` — Windows + macOS.
- `crates/tillandsias-headless/src/tray/mod.rs` → `build_menu()` — Linux, its own
  independent implementation gating on `is_authenticated: bool`.

This was proven live today. The 626-r7kq fix landed in the shared layer, Windows
and macOS inherited it, and Linux did not — it has the same defect through a
different mechanism, filed as 627-m3vp. Any string-parity railguard that does not
address this will be permanently fighting a second implementation.

**Converging the two builders is what makes the other four packets cheap.** With
one builder and one string table, most of this drift becomes unrepresentable
rather than merely detected.

---

## Governance note — the cleanup packet needs operator sign-off

Reconciling existing drift **changes a user-visible string on whichever platform
loses**. `spec:tray-ux` "UX curation governance" forbids that without recorded
operator approval for the exact surface change. So 628-w9sm must produce the
drift inventory and bring the *proposed* canonical spelling of each divergent
string to the operator, and must not self-select a winner — not even when one
side is "obviously" a typo. `🔑 GitHubLogin` vs `🔑 GitHub Login` is exactly such
a case, and it still needs the ruling.

The railguard packets (628-h4nx, 628-r2vk) add gates, not strings, and need no
UX approval. 628-c7qd is a refactor that must be **byte-identical** at the
surface — moving a literal into a table is not a UX change only if the rendered
bytes do not move; any string it cannot preserve exactly is a drift finding to
route to 628-w9sm, not a change to make in passing.

---

## Shape of the work

| packet | what it does |
|---|---|
| **628-c7qd** | Wire `locales/*.toml` into a shared Rust string layer; every tray string resolves by key. Reconcile the two corpora to one source. |
| **628-p5tj** | Converge the two menu builders so Linux stops being a second implementation. |
| **628-h4nx** | Railguard: fail the build on a hardcoded user-visible literal, or on platforms resolving one key differently. |
| **628-r2vk** | Railguard: a new user-visible surface cannot land without a matrix row + string key on all three platforms. |
| **628-w9sm** | Cleanup: inventory existing drift across menus, notifications, chips, tooltips; take the canonical-spelling rulings to the operator; apply. |

Dependency shape: `628-c7qd` and `628-p5tj` are the foundation and can run in
parallel; `628-h4nx` needs `628-c7qd`; `628-w9sm` needs `628-c7qd` and the
operator rulings; `628-r2vk` is independent of all of them and is the cheapest
thing on the list — it is a gate over the matrix file, buildable today.

**Recommended order: 628-r2vk first.** It stops the bleeding (no NEW drift)
while the larger refactors land, and it does not need the string layer to exist.

---

## Addendum 2026-08-09: operator ruling on "GitHub", and the terminology dictionary

The operator ruled:

> *"'🔑 GitHub Login' is correct, 'GitHub' is the correct spelling to be used
> wherever GitHub is referenced, we might even need a dictionary now that we're
> adding language work packets, to make sure language is consistent throughout
> our application."*

Recorded on **628-w9sm** as the first canonical-spelling ruling. The dictionary
is filed as **629-t6bx**.

### The ruling's blast radius is much smaller than it looks — measure before acting

`grep -rn "Github"` hits 15 files, which reads alarming. It is not:

- **No user-visible string misspells it.** A search for `Github` inside menu
  labels, locale values, and printed output returns **nothing**. The corpus and
  the trays already say "GitHub".
- **Every hit is a Rust identifier** — `GithubLoginState`,
  `GithubLoginStatusRequest`, `GithubLoginStatusReply` — or the `kind()`
  diagnostic string those types produce.
- **The one real user-visible defect is a missing space**, not a capital:
  `crates/tillandsias-headless/src/tray/mod.rs:3240` renders
  `"\u{1F511} GitHubLogin"`. That is the Linux tray, and it is the drift already
  tracked in 628-w9sm.

So the ruling closes exactly one user-visible item. Read literally — "wherever
GitHub is referenced" — it would also rename ~15 files of identifiers, and
`"GithubLoginStatusRequest"` is a `kind()` value appearing 6 times in dispatch
tables and error text, i.e. protocol-adjacent. That is a separate decision with
real blast radius and it is deliberately NOT bundled: see 629-t6bx's two tiers.

### Second finding: the locale corpus is unequal, not just unwired

Key counts per locale file:

| locales | keys |
|---|---|
| `de`, `es` | 169 |
| `en` | 168 |
| the other **14** (`ar fr hi it ja ko nah pt ro ru ta te zh-Hans zh-Hant`) | 143 |

Fourteen locales are ~26 keys behind. `sign_in_github` is one of the missing
ones — it is defined in **only 3 of 17** files (`en`, `de`, `es`). Two of those
three are translated (`🔑 Iniciar sesión en GitHub`,
`🔑 GitHub-Anmeldung`), so the corpus is real work, just unfinished.

This matters for 628-c7qd: the string layer's missing-key behaviour is not an
edge case to design for later, it is the **majority** case on day one for 14 of
17 languages. Fallback-to-`en` must be specified and tested before anything
resolves through it.
