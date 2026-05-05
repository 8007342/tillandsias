# browser-tray-notifications spec

## REQUIREMENTS

### REQ-1: Show "Launching browser" chip with withered globe
**Given** `handlers::handle_open_browser_window()` is called  
**When** the function starts executing  
**Then** add a `BuildProgress` entry with:
- `image_name: "Browser"` (or "Browser — <project>")
- `status: InProgress`
- Globe icon (🌐) displayed as withered (grayed out)

### REQ-2: Update chip on success
**Given** the browser container spawned successfully  
**When** `spawn_chromium_window()` returns Ok  
**Then** update the chip to:
- `status: Completed`
- Globe icon shown as green/active for 5s, then fadeout

### REQ-3: Update chip on failure
**Given** the browser container failed to spawn  
**When** `spawn_chromium_window()` returns Err  
**Then** update the chip to:
- `status: Failed(reason)`
- Globe icon shown as red (❌) for 5s, then fadeout
- Message: "Browser failed: <reason>"

**Trace**: @trace spec:browser-tray-notifications  
**URL**: https://github.com/8007342/tillandsias/search?q=%40trace+spec%3Abrowser-tray-notifications&type=code
