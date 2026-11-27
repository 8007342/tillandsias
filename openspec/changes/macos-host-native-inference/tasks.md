# Tasks — macos-host-native-inference (2381-778w)

@trace order:2381-778w

- [ ] 2381-tfna Measure Ollama-MLX vs `mlx_lm.server` vs `llama-server` on the base M5 16 GB: 0.5B–4B
      chat (decode and prefill) and embeddings (Qwen3-Embedding-0.6B, EmbeddingGemma); resident memory per
      model. Choose the default engine from the numbers.
- [ ] 2381-iy9u The tray starts, leases and stops the host service and binds SLOT-6 to it by default;
      the guest-CPU fallback is named in status (SLOT-10).
- [ ] 2381-t39p The allowlist between the relay and the service: two operations, tier-table models
      only, per-VM credential, caps; model-management refused by name (SLOT-10.3, SLOT-10.4).
- [ ] 1654-6me6 The Seatbelt profile for the service: no network, empty environment, no keychain
      (SLOT-10.2); a test that an outbound connection from inside fails.
- [ ] 2381-zueb Model residency (host service, in-guest models, the babysitter judge) is admitted
      against one host budget in `job-admission-queue` (2094-65yz).
- [ ] 2381-rt4e The Foundation Models tier: availability probe, skip reason, fall-through (SLOT-11).
- [ ] 1921-kr7v The krunkit provider with VZ fallback, as already filed; its GPU follow-ups (1921-vk4i,
      1653-77bt) are deprioritised.
