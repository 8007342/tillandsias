## 1. Catalogue

- [x] 1.1 Vendor Playwright deviceDescriptorsSource.json (pinned 606f017a1) and Chrome DevTools EmulatedDevices.ts (pinned b0d348764), with their licences
- [x] 1.2 Hand-written overlay (Xperia 1 VI, OnePlus 12/13, Xiaomi 14) from manufacturer spec pages; derived viewport/dpr labelled as derived
- [x] 1.3 released.yaml: launch months, flagship lines, extra aliases
- [x] 1.4 scripts/lua/build-device-catalogue.lua writes a byte-reproducible catalogue.json; --check proves freshness

## 2. Resolver and CLI

- [x] 2.1 tillandsias_core::devices::resolve with the six rules
- [x] 2.2 Unit tests for every exit criterion of 1643-q3at
- [x] 2.3 `tillandsias devices resolve <query>` / `devices list`

## 3. Next (other rows)

- [ ] 3.1 Browser plan consumers (CDP emulation, containerized browser.open, WebKit engine): coordinator's batch
