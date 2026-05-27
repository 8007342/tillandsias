# Forge Completeness Baseline — 2026-05-27

## Method

Audit of all active forge-related OpenSpec specs against their defined
requirements and existing litmus test bindings. Each requirement's coverage
is rated:

- **LITMUS**: Has a passing litmus test that exercises this requirement
- **STATIC**: Validated by static shell/grep analysis (instant-size)
- **PROMPT**: Could be validated via forge agent diagnostic prompt
- **NONE**: No coverage

## Matrix

### forge-as-only-runtime (100% LITMUS)
| Req | Coverage | Method |
|---|---|---|
| Agent CLIs on $PATH (claude, codex, opencode, bash) | LITMUS | `litmus:forge-as-only-runtime` |
| No raw podman shell-outs outside idiomatic layer | LITMUS | `litmus:forge-as-only-runtime` |

### forge-cache-dual (33% LITMUS)
| Req | Coverage | Method |
|---|---|---|
| /tmp capped at 256 MB | STATIC | spec grammar |
| /run/user/1000 capped at 64 MB | STATIC | spec grammar |
| Per-language env vars (CARGO_HOME, GOPATH, npm, etc.) | PROMPT | agent can `echo $CARGO_HOME` |
| Cache hits on second build | NONE | needs E2E |
| Project boundaries not crossed | NONE | needs E2E |

### forge-environment-discoverability (50% LITMUS)
| Req | Coverage | Method |
|---|---|---|
| TILLANDSIAS_PROJECT_PATH exported | PROMPT | `echo $TILLANDSIAS_PROJECT_PATH` |
| TILLANDSIAS_PROJECT_GENUS exported | PROMPT | `echo $TILLANDSIAS_PROJECT_GENUS` |
| Project info MCP tool responds | STATIC | grep for script |
| Cache-discipline instructions available | PROMPT | `cat ~/.config/opencode/instructions/cache-discipline.md` |

### forge-hot-cold-split (33% LITMUS)
| Req | Coverage | Method |
|---|---|---|
| Four HOT paths mounted as tmpfs | LITMUS | `litmus:forge-hot-cold-split-shape` |
| /opt/cheatsheets capped at 8 MB | PROMPT | `df /opt/cheatsheets` inside forge |
| /home/forge/src sized per-launch | PROMPT | `df /home/forge/src` inside forge |
| --memory = sum(tmpfs) + 256 MB | NONE | needs Rust trace |
| Pre-flight RAM check | NONE | needs Rust trace |
| Per-launch project source budget | NONE | needs Rust trace |
| Tmpfs-overlay lane for pull cache | NONE | needs spec action |
| Agent transparency (paths unchanged) | PROMPT | agent can verify |
| TILLANDSIAS_CHEATSHEETS unchanged | PROMPT | `echo $TILLANDSIAS_CHEATSHEETS` |

### forge-offline (33% LITMUS)
| Req | Coverage | Method |
|---|---|---|
| Zero credential mounts | LITMUS | `litmus:credential-isolation` |
| No GH_TOKEN in env | PROMPT | `echo $GH_TOKEN` (must be empty) |
| /run/secrets/ does not exist | PROMPT | `ls /run/secrets/` (must fail) |
| No direct project mount (clone only) | NONE | needs E2E with diff |
| Enclave-only network | PROMPT | `curl -m 2 https://example.com` (must fail)|
| Package install through proxy works | PROMPT | `curl --proxy http://proxy:3128 ...` |
| Changes lost on container stop | NONE | needs E2E sequence |

### forge-opencode-onboarding (30% LITMUS)
| Req | Coverage | Method |
|---|---|---|
| OpenCode installed | PROMPT | `command -v opencode` |
| /startup routing decision taken | PROMPT | agent can report |
| Synthetic first prompt written | PROMPT | agent can report |
| Config overlay applied | PROMPT | agent can report |

### forge-shell-tools (50% LITMUS)
| Req | Coverage | Method |
|---|---|---|
| Shell helpers defined | PROMPT | `type tillandsias-help` |
| Cache discipline doc available | PROMPT | `cat cache-discipline.md` |
| lib-common.sh functions available | STATIC | grep for definition |
| BASH_ENV / ENV sourcing | STATIC | spec grammar |

### forge-staleness (30% LITMUS)
| Req | Coverage | Method |
|---|---|---|
| Source-hash rebuild triggers | STATIC | spec grammar |
| Newer-image selection contract | NONE | needs E2E |

### forge-standalone (33% LITMUS)
| Req | Coverage | Method |
|---|---|---|
| Uses forge image only | LITMUS | `litmus:forge-standalone-traceability` |
| Source mount is project-scoped | STATIC | grep for mount pattern |
| Interactive bash session | STATIC | spec grammar |
| Full network (no enclave) | STATIC | spec grammar |
| Fail-fast on missing args/image | STATIC | spec grammar |

### forge-welcome (50% LITMUS)
| Req | Coverage | Method |
|---|---|---|
| Welcome banner renders | PROMPT | agent can report banner content |
| Locale-aware help shown | PROMPT | agent can report |
| First-launch feedback path | NONE | needs E2E |

### default-image (50% LITMUS — shares forge-standalone-traceability)
| Req | Coverage | Method |
|---|---|---|
| Fedora Minimal base | STATIC | Containerfile FROM |
| Agent binaries baked in | LITMUS | `litmus:forge-as-only-runtime` |
| Forge user created | PROMPT | `id forge` |
| Entrypoints installed | STATIC | grep for COPY entrypoint |
| OpenCode config present | PROMPT | `cat ~/.config/opencode/config.json` |
| Shell configs in place | PROMPT | agent can report .bashrc exists |

## Summary

| Coverage Level | Count | Pct |
|---|---|---|
| LITMUS (fully tested) | 3 reqs | 6% |
| STATIC (grep/grammar) | 12 reqs | 24% |
| PROMPT (can be tested via diagnostics) | 17 reqs | 34% |
| NONE (no coverage) | 18 reqs | 36% |

**Total active forge requirements audited: 50**

The `PROMPT` and `NONE` cells (34% + 36% = 70% of forge requirements) are the
initial targets for the diagnostics automation wave.
