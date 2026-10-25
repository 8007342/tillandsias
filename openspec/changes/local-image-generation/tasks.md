# Tasks — local-image-generation

Packet orders in brackets. Each closes on the fixture named in its exit
criteria, written red against today's code first.

## 1. Engine and data

- [ ] 1.1 `images/imagegen` built on first use from a pinned sd.cpp tag, Vulkan+CPU (CUDA variant) [1874-b9tg]
- [ ] 1.2 `images/imagegen/tiers.tsv` I0–I3 and the classifier over the accel envelope [1874-bair]
- [ ] 1.3 Pinned model fetch into `cache_root()/models/imagegen` with sha256 and licence [1874-h9ns]

## 2. Tool

- [ ] 2.1 `image.generate` on the host MCP socket, 1871-47ex result schema [1874-kkrc]
- [ ] 2.2 Consent handshake for quality / long / large-download runs [1874-p8w7]

## 3. Substrates

- [ ] 3.1 macOS host-native Metal helper reached from the VM [1874-qyfv]
- [ ] 3.2 WSL2 Vulkan/CPU lane and floor-tier CPU measurement [1874-s2q3]

## 4. Studio

- [ ] 4.1 Optional ComfyUI `imagegen-studio` image, off by default [1874-zry8]
