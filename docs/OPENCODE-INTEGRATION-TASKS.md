# OpenCode Integration Tasks for Tillandsias CLI

## Current State
- ✅ Portable binary (musl-static) — working
- ✅ Headless orchestration — working
- ✅ Container image building — working
- ✅ App lifecycle (start/stop with JSON events) — working
- ✅ Signal handling — working
- ❌ OpenCode CLI integration — not yet implemented
- ❌ LLM inference — not yet integrated

## Implementation Path

### Phase A: CLI Flag Support (--opencode, --prompt)
**File**: `crates/tillandsias-headless/src/main.rs`

1. **Parse --opencode flag**
   - Current: Rejects as unsupported option
   - Required: Accept flag, enable OpenCode mode
   - Implementation: Add to `known_flags` array, set boolean flag

2. **Parse --prompt flag**
   - Current: Not recognized
   - Required: Accept string argument, store prompt text
   - Implementation: Extract prompt value after flag, store in struct

3. **Create OpenCode mode handler**
   ```rust
   if opencode {
       run_opencode_mode(config_path, prompt, debug)?;
       return;
   }
   ```

### Phase B: Project Mounting & Container Setup
**Files**: `handlers.rs`, `orchestrate-enclave.sh`

1. **Mount project directory**
   - Bind `/var/home/machiyotl/src/java` into forge container
   - Path: `/workspace` inside container
   - Permissions: Read-write (user isolation via --userns=keep-id)

2. **Start enclave containers in order**
   - Proxy (caching, security)
   - Git service (mirror, credentials)
   - Inference (ollama, LLM models)
   - Forge (dev environment, workspace mounted)

3. **Establish inter-container networking**
   - Create bridge network
   - Service discovery via container names
   - Environment variables for service endpoints

### Phase C: LLM Inference Integration
**Files**: `handlers.rs`, new `opencode.rs` module

1. **Inference container handshake**
   - Wait for inference health check (JSON endpoint)
   - Verify ollama is ready
   - Check model availability

2. **Send prompt to inference**
   - Format prompt as HTTP POST to `http://inference:11434/api/generate`
   - Stream response lines back to user
   - Handle errors (model not loaded, timeout, etc.)

3. **Response handling**
   - Parse JSON stream from ollama
   - Extract completion tokens
   - Display in real-time or accumulate

### Phase D: Integration Testing
**Test sequence**:
```bash
tillandsias /var/home/machiyotl/src/java \
  --opencode \
  --debug \
  --prompt "Analyze this Java project. What's the main purpose?"
```

Expected flow:
1. App starts, logs "OpenCode mode enabled"
2. Mounts `/src/java` into forge container
3. Starts containers (proxy, git, inference, forge)
4. Sends prompt to inference
5. Streams response: "This project appears to be..."
6. On completion or user interrupt (Ctrl+C): graceful shutdown

## Files to Modify

| File | Changes |
|------|---------|
| `crates/tillandsias-headless/src/main.rs` | Add CLI parsing for --opencode, --prompt |
| `src-tauri/src/handlers.rs` | Mount project, start orchestration |
| `src-tauri/src/opencode.rs` | (new) OpenCode orchestration logic |
| `scripts/orchestrate-enclave.sh` | Container startup sequence |

## Known Constraints

- **No authenticated GitHub access in forge**: Credentials stay in git-service only (security isolation)
- **No internet from forge**: Proxy-only access (pre-filtered domain allowlist)
- **Stateless containers**: Changes in forge are ephemeral (by design)
- **Inference latency**: First prompt cold-starts ollama model loading (~30s for 7B parameter model)

## Testing Checklist

- [ ] `--opencode` flag parsed correctly
- [ ] `--prompt` argument captured
- [ ] Project directory mounted in forge
- [ ] Inference container responds to health check
- [ ] Prompt sent to ollama over HTTP
- [ ] Response streamed to stdout
- [ ] Graceful shutdown on Ctrl+C
- [ ] No orphaned containers after exit
- [ ] Secrets cleaned up on exit

## Success Criteria

**Minimal (MVP)**: User can run:
```bash
tillandsias /path/to/project --opencode --prompt "What does this code do?"
```
And receive a response from the inference container.

**Full**: Same as MVP + proper error handling, timeout management, and real-time streaming.
