# mcp-on-demand spec

## REQUIREMENTS

### REQ-1: Replace MCP daemon with on-demand CLI tool
**Given** the current `tillandsias-mcp-browser` runs as a persistent daemon inside the forge container  
**When** refactoring to on-demand tool  
**Then** create `tillandsias-browser-tool` binary that:
1. Takes CLI args: `safe <url>` or `debug <url>`
2. Connects to `/run/tillandsias/tray.sock`
3. Sends JSON-RPC request: `{"method": "open_browser_window", "params": {"project": "...", "url": "...", "window_type": "..."}}`
4. Exits with code 0 (success) or 1 (failure)
5. Outputs JSON to stdout: `{"status": "ok"}` or `{"status": "error", "message": "..."}`

### REQ-2: OpenCode web always uses safe browser
**Given** `opencode serve` is running in the forge container  
**When** the agent or user clicks a link like `http://opencode.<project>.localhost`  
**Then** it calls `tillandsias-browser-tool safe http://opencode.<project>.localhost:<port>` (never debug).

### REQ-3: One debug browser max per project
**Given** a debug browser exists for a project  
**When** another `debug <url>` request arrives  
**Then** reject with error "Debug browser already running for <project>".

**Trace**: @trace spec:mcp-on-demand  
**URL**: https://github.com/8007342/tillandsias/search?q=%40trace+spec%3Amcp-on-demand&type=code
