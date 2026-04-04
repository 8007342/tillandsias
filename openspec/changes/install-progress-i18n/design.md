## Context

Container entrypoint scripts run tool installations (npm install for openspec/claude, curl for opencode) with no visible progress. The i18n locale system exists (`lib-common.sh` loads `L_*` variables from `/etc/tillandsias/locales/<lang>.sh`) but entrypoints still use hardcoded English strings. The Containerfile only copies en.sh and es.sh, so German and other locales are missing at runtime.

## Goals / Non-Goals

**Goals:**
- Visible progress during all install operations (spinner with i18n status text)
- All user-facing entrypoint strings use `L_*` locale variables
- All available locale files deployed in container image
- Rust-side "Remote Projects" menu label uses i18n

**Non-Goals:**
- Adding new locale translations beyond en/es/de (stubs remain stubs)
- Changing npm/curl install mechanisms themselves
- Adding progress bars with download percentages (spinner is sufficient)
- Overhauling the i18n system architecture

## Decisions

### 1. Inline bash spinner, no npm dependency

Use a pure-bash background spinner function in `lib-common.sh`. The spinner runs as a background process, writes to stderr, and is killed when the wrapped command finishes.

**Why not an npm package?** The spinner runs *during* npm install — npm isn't available yet. A bash spinner is zero-dependency and works in all container environments.

**Pattern:**
```bash
spin() {
    local msg="$1"; shift
    local chars='⠋⠙⠹⠸⠼⠴⠦⠧⠇⠏'
    local pid
    ( while true; do
        for ((i=0; i<${#chars}; i++)); do
            printf '\r  %s %s' "${chars:$i:1}" "$msg" >&2
            sleep 0.1
        done
    done ) &
    pid=$!
    "$@" >/dev/null 2>&1
    local rc=$?
    kill "$pid" 2>/dev/null; wait "$pid" 2>/dev/null
    printf '\r\033[K' >&2
    return $rc
}
```

### 2. Forward progress for npm install (verbose mode)

For npm installs, use `spin "Installing..."` which hides npm's noisy output but shows the spinner. On failure, re-run without suppression so the user sees the error.

### 3. i18n string replacement — use existing L_ pattern

All hardcoded strings become `${L_SOME_KEY}` with fallback defaults via bash parameter expansion: `"${L_INSTALLING:-Installing...}"`. New keys added to en.sh, es.sh, de.sh.

### 4. Containerfile glob COPY for locales

Replace individual COPY lines with `COPY locales/ /etc/tillandsias/locales/` to deploy all locale files automatically.

## Risks / Trade-offs

- [Spinner on non-TTY] → Check `[ -t 2 ]` before starting spinner; fall back to simple "Installing..." message for non-interactive contexts.
- [Background process cleanup] → Use trap to ensure spinner PID is killed on script exit.
- [Locale file size] → Negligible; all 17 locale files total <20KB.
