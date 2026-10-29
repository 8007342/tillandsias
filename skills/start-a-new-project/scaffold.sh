#!/usr/bin/env bash
# scaffold.sh — set up a brand-new project: specs, a plan folder, a README.
#
# Usage: scaffold.sh --name "<App Name>" --summary "<one sentence>"
#                    [--stack flutter|flutter-flame|web|other] [--no-specs]
#                    [--dir <project root>]
#                    [--deploy cloudflare|gcp-dockerfile|gcp-buildpacks|none]
#                    [--runtime node|python|go|static] [--port <n>]
#
# Creates only what is missing and never overwrites an existing file. Prints
# one line per path it created or kept, then ok:scaffold:<created count>.
# Exit 2 on a usage error.
#
# @trace spec:project-bootstrap-readme
set -euo pipefail

name="" summary="" stack="other" specs=1 dir="." deploy="" runtime="" port="8080"
while [ $# -gt 0 ]; do
    case "$1" in
        --name) name="${2:-}"; shift 2 ;;
        --summary) summary="${2:-}"; shift 2 ;;
        --stack) stack="${2:-}"; shift 2 ;;
        --no-specs) specs=0; shift ;;
        --dir) dir="${2:-}"; shift 2 ;;
        --deploy) deploy="${2:-}"; shift 2 ;;
        --runtime) runtime="${2:-}"; shift 2 ;;
        --port) port="${2:-}"; shift 2 ;;
        *) echo "usage: scaffold.sh --name <name> --summary <sentence> [--stack flutter|flutter-flame|web|other] [--no-specs] [--dir <root>] [--deploy cloudflare|gcp-dockerfile|gcp-buildpacks|none] [--runtime node|python|go|static] [--port <n>]" >&2; exit 2 ;;
    esac
done
if [ -z "$name" ] || [ -z "$summary" ]; then
    echo "usage: scaffold.sh --name <name> --summary <sentence> [--stack ...] [--no-specs] [--dir <root>]" >&2
    exit 2
fi
case "$stack" in flutter|flutter-flame|web|other) ;; *) echo "unknown --stack: $stack" >&2; exit 2 ;; esac
if [ -z "$deploy" ]; then case "$stack" in web|flutter) deploy=cloudflare ;; *) deploy=none ;; esac; fi
case "$deploy" in cloudflare|gcp-dockerfile|gcp-buildpacks|none) ;; *) echo "unknown --deploy: $deploy" >&2; exit 2 ;; esac
case "$runtime" in ""|node|python|go|static) ;; *) echo "unknown --runtime: $runtime" >&2; exit 2 ;; esac
case "$port" in ''|*[!0-9]*) echo "--port must be a number: $port" >&2; exit 2 ;; esac
[ -d "$dir" ] || { echo "no such directory: $dir" >&2; exit 2; }
templates="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/templates"
cd "$dir"

# The app's runtime, when not given: from the project's own files, then the stack.
if [ -z "$runtime" ]; then
    if [ -f package.json ]; then runtime=node
    elif [ -f requirements.txt ] || [ -f pyproject.toml ]; then runtime=python
    elif [ -f go.mod ]; then runtime=go
    elif [ -f pubspec.yaml ] || [ "$stack" = flutter ] || [ "$stack" = flutter-flame ]; then runtime=static
    else runtime=node
    fi
fi
case "$runtime" in node) gcp_runtime=nodejs ;; *) gcp_runtime="$runtime" ;; esac

# Refuse an impossible deploy target before creating anything.
case "$deploy:$runtime" in
    gcp-buildpacks:static)
        echo "Google Cloud's buildpacks cannot serve a static or Flutter web app yet; use --deploy gcp-dockerfile." >&2
        exit 3 ;;
esac

created=0
# write_new <path> — writes stdin to <path> only when the path does not exist.
write_new() {
    local path="$1"
    if [ -e "$path" ] || [ -L "$path" ]; then
        cat >/dev/null
        echo "kept: $path"
        return 0
    fi
    mkdir -p "$(dirname "$path")"
    cat >"$path"
    echo "created: $path"
    created=$((created + 1))
}

case "$stack" in
    flutter) stack_line="Flutter (one codebase for web, mobile and desktop)." ;;
    flutter-flame) stack_line="Flutter with the Flame engine (games and graphics)." ;;
    web) stack_line="A web app." ;;
    *) stack_line="To be decided." ;;
esac

slug="$(printf '%s' "$name" | tr '[:upper:]' '[:lower:]' | tr -cs 'a-z0-9' '-' | sed 's/^-*//; s/-*$//')"
[ -n "$slug" ] || slug="app"

write_new README.md <<EOF
# $name

$summary

## Stack

$stack_line

## How this project is organised

- \`openspec/\`: what the app should do, written as short specs. Change the
  specs first, then the code.
- \`plan/\`: work that takes more than one session. Each line says what is left.
- \`research/\`: what is known about how people use apps like this, with sources.
EOF

if [ "$specs" -eq 1 ]; then
    if [ ! -d openspec ] && command -v openspec >/dev/null 2>&1; then
        # The CLI sets up its own folders and commands; tolerate its absence or
        # failure, the files below are enough to start.
        openspec init </dev/null >/dev/null 2>&1 || true
    fi
    write_new openspec/project.md <<EOF
# $name

$summary

## Stack

$stack_line
EOF
    write_new "openspec/specs/$slug/spec.md" <<EOF
# $name

## Purpose

$summary

## Requirements

### Requirement: The first version runs

The app SHALL start and show its first screen.

#### Scenario: opening the app

- **WHEN** the user opens the app
- **THEN** its first screen appears
EOF
fi

write_new plan/README.md <<'EOF'
# Plan

Work that takes more than one session lives here, so the next session (or
another helper) can pick it up.

- `roadmap.md`: one line per piece of work, saying what is LEFT to do.
  Update the line at the end of each session; delete it when it is done.
EOF

write_new plan/roadmap.md <<EOF
# Roadmap

- [ ] Build the first version of $name that runs and shows its first screen.
EOF

# spec:research-records — the project's own research store, same format as
# the shared library at \$TILLANDSIAS_RESEARCH (/opt/research).
write_new research/README.md <<'EOF'
# Research

What is known about how people use things like this app, kept next to the
code so decisions carry their reasons.

- One file per finding: `research/<domain>/<slug>.md`, copied from the
  shared library (`$TILLANDSIAS_RESEARCH`, `/opt/research`) or written with
  the `find-research` skill from its `TEMPLATE.md`. Every file names its
  source, an archived copy of it, and how strong the evidence is.
- Cite a finding as `research:<domain>/<slug>` in specs, code comments and
  commit trailers (`Research: <domain>/<slug>`); see the `cite-research`
  skill.
- Downloaded papers and pages do not live here; they go in the cache layer.
EOF

# render <template> <path> — fills {{NAME}} {{SLUG}} {{PORT}} {{RUNTIME}} and
# writes the result only when <path> does not exist.
render() {
    local text
    text="$(cat "$templates/$1")"
    text="${text//\{\{NAME\}\}/$name}"
    text="${text//\{\{SLUG\}\}/$slug}"
    text="${text//\{\{PORT\}\}/$port}"
    text="${text//\{\{RUNTIME\}\}/$gcp_runtime}"
    text="${text//\{\{COMPAT_DATE\}\}/$compat_date}"
    write_new "$2" <<<"$text"
}
# Today's date, from bash itself: the skill's own test runs with a bare PATH.
printf -v compat_date '%(%Y-%m-%d)T' -1

case "$deploy" in
    cloudflare)
        if [ "$stack" = flutter ]; then
            render cloudflare/wrangler.spa.jsonc wrangler.jsonc
        else
            render cloudflare/wrangler.static.jsonc wrangler.jsonc
            render cloudflare/index.html public/index.html
        fi
        render cloudflare/dev.vars.example .dev.vars.example
        # Local-only settings never reach git; an existing line is left alone.
        if [ ! -f .gitignore ]; then
            write_new .gitignore <<<".dev.vars"
        elif ! grep -qx '.dev.vars' .gitignore; then
            printf '.dev.vars\n' >>.gitignore
            echo "updated: .gitignore"
        fi
        ;;
    gcp-dockerfile)
        render "gcp/Dockerfile.$runtime" Dockerfile
        render gcp/dockerignore .dockerignore
        [ "$runtime" = static ] && render gcp/nginx.conf.template nginx.conf.template
        render gcp/cloudbuild.yaml cloudbuild.yaml
        render gcp/service.yaml service.yaml
        ;;
    gcp-buildpacks)
        render gcp/project.toml project.toml
        render gcp/service.yaml service.yaml
        ;;
esac

echo "ok:scaffold:$created"
