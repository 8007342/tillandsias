# 1637-5765: hosts and sizes of a clean Flutter + Flame web build (lenovinha, 2026-10-14)

**Question (the row's next_action):** which hosts does a clean `flutter build web` with Flame fetch, and does it fit the forge?

**Method:** `measure.sh`, run on a private podman store under `target/work`.
- Each phase is its own container on an `--internal` network.
- The only way out is `logproxy.py`, a CONNECT-logging proxy in a container on both networks. This is the forge's topology, so a direct connection could not bypass the log.
- `hosts.tsv` holds one line per connection: phase, method, host, bytes down, bytes up.
- The base OS tools come from image build time (deb.debian.org) and are outside the measurement.
- The operator's containers and `$XDG_RUNTIME_DIR/containers/networks` were snapshotted before and after: unchanged.

## Result

| Phase | rc | Time | Hosts | Down |
|---|---|---|---|---|
| 1 SDK download (releases_linux.json + tarball) | 0 | 61 s | storage.googleapis.com | 1,578,092,224 B tarball (the proxy logged a reset at close, so its byte count is 0) |
| 2 first `flutter --version` | 0 | 31 s | none reached. One plain-HTTP probe to 169.254.169.254/metadata/instance, timed out (cloud-metadata bot detection) | 0 |
| 3 `flutter precache --web` | 0 | 0 s | none: the stable tarball already carries the web SDK | 0 |
| 4 `flutter create --platforms web app` | 0 | 15 s | pub.dev (242 connections) | 31.3 MB |
| 5 `flutter pub add flame` (flame 1.38.2) | 0 | 3 s | pub.dev (31 connections) | 16.9 MB |
| 6 `flutter build web --release` | 0 | 24 s | **none** | 0 |
| 7 rebuild | 0 | 22 s | none | 0 |

Pinned SDK: Flutter 3.47.7 stable (Dart 3.13.5), archive `stable/linux/flutter_linux_3.47.7-stable.tar.xz`. sha256 `af7455f540df951184c7953fbe3cf884766e7541dacf8571f9f582db03dd6230` matches the manifest. No analytics endpoint was contacted.

**Allowlist:** `images/proxy/allowlist.txt` already admits both hosts the build needs, `.googleapis.com` and `.pub.dev`. The row's claim that "the proxy does not allow pub.dev or Flutter's artifact storage" is false on today's trunk. The proxy is not the blocker; the missing SDK is.
- The SDK fetch belongs at IMAGE build time, so a forge-time build needs only pub.dev.
- A build with no new packages needs no network at all.
- The 169.254.169.254 probe must stay refused. It is not on the allowlist.

## Sizes, against the 348 MB forge tmpfs

| What | Size | Where it must live |
|---|---|---|
| SDK unpacked | 2.5 GB: artifacts 1000 MB, dart-sdk 642 MB, .git 301 MB, flutter_web_sdk 117 MB | an image, never tmpfs |
| SDK tarball | 1.5 GB | image build only |
| PUB_CACHE after create + flame | 217 MB (168 MB after create alone; 115 packages) | the disk-backed forge cache volume. lib-common.sh already sets `PUB_CACHE=$PROJECT_CACHE/pub` |
| app `.dart_tool` | 30 MB | the project volume (RAM) |
| app `build/web` (canvaskit, main.dart.js) | 40 MB | the project volume (RAM) |

So one Flutter app adds about 70 MB to the project's RAM volume. macron.dev (176 MB) plus one Flame app comes to about 246 MB of 348 MB. It fits, but a second app or a large asset set would not. PUB_CACHE must stay on the cache volume: put on tmpfs, it alone would take 62% of the budget.

## The image, built and run (image-run/)

`images/flutter/Containerfile` was built in the same private store: 98 s, 2,796,849,689 bytes. The forge-time phases then ran against it as uid 1000 (`--userns=keep-id`), with the logging proxy as the only egress.

| Phase | rc | Time | Hosts |
|---|---|---|---|
| `flutter --version` | 0 | 2 s | none. No 169.254.169.254 probe: `BOT=false` stops the bot detector |
| `flutter create --platforms web app` | 0 | 14 s | pub.dev (242) |
| `flutter pub add flame` | 0 | 3 s | pub.dev (33) |
| `flutter build web --release` | 0 | 25 s | pub.dev (2; pub's freshness check in a fresh container) |

With the image, the forge-time allowlist need is exactly `.pub.dev`. Project files are owned by the forge uid.
