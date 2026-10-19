#!/usr/bin/env bash
# @trace order:1777-yhwr, order:1656-tjv4
# The WebKit window's entrypoint. The window plays to a private audio server
# whose only device is "Speakers", never to the output-only server it was given
# (whose clients can list every host device): the same front as the Chromium
# window (1769-9gna), from the same browser-audio-start.sh.
set -euo pipefail

# shellcheck source=browser-audio-start.sh
source /usr/local/lib/tillandsias/browser-audio-start.sh

exec node /opt/tillandsias/webkit-window.js "$@"
