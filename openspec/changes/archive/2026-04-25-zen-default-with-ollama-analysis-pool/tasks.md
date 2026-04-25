# tasks

## 1. Config overlay

- [x] `images/default/config-overlay/opencode/config.json` — set
  `model: "opencode/big-pickle"`, set `small_model:
  "opencode/gpt-5-nano"`, keep ollama provider intact.
- [x] Add a short instruction file telling the agent: "use the
  ollama/* models for analysis subtasks; opencode/* for tool-calling".

## 2. Inference image — tool-capable model pre-pulls

- [x] `images/inference/Containerfile` — add a build-time `RUN ollama
  serve & pull qwen2.5:0.5b llama3.2:3b; pkill ollama` step. Bakes
  ~2.4GB but eliminates first-run Squid pulls for the baseline tier.
- [x] `images/inference/entrypoint.sh` — replace `tinyllama:1.1b` with
  `llama3.2:3b` at T1; bump GPU tiers to qwen2.5 / qwen2.5-coder;
  log which tier the host was classified into.

## 3. Verification

- [x] Boot tray + attach to ../java project.
- [x] Inside forge, run `opencode run "build and compile
  HelloAsynchronous.java, and push to remote once successfully run"`.
- [x] Agent writes file, javac, java run prints expected output, git
  add + commit + push happens via the mirror.
- [x] `git log` on host's working tree (post mirror→host sync) shows the
  new commit.

## 4. OpenSpec convergence

- [x] Validate strict.
- [x] Archive once verification scenarios pass.
