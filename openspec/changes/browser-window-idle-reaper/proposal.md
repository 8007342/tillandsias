## Why

On macuahuitl on 2026-11-20, the cannonball forge's five `browser.open` windows were still running 13-17 hours after the work finished. Each window had its `tillandsias-browser-fwd-<id>` forwarder alongside it.
- All five were `--headless=new`.
- Each GPU process ran at 250-300% CPU, and each renderer at about 50%.
- Together they drove 30 GB of swap, and the coordinator stopped them by hand.

The registry carried a 24 h idle check and a 48 h lifetime check, but nothing called either, and no tool call ever counted as activity. So a window lived until `browser.close` or tray Quit, and an agent that forgot `browser.close` leaked it.

## What Changes

- ADDED to `host-browser-mcp`: idle windows are reaped.
  - A headless window, or a dev window, with no CDP command and no user input for the idle limit is stopped together with its forwarder and network. The default limit is 15 minutes, set by `TILLANDSIAS_BROWSER_IDLE_MINUTES`; `0` disables it.
  - The agent's next call on that window answers `browser.closed:idle`.
  - Every tool call that names a window counts as activity.
  - A dev window carries a page listener that records user input, so a person using it keeps it alive.
  - A headed non-dev window runs no page script, so the reaper cannot see input there. A person can see and close it, and only the 48 h lifetime bounds it.
- The `browser.open` result (a `lifecycle` field), the `browser.open` and `browser.close` descriptions, and the forge's browser instructions all say: "close it with browser.close when you are done".

## Impact

- `crates/tillandsias-browser-mcp`, the forge agent guidance and the opencode web-services instruction, the forge-quick-intro skill, and the CDP cheatsheet.
- An agent that leaves a window idle for 15 minutes loses it and reopens it.
