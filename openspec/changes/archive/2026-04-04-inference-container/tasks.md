## 1. Inference Container Image

- [ ] 1.1 Create `images/inference/Containerfile` — Fedora minimal + ollama, non-root user
- [ ] 1.2 Create `images/inference/entrypoint.sh` — start ollama serve with proxy env vars
- [ ] 1.3 Register `inference` image type in `build-image.sh`
- [ ] 1.4 Test: `build-image.sh inference` builds successfully

## 2. Inference Container Profile & Lifecycle

- [ ] 2.1 Add `inference_profile()` to `container_profile.rs` — enclave network, model cache volume, proxy env vars, no secrets
- [ ] 2.2 Add `inference_image_tag()` to `handlers.rs`
- [ ] 2.3 Add `ensure_inference_running()` to `handlers.rs` — start if not running, shared across projects
- [ ] 2.4 Add `stop_inference()` to `handlers.rs` — stop on app exit
- [ ] 2.5 Wire `ensure_inference_running()` into forge launch paths
- [ ] 2.6 Add inference stop to shutdown sequence in `main.rs`

## 3. Forge Integration

- [ ] 3.1 Add `OLLAMA_HOST=http://inference:11434` env var to `common_forge_env()`
- [ ] 3.2 Update env var count tests

## 4. Testing & Verification

- [ ] 4.1 Run `cargo test --workspace` — all tests pass
- [ ] 4.2 Test: inference container starts and ollama responds
- [ ] 4.3 Test: forge container can reach inference via OLLAMA_HOST
