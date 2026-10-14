# v56.10.14.1 e2e smoke — macos PASS (2026-10-14)

Release: https://github.com/8007342/tillandsias/releases/tag/v56.10.14.1. macOS curl-install smoke on tlatoanis-macbook-air, requested by the coordinator (macuahuitl-fedora) after the release's ledger row landed (5442f5375, land 429). The Linux record is plan/issues/e2e-smoke-v56.10.14.1-linux-2026-10-14.md.

**PASS** for v56.10.14.1 on macOS: the published artifact, installed by curl and run through install, Ready, crash rebuild, 1668 through the tray, a clean quit with a forge open, and the guest baseline. One new p1 feature defect (1713-1dnx), which doesn't affect install or sign-in.

| | |
|---|---|
| host | Tlatoanis-MacBook-Air (tlatoanis-macbook-air), macOS 27.0, arm64, 10 cores / 16 GiB |
| tag | v56.10.14.1, tray git `643de7a39`, built 2026-10-14T16:43:13Z |
| install | `curl -fsSL …/releases/download/v56.10.14.1/install-macos.sh \| TILLANDSIAS_VERSION=v56.10.14.1 bash`, exit 0 (20:02:48Z → 20:03:56Z) |
| consent | the operator's standing instruction (2026-10-12) to smoke-test every release with the default install, destructive by design; the operator was warned before the run |
| go | coordinator macuahuitl, after the ledger row landed at 5442f5375 (land 429) |

    §1 install     PASS  exit 0   sha256: ok (0caff27815a2…)
                            installed: version=56.10.14.1 pin=55c60a3b80d3
                            reset: SOFT (VM kept; store and sign-ins kept)
                            the old 13.1 tray's quit: drain_timeout (60s), force-stop (finding A)
    §2 ready       PASS  20:04:49Z phase=Ready podman_ready=true
                            first launch: "reset: REBUILD (unclean previous stop …)", rootfs.img destroyed,
                            fresh Fedora Cloud image, vm-identity.img kept
                            GitHub sign-in kept (cloud-projects: 16 entries at 20:05:06Z)
    §3 crash       PASS  kill -9 of the tray at 20:05:27Z, relaunched 20:05:30Z:
                            REBUILD again, rootfs destroyed, identity disk kept
                            20:07:16Z phase=Ready; sign-in intact (16 entries at 20:07:33Z)
                            the log also printed a stale DEFECT line (finding B)
    §1668          PASS  through the tray: macron.dev, agent Claude, attached 20:08:37Z, "Claude session open" 20:11:08Z
                            the operator saw no git name or email prompt at any point
                            in the forge: GIT_AUTHOR_IDENT = GIT_COMMITTER_IDENT =
                              Tlatoāni (tillandsias-vm · tillandsia-cyanea) <162944123+8007342@users.noreply.github.com>
                            source: file:/home/forge/.config/git/config (user.name, user.email)
                            a throwaway commit in a mktemp repo: author = committer = the same identity
    §4 quit        PASS  Apple-event quit at 21:05:59Z with the macron.dev forge (Claude) still open
                            → "in-VM headless acked shutdown request" 21:05:59.634Z
                            → "guest reported a clean power-off (token matched)" → 21:06:06.944Z "Quit: VM drained cleanly" (7.4 s)
    §5 guest       PASS  exec-guest after the quit: Fedora Linux 44 (Cloud Edition)
                            df /: 20G, 4.9G used (forge images built this session); identity disk 2.0G, 48M used
                            free: Mem 7.7Gi; Swap 25Gi (/dev/vdb 24G + zram 2G)
                            WIPING: 0 lines in boot -1 (20:06:38Z→21:06:01Z, the boot after the crash rebuild) and 0 in boot 0
                            cloud project state lives in guest volumes on the root disk: tillandsias-mirror-macron.dev,
                            tillandsias-source-<hash> (RAM tmpfs), tillandsias-spec-index-macron.dev, tillandsias-forge-cache-macron.dev
    macron.dev     DONE  the forge's own agent, per the operator's standing permission (2026-10-14): pushed e1a5205 to main, including the note
                            "Release smoke v56.10.14.1, from inside a macOS forge"; measured deploys (push → Workers Builds check):
                            main 12m37s / 1m31s / 59s / 6m46s, success; branch builds 9m39s and ~27s, FAILED with no reason given

## Findings

- **1713-1dnx (p1, new)**: in the forge, host-browser is CONNECTION_CLOSED. /run/host/tillandsias-mcp is mounted with TILLANDSIAS_CONTROL_SOCKET set, but it's empty, and the wrapper answers "TILLANDSIAS_CONTROL_SOCKET does not exist". Source read: the lane listener is `#[cfg(feature = "tray")]`, and the VM guest binary is built with `--features listen-vsock`. So publish_local and every browser tool are unreachable from macOS VM forges (and likely from Windows forges). It blocks 1712-3fsw. This affects a feature, not install or sign-in, so it doesn't block promotion on its own; that's the coordinator's call.
- **A (install-time forced stop)**: the installer stopped the old 13.1 tray at 20:02:50Z. The guest acked shutdown, but VZ stayed Running past the 60 s drain, so the tray force-stopped at 20:03:56Z. The next launch was therefore an unclean REBUILD. No forge session was live: the "Claude session ended" event text was carried over from 02:40:05Z, the Mac then slept (wake at 06:09Z), and nothing attached after. The previous evening's clean menu Quit (23:43:57Z → 23:44:04Z) drained in 7 s. The console log for this stop was overwritten by the two later boots, so the guest side isn't known. Work survival: cloud project state lives in guest volumes on the root disk (§5), and an unclean-stop REBUILD destroys rootfs.img, so unpushed forge work doesn't survive a REBUILD. The operator ruled this out of scope ("Don't worry about lost work"). The same quit path drained cleanly in 7.4 s with a forge open (§4), so the timeout likely follows the Mac's long sleep (02:40Z → 20:02Z, wake at 06:09Z), not a live forge. Not reproduced.
- **B (stale wording, noted on 1642-cc54)**: the second REBUILD logged "DEFECT (1642-cc54): two unclean stops in a row, so the workspace was rebuilt again and the sign-ins lost again". The sign-ins were kept (16 entries after Ready). The message predates the identity-disk move.
- **Seen in the log, not a 14.1 finding**: on 13.1, the launch at 01:22:41Z after a clean quit showed "cloud-projects: fetch unconfirmed; keeping previous list", then 0 entries, and the operator signed in again at 01:30:47Z (16 entries at 01:31:39Z). Whether the sign-in was actually lost or only the fetch was unconfirmed isn't known; it's to be asked of the operator.
- **macron.dev blockers needing dashboard access** (relayed to the operator): Cloudflare branch preview builds all fail with no reason given; the forge egress allowlist blocks macron.dev, so forges can't see push → live directly.
- **Side task**: the Flutter arm64 pin (PR #433). `git ls-remote https://github.com/flutter/flutter.git refs/tags/3.47.7` = abaf9c523780a608bd46686fd5e53740a07077f8, a lightweight tag equal to FLUTTER_RELEASE_HASH, so the clone check `rev-parse HEAD = release hash` will hold. The full image build is pending.
