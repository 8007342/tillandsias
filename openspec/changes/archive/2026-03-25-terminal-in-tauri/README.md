# terminal-in-tauri — REJECTED

**Reason**: Tauri windows are WebViews (WebKitGTK on Linux). Embedding xterm.js or any terminal emulator in a WebView adds 20-40ms latency per keystroke vs native terminals. NVIDIA GPU white screen bugs with WebKitGTK canvas rendering. The WebView process boundary is an architectural bottleneck that no renderer (WASM, WebGL) can eliminate.

**Alternative**: `named-terminals` — set custom window titles on native terminals (ptyxis -T) so users can identify and recover windows by project name. Zero performance cost, same UX benefit.
