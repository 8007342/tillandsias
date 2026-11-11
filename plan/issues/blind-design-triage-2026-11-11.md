# Blind-design triage — 2026-11-11 (order 2080-294s)

Triage lead: macuahuitl-fedora. Inputs: four blind designs (designer A and B
for the tray and cloud, a security design, an events design), two independent
judges, a black-box audit of the live host, and 19 operator questions. Copies
are in `plan/issues/blind-design-2026-11-11/` (no secret values; scanned for
key, token, AppRole and PEM shapes before copying). Code is cited by symbol.

## Contamination caveat

The blind sessions were not blind. Every designer got the injected CLAUDE.md,
the auto-memory index and the skill list in its first turn, so operator rulings
and project vocabulary leaked into the "independent" designs. Judge 1 scored
those rows "n.i." (not independent) and left them out of the independent
totals; eight of thirty-two rows could not measure independence. Judge 2
excluded A7 for the same reason. Read X-over-Y gaps on ruling-shaped rows as
"the rulings are good", not "the blind design found it". Filed as
2080-nrgw so the next exercise starts clean.

## Scores

X = blind designs (paper only, implemented 0), Y = the current system.

**Judge 1** (0–4 per row):

| Area | X | Y | X indep. | Y indep. |
|---|---|---|---|---|
| Tray (A / B) | 17 / 18 of 24 | 15 | 15 / 16 of 20 | 13 |
| Cloud (A / B) | 20 / 18 of 24 | 14 | 18 / 16 of 20 | 12 |
| Security | 23 of 28 | 14 | 19 of 20 | 10 |
| Supply chain | 18 of 24 | 16 | 12 of 16 | 10 |
| Events | 23 of 28 | 15 | 19 of 20 | 11 |
| Cross-cutting | A 16, B 18, Sec 17, Evt 16 of 20 | 11 | | |
| Implemented | 0 of 20 | 14 | | |

**Judge 2** (D = design, I = implemented):

| Area | X.D | Y.D | max | Y.I |
|---|---|---|---|---|
| Product promise | 16 | 13 | 24 | 17 |
| Per-platform obligations | 17 | 16 | 24 | 18 |
| Credential hygiene | 30 | 23 | 36 | 24 |
| Observability for forge agents | 27 | 17 | 28 | 18 |
| Supply-chain provenance | 20 | 16 | 28 | 15 |
| Earned complexity | 20 | 8 | 24 | — |
| Language direction | 12 | 6 | 16 | 5 |
| **Total** | **142** | **99** | 180 | **97 / 152** |

Both judges agree on where the gaps are: credentials, forge-agent
observability, idle overhead with no number, and complexity / shell growth.

## Operator rulings applied (2026-11-11)

- **Design floor** = 16 GB RAM and an accelerator (iGPU, dGPU and/or NPU);
  yoga, yolanda and tlatoanis-macbook-air are examples. Below the floor install
  proceeds with a warning and local inference is off by default; agents may
  start it on demand with a performance warning.
- **Near-zero idle for everything**; events over polling; unavoidable polling
  uses exponential backoff.
- **Multi-machine is in scope** (Cloudflare login, IPv6 discovery with shared
  floating addresses, an always-on Raspberry Pi fleet). Linked rather than
  refiled: 1548-5t00, 1548-7onc, 1548-2ilf, 1548-i07i, 1548-v453, 1548-y56i,
  1800-zk9i, 1800-pj2x, 1800-p47s, 1290-5833, 1291-38mt, 593-9y5r.
- **Licence acceptances are committed in the project repository**; a vault
  wipe never loses them. Change proposal:
  `openspec/changes/licence-acknowledgements-in-repo`.
- **Every obligation holds independently on each platform**: platform rows
  are split where the work differs (idle measurement, guest stop, floor probe).

## Answered operator questions

- **OQ-1** floor host → the capability floor above (refines option c).
- **OQ-2** what near-zero binds → the whole product, every service (option b);
  numbers proposed by 2080-anej / 2080-ari8 / 2080-bbuu, confirmed by the operator.
- **OQ-3** Linux desktop with no tray host → not ruled on in the 2026-11-11
  rulings; **still open** (it was grouped with OQ-1..4 but nothing answers it).
- **OQ-4** more than one machine → yes, option (b), through the Cloudflare
  login, IPv6 discovery and the Pi fleet.
- **OQ-19** licence key after a vault wipe → option (a): a new key, old records
  stay valid against the signer committed in the repository (design D2).

## Open operator questions

OQ-3, OQ-5, OQ-6, OQ-7, OQ-8, OQ-9, OQ-10, OQ-11, OQ-12, OQ-13, OQ-14, OQ-15,
OQ-16, OQ-17, OQ-18 (text in `blind-design-2026-11-11/operator-questions.md`).
OQ-6 holds the Vault audit file retention; OQ-16 holds whether a sign-in can
stay out of the forge; OQ-17/18 set the ceiling of the threat model (2080-996d).

## Filed packets (40 new rows in 7 stories, plus this triage row)

Credential findings are NOT refiled: they are in the credential audit order
2080-yvby (branch work/2080-yvby-credaudit, PR #1087, 19 packets) — root
token (2080-yvby, 2080-u6nm), one Vault module (2080-dy3a), router socket
(2080-jmve), forge policies cannot write sign-ins (2080-7euu, which covers
judge 2 G3), 0444 files (2080-fqvh), host push (2080-swqp), proxy CA key
(2080-m3kw), silent wipe (2080-i4ga), debug flags (2080-363e), census
(2080-xz8m, which covers judge 1 #10 and judge 2 G6), and the rest.
Level-5 grader items are in 2080-3tzc (PR #1086).

**blind-sec-v05 (6)** — 2080-2wwn per-project forge+mirror network (High,
p1); 2080-4m4j podman-secrets-migration change vs no-plaintext ruling;
2080-73qx digest-pinned bases; 2080-7pa3 attached-session logs die with the
forge; 2080-8mc8 installers verify the cosign bundle (after 1068-phrh);
2080-996d threat model with boundary→check lint.

**idle-floor-v05 (9)** — 2080-9ijy periodic-wakeup inventory + check (p1);
2080-9wex memory_stall_watch on a PSI trigger (p1); 2080-a9tb lane-freshness
and PTY heartbeat off fixed cadences; 2080-anej / 2080-ari8 / 2080-bbuu idle
measurement on Linux / macOS / Windows (p1); 2080-bd3f service catalog states
obligation, start and idle cost; 2080-dunr / 2080-g4ru macOS guest / Windows
distro stop when idle.

**forge-events-v05 (6)** — 2080-g7gw agent wait + un-ignore the 1779-sq9g
fixtures (p1); 2080-gqc4 cursor with gap + snapshot; 2080-hpys max_tokens on
every read; 2080-hrvi one status tool with retry_after_s (v0.6); 2080-i5qu
models by digest from a register, read-only mount (v0.6); 2080-ipyz tray lists
sign-ins restored into each forge (v0.6, OQ-16).

**footprint-hygiene-v05 (8)** — 2080-iseg images shell line floor (25,363);
2080-jjaz repository shell line floor (210,639); 2080-jw9m three studio
Python files ported or waived; 2080-kkki cheatsheets without provenance error
+ staleness label; 2080-kmbn wsl-bash.md stops prescribing podman machine;
2080-mcws dead tillandsias-logging modules (v0.6); 2080-n2ge decision prebuilt
images vs local build (v0.6); 2080-nrgw blind exercises start clean (v0.6).

**licence-in-repo-v05 (3)** — 2080-qqsm gate reads committed records (p1);
2081-qndc history-anchored signature verification (p1); 2080-ryc8 migration
of state-dir records.

**floor-capability-v05 (5)** — 2080-u86h / 2080-ugz6 / 2080-w2ni RAM +
accelerator probe with one plain warning below the floor on Linux / macOS /
Windows (p1, reuses accel_probe); 2080-wc2c inference off by default below
the floor; 2080-wf7p agent on-demand start with a performance warning. Linked:
1957-emar (GPU arbiter), 483, 543, 657-s6g8, 657-zm2n, 793-ee2g, 802-2536.

**forge-safety-v05 (3)** — from the 2026-11-11 incident where a rotation ran
--stop-all and --reset-guest over a live visual-chess forge: 2080-xydi
stop-all/reset name live agents and unpushed commits and refuse without
consent (p1); 2080-ybu9 unpushed refs and transcripts survive a guest reset
(p1); 2081-877k launcher passes --name, --remote-control, --continue/--resume
to Claude.

Every exit criterion is written to fail on today's code; implementations are
Lua, Rust or Go.

## Reprioritised / annotated existing rows

| Row | Change |
|---|---|
| 1068-phrh installer skips verification (incl. missing SHA256SUMS) | p2 → p1 |
| 588-8mh8 cheatsheet provenance unverified | → p1; child 2080-kkki |
| 451 authenticated forge write transport | note: land 2080-2wwn first; credential side in 2080-yvby |
| 1252-qyii SELinux enforcement vs label=disable mandate | note: reconcile before pickup (label=disable is in 2080-yvby scope) |
| 590-z3jh credential audit milestone | note: judge 2 §3 is the map; instrument is 2080-xz8m |
| 1779-sq9g forge diagnostics scope | note: reads implemented but fixtures still ignored, 0/7 tasks |
| 1438-pk9j one storage root | note: live host has five roots |
| 1958-fc3y state-dir licence copy | note: superseded by the in-repo licence change |

## Deliberately not filed

- The "rotate what the audit printed" action (intermediate CA key, one mirror
  AppRole secret_id): an operator/credential-auditor action, not a packet.
- Every credential item listed above (owned by 2080-yvby).
- Judge 1 #16 one storage root: already 1438-pk9j (and 1874-a8nr on Windows).
- Judge 2 table rows 972-umik and 578: kept as they are, no change.
- OQ-dependent work whose scope is undecided (Vault audit retention, OQ-6;
  gateway sign-ins, OQ-16) beyond the rows above.
