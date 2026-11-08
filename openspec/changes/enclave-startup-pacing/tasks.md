## 1. Lane and settle (2031-75q4)
- [ ] 1.1 Enclave-wide heavy-step lane in tillandsias-headless
- [ ] 1.2 PSI trigger wait with per-step deadline and fallback
- [ ] 1.3 `bringup: step=… settle_ms=…` records; fixture with a fake pressure file

## 2. Readiness instead of sleeps (2031-wqbe)
- [ ] 2.1 Proxy port check replaces the 3 s sleep
- [ ] 2.2 Router start confirmed; "Routing Traffic" status line

## 3. Inference after forge Ready (2031-pd7g)
- [ ] 3.1 Defer inference ensure/start and model fetch until forge Ready; soft failure

## 4. Bounded copies (2031-yu46)
- [ ] 4.1 `image_parallel_copies = 2` in provisioned containers.conf on all three platforms

## 5. macOS guest writeback (2031-v8si)
- [ ] 5.1 Guest sysctl dirty_bytes/background_bytes; measure a cold bringup before/after
