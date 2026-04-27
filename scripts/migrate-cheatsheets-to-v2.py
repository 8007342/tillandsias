#!/usr/bin/env python3
# migrate-cheatsheets-to-v2.py — one-shot migration of every legacy cheatsheet
# under cheatsheets/ to the v2 frontmatter schema (cheatsheets-license-tiered).
#
# Behavior:
#   - Skips INDEX.md, TEMPLATE.md, license-allowlist.toml.
#   - Skips cheatsheets that already have `tier:` set in frontmatter.
#   - For each remaining cheatsheet:
#       1. Parse existing frontmatter (if any) and body.
#       2. Collect URLs from frontmatter `sources:` AND from `## Provenance` body URLs.
#       3. Look up each URL's domain in cheatsheets/license-allowlist.toml; the strongest
#          tier wins (bundled > pull-on-demand) so a cheatsheet stays bundled if at least
#          one source is redistributable.
#       4. Add v2 fields: tier, summary_generated_by, bundled_into_image,
#          committed_for_project. For pull-on-demand: also pull_recipe.
#       5. Bump last_verified to 2026-04-27 (migration date).
#       6. For pull-on-demand: append a ## Pull on Demand stub before ## See also.
#       7. For files with no frontmatter: synthesise minimal v2 frontmatter from body.
#
# @trace spec:cheatsheets-license-tiered
# @cheatsheet runtime/cheatsheet-tier-system.md, runtime/cheatsheet-frontmatter-spec.md

from __future__ import annotations

import re
import sys
from pathlib import Path
from typing import Optional
from urllib.parse import urlparse

REPO_ROOT = Path(__file__).resolve().parent.parent
CHEATSHEETS_DIR = REPO_ROOT / "cheatsheets"
ALLOWLIST_TOML = CHEATSHEETS_DIR / "license-allowlist.toml"
MIGRATION_DATE = "2026-04-27"
LEGACY_SINCE = "2026-04-25"

SKIP_NAMES = {"INDEX.md", "TEMPLATE.md"}


# ----- allowlist parsing ---------------------------------------------------

def load_allowlist() -> dict[str, str]:
    """Return mapping of domain (or domain/path-prefix) -> default_tier."""
    text = ALLOWLIST_TOML.read_text(encoding="utf-8")
    out: dict[str, str] = {}
    current_domain: Optional[str] = None
    for line in text.splitlines():
        s = line.strip()
        if s.startswith("#") or not s:
            continue
        m = re.match(r'^\[domains\."([^"]+)"\]', s)
        if m:
            current_domain = m.group(1)
            continue
        if current_domain is None:
            continue
        m = re.match(r'^default_tier\s*=\s*"([^"]+)"', s)
        if m:
            out[current_domain] = m.group(1)
            current_domain = None
    return out


ALLOWLIST = load_allowlist()


def classify_url(url: str) -> str:
    """Return the tier for a single URL based on the allowlist."""
    try:
        parsed = urlparse(url)
    except ValueError:
        return "pull-on-demand"
    host = (parsed.netloc or "").lower()
    path = parsed.path or ""
    # First try domain + leading path-prefix entries (e.g. raw.githubusercontent.com/ollama/ollama).
    # Build candidate keys longest-first.
    candidates: list[str] = []
    if host and path:
        # Try host + first 2 path segments, then 1, then host alone.
        segs = [seg for seg in path.split("/") if seg]
        for n in (2, 1):
            if len(segs) >= n:
                candidates.append(f"{host}/{'/'.join(segs[:n])}")
    if host:
        candidates.append(host)
    for k in candidates:
        if k in ALLOWLIST:
            return ALLOWLIST[k]
    # Off-allowlist => safe default
    return "pull-on-demand"


def classify_cheatsheet(urls: list[str]) -> str:
    """Pick the tier across all URLs for one cheatsheet.

    Bundled wins over pull-on-demand: if the cheatsheet has at least one
    redistributable source, the cheatsheet itself can be bundled (the
    pull-on-demand sources merely become the parts requiring runtime fetch
    if the agent needs depth — but the curated summary is always shippable).
    """
    if not urls:
        return "pull-on-demand"
    tiers = {classify_url(u) for u in urls}
    if "bundled" in tiers:
        return "bundled"
    if "distro-packaged" in tiers:
        return "distro-packaged"
    return "pull-on-demand"


# ----- frontmatter + body parsing -----------------------------------------

FM_DELIM = "---\n"


def split_frontmatter(text: str) -> tuple[Optional[str], str]:
    """Return (frontmatter_block_without_delims, body) or (None, text)."""
    if not text.startswith(FM_DELIM):
        return None, text
    end = text.find("\n" + FM_DELIM, len(FM_DELIM))
    if end < 0:
        return None, text
    fm = text[len(FM_DELIM):end]
    body = text[end + len("\n" + FM_DELIM):]
    return fm, body


def fm_has_field(fm: str, field: str) -> bool:
    return re.search(rf"^{re.escape(field)}\s*:", fm, re.MULTILINE) is not None


def fm_get_sources(fm: str) -> list[str]:
    """Extract URLs from a YAML `sources:` block."""
    out: list[str] = []
    in_sources = False
    for line in fm.splitlines():
        if re.match(r"^sources\s*:", line):
            in_sources = True
            continue
        if in_sources:
            stripped = line.lstrip()
            if line.startswith(" ") or line.startswith("\t"):
                # Item line like "  - https://..."
                m = re.match(r"^-\s*(\S+)", stripped)
                if m:
                    out.append(m.group(1))
                    continue
                # Continuation/blank within block: keep going
                if not stripped:
                    continue
                # Anything else within indented block: stop
                continue
            else:
                # Left-justified line ends the block
                in_sources = False
    return out


URL_RE = re.compile(r"https?://[^\s)>\]]+")


def body_extract_provenance_urls(body: str) -> list[str]:
    """Find the ## Provenance section and harvest URLs."""
    m = re.search(r"^##\s+Provenance\s*$", body, re.MULTILINE)
    if not m:
        # Some cheatsheets use a different heading; fall back to scanning the
        # first 60 lines for URLs.
        head = "\n".join(body.splitlines()[:60])
        return _dedupe(URL_RE.findall(head))
    start = m.end()
    # End at next heading of same depth or higher
    rest = body[start:]
    end_m = re.search(r"^##\s+\S", rest, re.MULTILINE)
    section = rest[: end_m.start()] if end_m else rest
    urls = URL_RE.findall(section)
    # Strip trailing punctuation that the URL_RE may have caught
    urls = [u.rstrip(".,;:>") for u in urls]
    return _dedupe(urls)


def _dedupe(seq: list[str]) -> list[str]:
    seen: set[str] = set()
    out: list[str] = []
    for x in seq:
        if x not in seen:
            seen.add(x)
            out.append(x)
    return out


# ----- placeholder URL hints for stubbed cheatsheets ----------------------
# When a cheatsheet has no frontmatter AND no URLs in its body, we still need
# at least one URL to make the pull-on-demand stub meaningful. These hints
# map cheatsheet basenames (without .md) to a high-authority canonical URL.
PLACEHOLDER_HINTS: dict[str, str] = {
    "git": "https://git-scm.com/docs",
    "jq": "https://jqlang.github.io/jq/manual/",
    "yq": "https://mikefarah.gitbook.io/yq",
    "ripgrep": "https://github.com/BurntSushi/ripgrep/blob/master/GUIDE.md",
    "fd": "https://github.com/sharkdp/fd",
    "fzf": "https://github.com/junegunn/fzf",
    "gh": "https://cli.github.com/manual/",
    "rsync": "https://download.samba.org/pub/rsync/rsync.1",
    "ssh": "https://man.openbsd.org/ssh.1",
    "tree": "https://oldmanprogrammer.net/source.php?dir=projects/tree",
    "curl": "https://curl.se/docs/manpage.html",
    "shellcheck-shfmt": "https://www.shellcheck.net/wiki/",
    "tar": "https://www.gnu.org/software/tar/manual/tar.html",
    "bash": "https://www.gnu.org/software/bash/manual/bash.html",
    "css": "https://developer.mozilla.org/en-US/docs/Web/CSS",
    "dart": "https://dart.dev/guides",
    "html": "https://html.spec.whatwg.org/multipage/",
    "java": "https://docs.oracle.com/en/java/javase/21/docs/api/",
    "javascript": "https://developer.mozilla.org/en-US/docs/Web/JavaScript",
    "json": "https://www.json.org/json-en.html",
    "markdown": "https://spec.commonmark.org/",
    "python": "https://docs.python.org/3/",
    "rust": "https://doc.rust-lang.org/book/",
    "sql": "https://www.postgresql.org/docs/current/sql.html",
    "toml": "https://toml.io/en/v1.0.0",
    "typescript": "https://www.typescriptlang.org/docs/handbook/intro.html",
    "xml": "https://www.w3.org/TR/xml/",
    "yaml": "https://yaml.org/spec/1.2.2/",
    "go": "https://go.dev/doc/",
    "gradle": "https://docs.gradle.org/current/userguide/userguide.html",
    "make": "https://www.gnu.org/software/make/manual/make.html",
    "maven": "https://maven.apache.org/guides/index.html",
    "ninja": "https://ninja-build.org/manual.html",
    "npm": "https://docs.npmjs.com/cli/v10",
    "pip": "https://pip.pypa.io/en/stable/cli/",
    "pipx": "https://pipx.pypa.io/stable/",
    "pnpm": "https://pnpm.io/cli/install",
    "poetry": "https://python-poetry.org/docs/",
    "uv": "https://docs.astral.sh/uv/",
    "yarn": "https://yarnpkg.com/cli",
    "cargo-test": "https://doc.rust-lang.org/cargo/commands/cargo-test.html",
    "go-test": "https://pkg.go.dev/testing",
    "junit": "https://junit.org/junit5/docs/current/user-guide/",
    "playwright": "https://playwright.dev/docs/intro",
    "pytest": "https://docs.pytest.org/en/stable/",
    "selenium": "https://www.selenium.dev/documentation/",
    "flutter": "https://docs.flutter.dev/reference/flutter-cli",
}


# ----- frontmatter writing ------------------------------------------------

V2_TIER_BLOCK_HEADER = (
    "\n# v2 — tier classification (cheatsheets-license-tiered)\n"
)


def append_v2_fields(fm: str, tier: str) -> str:
    """Append the v2 tier fields to an existing frontmatter block.

    The existing block is preserved verbatim; the new fields are appended
    just before the closing `---`. We also bump `last_verified` to the
    migration date.
    """
    # Bump last_verified
    fm = re.sub(
        r"^(last_verified\s*:\s*).*$",
        rf"\g<1>{MIGRATION_DATE}",
        fm,
        count=1,
        flags=re.MULTILINE,
    )

    bundled_into_image = "true" if tier in ("bundled", "distro-packaged") else "false"

    extra = [V2_TIER_BLOCK_HEADER.rstrip()]
    extra.append(f"tier: {tier}")
    extra.append("summary_generated_by: hand-curated")
    extra.append(f"bundled_into_image: {bundled_into_image}")
    extra.append("committed_for_project: false")
    if tier == "pull-on-demand":
        extra.append("pull_recipe: see-section-pull-on-demand")

    return fm.rstrip() + "\n" + "\n".join(extra) + "\n"


def synthesise_frontmatter(path: Path, body: str, tier: str, urls: list[str]) -> str:
    """Build a minimal v2 frontmatter block for a file that has none."""
    bundled_into_image = "true" if tier in ("bundled", "distro-packaged") else "false"
    sources_lines: list[str]
    if urls:
        sources_lines = [f"  - {u}" for u in urls]
    else:
        sources_lines = ["  []  # TODO: cite real authoritative URL on next refresh"]
        # YAML list shorthand isn't valid like that; fix to a proper empty list
        sources_lines = []

    lines = [
        "---",
        "tags: []  # TODO: add 3-8 kebab-case tags on next refresh",
        "languages: []",
        f"since: {LEGACY_SINCE}",
        f"last_verified: {MIGRATION_DATE}",
    ]
    if sources_lines:
        lines.append("sources:")
        lines.extend(sources_lines)
    else:
        lines.append("sources: []  # TODO: cite real authoritative URL on next refresh")
    lines.append("authority: high")
    lines.append("status: current")
    lines.append("")
    lines.append("# v2 — tier classification (cheatsheets-license-tiered)")
    lines.append(f"tier: {tier}")
    lines.append("summary_generated_by: hand-curated")
    lines.append(f"bundled_into_image: {bundled_into_image}")
    lines.append("committed_for_project: false")
    if tier == "pull-on-demand":
        lines.append("pull_recipe: see-section-pull-on-demand")
    lines.append("---")
    lines.append("")
    return "\n".join(lines)


# ----- pull-on-demand stub generation ------------------------------------

def make_pull_on_demand_stub(rel_path: str, urls: list[str]) -> str:
    """Build the ## Pull on Demand section for a pull-on-demand cheatsheet."""
    primary = urls[0] if urls else "https://example.invalid/replace-me"
    parsed = urlparse(primary)
    host = parsed.netloc or "example.invalid"
    path = parsed.path.lstrip("/") or "index.html"

    # Best-effort license SPDX guess from allowlist (per-domain license_url
    # is in the TOML; we don't parse it here — we just cite the URL itself
    # and a generic placeholder. Authors will refine on next touch.)
    license_id = "see-license-allowlist"
    license_url = primary

    body = f"""## Pull on Demand

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
  - `{primary}`
- **Archive type:** `single-html`
- **Expected size:** `~1 MB extracted`
- **Cache target:** `~/.cache/tillandsias/cheatsheets-pulled/$PROJECT/{host}/{path}`
- **License:** {license_id}
- **License URL:** {license_url}

### Materialize recipe (agent runs this)

```bash
set -euo pipefail
TARGET="$HOME/.cache/tillandsias/cheatsheets-pulled/$PROJECT/{host}/{path}"
mkdir -p "$(dirname "$TARGET")"
curl --fail --silent --show-error \\
  "{primary}" \\
  -o "$TARGET"
```

### Generation guidelines (after pull)

1. Read the pulled file for the structure relevant to your project.
2. If the project leans on this tool/topic heavily, generate a project-contextual
   cheatsheet at `<project>/.tillandsias/cheatsheets/{rel_path}` using
   `cheatsheets/TEMPLATE.md` as the skeleton.
3. The generated cheatsheet MUST set frontmatter:
   `tier: pull-on-demand`, `summary_generated_by: agent-generated-at-runtime`,
   `committed_for_project: true`.
4. Cite the pulled source under `## Provenance` with `local: <cache target above>`.

"""
    return body


def insert_pull_on_demand(body: str, stub: str) -> str:
    """Insert stub before ## See also (or at end if absent).

    If the body already contains a `## Pull on Demand` heading, leave it alone.
    """
    if "## Pull on Demand" in body:
        return body
    m = re.search(r"^##\s+See also\s*$", body, re.MULTILINE)
    if m:
        return body[: m.start()] + stub + body[m.start():]
    # Else append at end (with a trailing newline guarantee)
    if not body.endswith("\n"):
        body += "\n"
    return body + "\n" + stub


# ----- driver --------------------------------------------------------------

def process_file(path: Path) -> Optional[tuple[str, str]]:
    """Process one cheatsheet. Returns (rel, tier) on migration, None on skip."""
    if path.name in SKIP_NAMES:
        return None
    rel = str(path.relative_to(CHEATSHEETS_DIR))
    text = path.read_text(encoding="utf-8")
    fm, body = split_frontmatter(text)

    if fm is not None and fm_has_field(fm, "tier"):
        # Already migrated (or hand-authored as v2). Skip.
        return None

    # Collect URLs
    fm_urls = fm_get_sources(fm) if fm else []
    body_urls = body_extract_provenance_urls(body)
    urls = _dedupe(fm_urls + body_urls)

    # If still nothing, fall back to a placeholder hint
    if not urls:
        stem = path.stem
        if stem in PLACEHOLDER_HINTS:
            urls = [PLACEHOLDER_HINTS[stem]]

    tier = classify_cheatsheet(urls)

    if fm is not None:
        new_fm = append_v2_fields(fm, tier)
        new_text = FM_DELIM + new_fm + FM_DELIM.replace("\n", "") + "\n" + body
        # Ensure delimiter is exactly "---\n"
        new_text = FM_DELIM + new_fm + "---\n" + body
    else:
        new_fm_block = synthesise_frontmatter(path, body, tier, urls)
        new_text = new_fm_block + body

    if tier == "pull-on-demand":
        # Build stub using the body section relative path so generation
        # guidelines suggest the right shadow location.
        new_body_marker = "---\n"
        idx = new_text.find(new_body_marker, len(FM_DELIM))
        if idx >= 0:
            after_fm_idx = idx + len(new_body_marker)
            new_body = new_text[after_fm_idx:]
            stub = make_pull_on_demand_stub(rel, urls)
            new_body = insert_pull_on_demand(new_body, stub)
            new_text = new_text[:after_fm_idx] + new_body

    path.write_text(new_text, encoding="utf-8")
    return rel, tier


def main() -> int:
    if not ALLOWLIST_TOML.exists():
        print(f"ERROR: allowlist not found at {ALLOWLIST_TOML}", file=sys.stderr)
        return 2

    migrated: list[tuple[str, str]] = []
    skipped = 0

    for path in sorted(CHEATSHEETS_DIR.rglob("*.md")):
        try:
            res = process_file(path)
        except Exception as e:
            print(f"FAIL {path.relative_to(CHEATSHEETS_DIR)}: {e}", file=sys.stderr)
            return 1
        if res is None:
            skipped += 1
        else:
            migrated.append(res)

    print(f"Migrated {len(migrated)} cheatsheets; skipped {skipped} (already-v2 or INDEX/TEMPLATE).")
    by_tier: dict[str, int] = {}
    for _, tier in migrated:
        by_tier[tier] = by_tier.get(tier, 0) + 1
    for tier in ("bundled", "distro-packaged", "pull-on-demand"):
        print(f"  {tier}: {by_tier.get(tier, 0)}")

    print("\nClassification CSV (rel,tier):")
    for rel, tier in migrated:
        print(f"{rel},{tier}")

    return 0


if __name__ == "__main__":
    sys.exit(main())
