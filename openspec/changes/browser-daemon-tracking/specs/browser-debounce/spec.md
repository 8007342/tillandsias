# browser-debounce spec

## REQUIREMENTS

### REQ-1: Debounce browser window spawns per project
**Given** an agent calls `open_safe_window(url)` for a project  
**When** a browser window was already spawned for that project in the last 10 seconds  
**Then** the new request is rejected with error "Debounced: wait Ns before opening another window for <project>".

**Rationale**: Prevent rapid-fire spawns from agents. 10s window matches build chip fadeout pattern.

### REQ-2: Track debounce timing per project
**Given** `TrayState` maintains `browser_last_launch: HashMap<String, Instant>`  
**When** `handle_open_browser_window()` is called  
**Then** check the map: if `now - last_launch < 10s`, reject; otherwise update timestamp and proceed.

### REQ-3: Debounce applies to safe windows only
**Given** `open_debug_window()` is called  
**When** checking debounce  
**Then** debounce is NOT applied (debug windows are manually triggered, rare).

**Trace**: @trace spec:browser-debounce  
**URL**: https://github.com/8007342/tillandsias/search?q=%40trace+spec%3Abrowser-debounce&type=code
