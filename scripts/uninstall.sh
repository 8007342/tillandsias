#!/usr/bin/env bash
# Tillandsias Uninstaller
# @trace spec:app-lifecycle
# freshness: auditor=windows-yolanda-opus5-20260818t1119z date=2026-08-18 verdict=updated scope=standing FRESHNESS audit (top unstamped, seed=20260818). Still MEANINGFUL and USEFUL, and its destructive paths are SOUND (804-bpke seams keep the macOS arm testable without deleting a real binary; 804-wfcu documents the userdel -r overlap). NOT COMPLETE, and that is what was fixed: install.sh appends a MARKED PATH block to ~/.profile and ~/.bashrc, adds ~/.zprofile and ~/.zshrc under zsh, and writes ~/.config/fish/conf.d/tillandsias.fish outright — and this script removed none of them, so every uninstall left the shells exporting a PATH entry for a directory it had just deleted. The markers existed only for install-side idempotency and nothing ever used them for removal. Symmetric removal added with scripts/test-uninstall-path-block.sh 5/5. Cache coverage re-checked against this cycle's new capabilities.json artifact: already covered by CACHE_DIR under --wipe, no change needed.
set -euo pipefail

# Seams, for the fixture only (804-bpke). Both default to the shipped values, so
# a real uninstall is unchanged. They exist because this script removes paths
# OUTSIDE $HOME (/usr/local/bin) and branches on uname, so a test that could not
# redirect those two things would have to either skip the macOS arm or delete a
# real installed binary to run.
#
# 1181-bkem: TILLANDSIAS_RESET_KEEP_MODELS=1 is an opt-in, per-run environment
# flag. With --wipe, it spares $CACHE_DIR/models (the downloaded model cache)
# instead of deleting it with the rest of the cache; unset, --wipe is unchanged
# from before this flag existed. It never widens what --wipe alone would not
# already remove, and it is a documented no-op without --wipe.
_uname_s="${TILLANDSIAS_UNINSTALL_FAKE_UNAME:-$(uname -s)}"

IS_MACOS=false
if [[ "$_uname_s" == "Darwin" ]]; then
    IS_MACOS=true
    INSTALL_DIR="${TILLANDSIAS_UNINSTALL_INSTALL_DIR:-/usr/local/bin}"
    LIB_DIR="$HOME/Library/Application Support/tillandsias/lib"
    DATA_DIR="$HOME/Library/Application Support/tillandsias"
    CONFIG_DIR="$HOME/Library/Application Support/tillandsias"
    LOG_DIR="$HOME/Library/Logs/tillandsias"
    CACHE_DIR="$HOME/Library/Caches/tillandsias"
else
    INSTALL_DIR="$HOME/.local/bin"
    LIB_DIR="$HOME/.local/lib/tillandsias"
    DATA_DIR="$HOME/.local/share/tillandsias"
    CONFIG_DIR="$HOME/.config/tillandsias"
    LOG_DIR="$HOME/.local/state/tillandsias"
    CACHE_DIR="$HOME/.cache/tillandsias"
fi

SERVICE_USER="tillandsias"
SERVICE_GROUP="tillandsias"
SERVICE_HOME="/var/lib/tillandsias"
SYSTEMD_USER_UNIT_DIR="/etc/systemd/user"
SYSUSERS_DIR="/etc/sysusers.d"
TMPFILES_DIR="/etc/tmpfiles.d"
IS_ROOT=false
if [[ "${EUID:-$(id -u)}" -eq 0 ]]; then
    IS_ROOT=true
fi

WIPE=false
[[ "${1:-}" == "--wipe" ]] && WIPE=true

# 1181-bkem: opt-in, per-run, never the default. See the seams comment above.
KEEP_MODELS=false
[[ "${TILLANDSIAS_RESET_KEEP_MODELS:-}" == "1" ]] && KEEP_MODELS=true

echo ""
echo "  Tillandsias Uninstaller"
echo "  ======================"
echo ""

# ── Show what will be removed ──────────────────────────────────
echo "  Tillandsias will remove the following:"
echo ""
[ -f "$INSTALL_DIR/tillandsias" ] && echo "    - $INSTALL_DIR/tillandsias (app binary)"
[ -f "$INSTALL_DIR/tillandsias-uninstall" ] && echo "    - $INSTALL_DIR/tillandsias-uninstall (uninstaller)"
[ -d "$LIB_DIR" ] && echo "    - $LIB_DIR/ (libraries)"
# 804-bpke: on macOS DATA_DIR is the VM home and is preserved without --wipe,
# so it must not be listed as "will be removed" on that path — the preamble is
# the only warning the user gets, and there is no confirmation prompt.
if [[ "$IS_MACOS" == true && "$WIPE" != true ]]; then
    [ -d "$LOG_DIR" ] && echo "    - $LOG_DIR/ (logs)"
else
    [ -d "$DATA_DIR" ] && echo "    - $DATA_DIR/ (app data, including the VM image)"
    [ -d "$CONFIG_DIR" ] && echo "    - $CONFIG_DIR/ (settings)"
    [ -d "$LOG_DIR" ] && echo "    - $LOG_DIR/ (logs)"
fi
if [[ "$IS_ROOT" == true ]]; then
    [ -f "$SYSTEMD_USER_UNIT_DIR/tillandsias.service" ] && echo "    - $SYSTEMD_USER_UNIT_DIR/tillandsias.service (systemd user service)"
    [ -f "$SYSUSERS_DIR/tillandsias.conf" ] && echo "    - $SYSUSERS_DIR/tillandsias.conf (service account sysusers entry)"
    [ -f "$TMPFILES_DIR/tillandsias.conf" ] && echo "    - $TMPFILES_DIR/tillandsias.conf (service account tmpfiles entry)"
    # 804-wfcu: name the EXPENSIVE thing, not just the directory. Under the
    # packaged service account the headless resolves its model cache from its
    # process HOME (main.rs:4013), so the weights live at
    # $SERVICE_HOME/.cache/tillandsias/models and go with the home below. The
    # macOS half of this defect (804-bpke) measured 11.83 GiB reported as
    # "preserved"; the Linux half is the same sentence over a different
    # directory. Size it so the operator sees what they are about to lose.
    if [ -d "$SERVICE_HOME" ]; then
        _svc_models="$SERVICE_HOME/.cache/tillandsias/models"
        if [ -d "$_svc_models" ]; then
            _svc_models_size="$(du -sh "$_svc_models" 2>/dev/null | cut -f1)"
            echo "    - $SERVICE_HOME/ (service account home/state, INCLUDING the model cache: ${_svc_models_size:-unknown})"
        else
            echo "    - $SERVICE_HOME/ (service account home/state)"
        fi
    fi
    [ -f "/usr/local/bin/tillandsias" ] && echo "    - /usr/local/bin/tillandsias (system binary)"
fi
if [[ "$WIPE" == true ]]; then
    [ -d "$CACHE_DIR" ] && echo "    - $CACHE_DIR/ (cache)"
    echo "    - tillandsias-forge:* container images"
    echo "    - tillandsias-web:* container images"
fi
echo ""
echo "  Your project files will NOT be touched."
echo ""

# ── Remove binaries ───────────────────────────────────────────
rm -f "$INSTALL_DIR/tillandsias" "$INSTALL_DIR/tillandsias-uninstall"

# ── Remove bundled libraries ──────────────────────────────────
rm -rf "$LIB_DIR"

# ── Remove bundled data (flake, scripts, images) ──────────────
# Order 804-bpke. On LINUX the six directories above are six distinct XDG
# paths, and DATA_DIR really is bundled data (flake, scripts, images) — cheap
# to reinstall, correct to remove unconditionally. On macOS THREE OF THEM
# COLLAPSE ONTO ONE PATH: LIB_DIR is a subdirectory of DATA_DIR, CONFIG_DIR is
# byte-identical to it, and the same directory is where the VM lives —
# vz.rs's image_root, holding rootfs.img. So this one line, written for the
# Linux meaning, deleted the entire VM.
#
# Measured on a macOS dev host 2026-08-17: DATA_DIR 11.83 GiB actual
# (rootfs.img 11.33 GiB actual / 250 GiB apparent, sparse), against a
# CACHE_DIR of 8 KB. The script then printed "Cache preserved. Use --wipe to
# remove everything." — so the default path destroyed ~11.8 GiB and reported
# preservation, while opting in to "remove everything" added 8 KB. Re-creating
# it costs a ~2.47 GB mandatory re-download (ollama engine payload + model +
# Fedora base) before the guest can serve a token again.
#
# The default therefore preserves the VM on macOS and --wipe removes it, which
# is what the closing message has always promised. Linux behaviour is
# unchanged: there DATA_DIR holds no VM.
if [[ "$IS_MACOS" == true && "$WIPE" != true ]]; then
    echo "  Preserving the VM image in $DATA_DIR (use --wipe to remove it)."
else
    rm -rf "$DATA_DIR"
fi

# ── Remove settings ───────────────────────────────────────────
# On macOS CONFIG_DIR == DATA_DIR, so removing it unconditionally would undo
# the preservation above. Same guard, same reason.
if [[ "$IS_MACOS" == true && "$WIPE" != true ]]; then
    :
else
    rm -rf "$CONFIG_DIR"
fi

# ── Remove logs ───────────────────────────────────────────────
rm -rf "$LOG_DIR"

# ── Remove the shell PATH integration install.sh added ────────
#
# FRESHNESS AUDIT 2026-08-18 (order 372 class): install.sh appends a marked
# PATH block to ~/.profile and ~/.bashrc, adds ~/.zprofile and ~/.zshrc under
# zsh, and WRITES A WHOLE FILE at ~/.config/fish/conf.d/tillandsias.fish. This
# script removed none of them, so an uninstall left every shell still exporting
# a PATH entry for a directory it had just deleted, plus an orphan fish config.
#
# The markers exist precisely so the block can be found again — install.sh uses
# them for idempotency (it returns early when BEGIN is present) and nothing
# ever used them for removal. An installer that leaves a marker and an
# uninstaller that ignores it is a half-finished handshake, not a design.
#
# The strings MUST match install.sh's PATH_MARKER_BEGIN/END byte for byte.
PATH_MARKER_BEGIN="# >>> tillandsias PATH >>>"
PATH_MARKER_END="# <<< tillandsias PATH <<<"

# awk, not sed -i: this edits USER dotfiles that predate us and will outlive
# us, and `sed -i` on macOS takes a mandatory backup suffix that GNU sed does
# not, so the portable spelling is a temp file we control. Only the marked span
# is dropped; every other line is copied through byte for byte.
strip_path_block() {
    _spb_file="$1"
    [ -f "$_spb_file" ] || return 0
    grep -F "$PATH_MARKER_BEGIN" "$_spb_file" >/dev/null 2>&1 || return 0

    _spb_tmp="$_spb_file.tillandsias-uninstall.$$"
    if awk -v b="$PATH_MARKER_BEGIN" -v e="$PATH_MARKER_END" '
        index($0, b) == 1 { skip = 1; next }
        skip && index($0, e) == 1 { skip = 0; next }
        !skip { print }
    ' "$_spb_file" > "$_spb_tmp" 2>/dev/null; then
        # Preserve the original mode: a dotfile that comes back 0644 when it was
        # 0600 is a quiet permission downgrade on a file we were only editing.
        if command -v chmod >/dev/null 2>&1; then
            chmod --reference="$_spb_file" "$_spb_tmp" 2>/dev/null || true
        fi
        mv "$_spb_tmp" "$_spb_file"
        echo "  Removed PATH block from $_spb_file"
    else
        # NEVER leave a truncated dotfile behind. A failed rewrite must leave
        # the user's shell config exactly as it was.
        rm -f "$_spb_tmp"
        echo "  WARNING: could not edit $_spb_file; its PATH block was left in place" >&2
    fi
}

for _profile in "$HOME/.profile" "$HOME/.bashrc" "$HOME/.zprofile" "$HOME/.zshrc"; do
    strip_path_block "$_profile"
done

# The fish block lives in a file install.sh created outright, so removing the
# whole file is correct — but only if it is OURS. A user who put their own
# lines in it keeps the file and loses just the block.
FISH_CONF="$HOME/.config/fish/conf.d/tillandsias.fish"
if [ -f "$FISH_CONF" ]; then
    if [ -n "$(awk -v b="$PATH_MARKER_BEGIN" -v e="$PATH_MARKER_END" '
        index($0, b) == 1 { skip = 1; next }
        skip && index($0, e) == 1 { skip = 0; next }
        !skip && NF { print }
    ' "$FISH_CONF" 2>/dev/null)" ]; then
        strip_path_block "$FISH_CONF"
    else
        rm -f "$FISH_CONF"
        echo "  Removed $FISH_CONF"
    fi
fi

# ── Remove service account runtime ────────────────────────────
if [[ "$IS_ROOT" == true ]]; then
    if command -v runuser >/dev/null 2>&1; then
        SERVICE_UID="$(id -u "$SERVICE_USER" 2>/dev/null || echo "")"
        if [[ -n "$SERVICE_UID" ]]; then
            runuser -u "$SERVICE_USER" -- env HOME="$SERVICE_HOME" XDG_RUNTIME_DIR="/run/user/$SERVICE_UID" \
                systemctl --user disable --now tillandsias.service podman.socket 2>/dev/null || true
        fi
    fi
    loginctl disable-linger "$SERVICE_USER" 2>/dev/null || true
fi

# ── Remove service-account unit files and policy ──────────────
if [[ "$IS_ROOT" == true ]]; then
    rm -f "$SYSTEMD_USER_UNIT_DIR/tillandsias.service"
    rm -f "$SYSUSERS_DIR/tillandsias.conf"
    rm -f "$TMPFILES_DIR/tillandsias.conf"
fi

# ── Linux desktop cleanup ─────────────────────────────────────
rm -f "$HOME/.local/share/applications/tillandsias.desktop"
rm -f "$HOME/.local/share/icons/hicolor/32x32/apps/tillandsias.png"
rm -f "$HOME/.local/share/icons/hicolor/128x128/apps/tillandsias.png"
rm -f "$HOME/.local/share/icons/hicolor/256x256/apps/tillandsias.png"
rm -f "$HOME/.config/autostart/tillandsias.desktop"
update-desktop-database "$HOME/.local/share/applications" 2>/dev/null || true

# ── macOS desktop cleanup ─────────────────────────────────────
# Stop the tray FIRST. install-macos.sh already does this before it replaces
# the bundle; the uninstaller did not, so `uninstall` left the tray running
# from a bundle that no longer exists — menu bar icon still there, still
# OWNING THE VM, surviving until logout, on a machine the user believes they
# have uninstalled from. Verified live on tlatoanis-macbook-air 2026-08-30:
# pid alive 12m after a "complete" uninstall with its bundle deleted.
# Same two-stage stop as the installer, and the same tolerance of absence.
#
# ── ORDER 1231-cbie: THE GUARD THIS HEADING ALREADY CLAIMED ──────────────────
#
# This block sat at COLUMN 0 under a "macOS desktop cleanup" heading, four lines
# after an unconditional LINUX cleanup block — so the heading read as scope and
# was not one. It ran on EVERY platform, and uninstall.sh is a SHIPPED RELEASE
# ARTIFACT (release.yml installs it and asserts it is present), so the reach was
# every machine that installs a release and later uninstalls.
#
# WHY THAT MATTERED ON LINUX SPECIFICALLY: there is no `tillandsias-tray`
# process here. The launcher is `tillandsias`. So every match `-f` could produce
# on a Linux host was a FALSE one — an editor, a grep, a CI shell, or the agent
# command running the uninstall — and the ladder then sent it SIGTERM and
# SIGKILL. scripts/e2e-preflight.sh condemns this exact form by name, with a
# measurement: its own first draft "reported PRESENT against its own invoking
# shell". That warning never travelled the two files to here.
#
# THE MATCHER IS NOW `-x`, MEASURED ON DARWIN 2026-09-17 (1231-cbie, second
# half). `-f` matches a COMMAND LINE, so it killed anything merely mentioning
# the string; `-x` matches the EXECUTABLE NAME exactly.
#
# The three facts a Linux host could not establish, each measured here:
#   1. CFBundleExecutable is `tillandsias-tray` and CFBundleName is
#      `Tillandsias`, so they DIFFER — a matcher keyed on the bundle name
#      would have matched nothing at all.
#   2. `tillandsias-tray` is exactly 16 characters, historically MAXCOMLEN on
#      BSD, so `-x` was not obviously safe. It is: `ps -o comm=` reports the
#      full path untruncated and `pgrep -x tillandsias-tray` matches it.
#   3. The collateral damage is real and `-x` removes it. With a live decoy
#      named `tillandsias-tray` and an innocent `tail -f .../tillandsias-tray.log`
#      running alongside, `pgrep -f` returned BOTH pids and `pgrep -x` returned
#      only the decoy. Under the old form that `tail` got SIGTERM then SIGKILL.
#
# THE TWO-STAGE STOP IS DELIBERATELY KEPT, not collapsed: a tray was observed
# alive 12m after a "complete" uninstall, and the sweeps fixture pins the
# stop's existence for that reason. Only the matcher narrowed.
if [[ "$IS_MACOS" == true ]]; then
    if pgrep -x tillandsias-tray >/dev/null 2>&1; then
        pkill -TERM -x tillandsias-tray 2>/dev/null || true
        sleep 1
        pkill -KILL -x tillandsias-tray 2>/dev/null || true
    fi
fi

# BOTH candidate install dirs, in the installer's own precedence order.
# install-macos.sh prefers /Applications and falls back to
# $HOME/Applications only when /Applications is not writable — so the
# DEFAULT target on an admin account (most personal Macs) was the one this
# block used to miss entirely. It removed the LaunchAgent below either way,
# leaving the worst possible state: the app still installed, and the thing
# that launches it gone, with the uninstaller reporting success.
#
# The `.bak` sibling goes with it. install-macos.sh moves any existing app
# aside to `Tillandsias.app.bak` before extracting; nothing ever reads it
# back (there is no rollback path) and nothing removes it on success, so it
# outlives the install it was taken from. Uninstalling must not leave a
# 30 MB copy of a removed application behind.
for _app_dir in "/Applications" "$HOME/Applications"; do
    rm -rf "$_app_dir/Tillandsias.app" "$_app_dir/Tillandsias.app.bak"
done
rm -f "$HOME/Library/LaunchAgents/com.tillandsias.tray.plist"

SERVICE_HOME_REMOVED=false
SERVICE_MODELS_NOT_SPARED=false
if [[ "$IS_ROOT" == true ]]; then
    rm -f "/usr/local/bin/tillandsias" "/usr/local/bin/tillandsias-uninstall"
    # 804-wfcu. `userdel -r` removes the account's HOME, and `rm -rf` finishes
    # the job, so both of these take $SERVICE_HOME/.cache/tillandsias/models
    # with them — the packaged service account's weights. That is defensible on
    # an uninstall; claiming afterwards that the cache was preserved is not.
    # Record what happened so the closing message can tell the truth.
    [ -d "$SERVICE_HOME" ] && SERVICE_HOME_REMOVED=true
    # 1181-bkem: this script never moves or chowns files out of a root-owned
    # service home on the invoking user's word, so under the flag we do not
    # try to spare this copy — we only say, truthfully, that it is not spared.
    if [[ "$KEEP_MODELS" == true && -d "$SERVICE_HOME/.cache/tillandsias/models" ]]; then
        SERVICE_MODELS_NOT_SPARED=true
    fi
    userdel -r "$SERVICE_USER" 2>/dev/null || true
    groupdel "$SERVICE_GROUP" 2>/dev/null || true
    rm -rf "$SERVICE_HOME"
    if [[ "$SERVICE_MODELS_NOT_SPARED" == true ]]; then
        echo "keep-models: $SERVICE_HOME/.cache/tillandsias/models is NOT spared by this script (service account home; not touched with reduced privilege)"
    fi
fi

if [[ "$WIPE" == true ]]; then
    # Remove cache (container images, opencode, openspec, secrets). 1181-bkem:
    # under the flag, spare $CACHE_DIR/models and remove everything else
    # directly under $CACHE_DIR instead of the whole tree, and say so — a run
    # that kept models must not be able to read back as a clean room by
    # accident.
    if [[ "$KEEP_MODELS" == true && -d "$CACHE_DIR/models" ]]; then
        _models_size="$(du -sh "$CACHE_DIR/models" 2>/dev/null | cut -f1)"
        find "$CACHE_DIR" -mindepth 1 -maxdepth 1 ! -name models -exec rm -rf {} +
        echo "keep-models: spared $CACHE_DIR/models (${_models_size:-unknown})"
    else
        rm -rf "$CACHE_DIR"
    fi

    # Remove all versioned forge and web images. The GNU-only no-run-if-empty
    # xargs flag is gone (851-28b5): the empty case is genuinely reachable
    # (fresh store, prior rmi), so guard on non-empty input instead — same
    # behavior on BSD and GNU xargs. Image refs contain no whitespace.
    imgs="$(podman images --format '{{.Repository}}:{{.Tag}}' 2>/dev/null | grep '^tillandsias-forge:' || true)"
    [ -n "$imgs" ] && printf '%s\n' "$imgs" | xargs podman rmi 2>/dev/null || true
    imgs="$(podman images --format '{{.Repository}}:{{.Tag}}' 2>/dev/null | grep '^tillandsias-web:' || true)"
    [ -n "$imgs" ] && printf '%s\n' "$imgs" | xargs podman rmi 2>/dev/null || true

    # Remove cached nix build output
    rm -rf "$CACHE_DIR/build-output" 2>/dev/null || true
fi

# ── Report ─────────────────────────────────────────────────────
echo ""
echo "  Uninstall complete. The following were removed:"
echo ""
echo "    - App binary"
echo "    - Libraries"
# 804-bpke: report what this run actually did, per platform and per mode.
if [[ "$IS_MACOS" == true && "$WIPE" != true ]]; then
    echo "    - Logs"
    echo "    - Desktop launcher"
else
    echo "    - App data"
    echo "    - Settings"
    echo "    - Logs"
    echo "    - Desktop launcher"
fi
[[ "$WIPE" == true ]] && echo "    - Cache and container images"
if [[ "$IS_MACOS" == true && "$WIPE" == true ]]; then
    echo "    - VM image ($DATA_DIR)"
fi
echo ""
echo "  Your project files were NOT touched."
# 804-bpke: name what was actually preserved. The old unconditional line said
# "Cache preserved" on a macOS run that had just deleted the VM — the one
# expensive thing on the disk — while the cache it named was 8 KB.
if [[ "$WIPE" != true ]]; then
    if [[ "$IS_MACOS" == true ]]; then
        echo "  VM image, settings and cache preserved. Use --wipe to remove everything."
    elif [[ "$SERVICE_HOME_REMOVED" == true ]]; then
        # 804-wfcu: the invoking user's cache IS preserved, but the service
        # account's home just went — models included. Saying "Cache preserved"
        # here is the same false reassurance 804-bpke removed on macOS: true of
        # the 8 KB nobody cares about, false of the gigabytes they do.
        echo "  Your cache ($CACHE_DIR) is preserved. The service account home"
        echo "  $SERVICE_HOME was REMOVED, including any model cache it held."
        echo "  Use --wipe to remove your cache too."
    else
        echo "  Cache preserved. Use --wipe to remove everything."
    fi
fi
echo ""
