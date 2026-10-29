# Tasks — local-image-generation

Packet orders in brackets. Each closes on the fixture named in its exit
criteria, written red against today's code first.

## 1. Engine and data

- [ ] 1.1 `images/imagegen` built on first use from a pinned sd.cpp tag, Vulkan+CPU (CUDA variant) [1874-b9tg]
- [ ] 1.2 `images/imagegen/tiers.tsv` I0–I3 ladder (permissive licences only) and the ceiling classifier [1874-bair]
- [x] 1.3 Pinned model fetch into `cache_root()/models/imagegen` with sha256 and licence [1874-h9ns]

## 2. Tool

- [x] 2.1 `image.generate` on the host MCP socket, exact requested size, output in shared `/work/tmp/imagegen/` [1874-kkrc]
- [ ] 2.2 Smallest-first, one-tier-up offer with curated sentences and a host-minted token [1874-p8w7]

## 3. Substrates

- [ ] 3.1 macOS host-native Metal helper reached from the VM [1874-qyfv]
- [ ] 3.2 WSL2 Vulkan/CPU lane and floor-tier CPU measurement [1874-s2q3]

## 4. Studio

- [ ] 4.1 (later) Optional ComfyUI `imagegen-studio` image, off by default [1874-zry8]
