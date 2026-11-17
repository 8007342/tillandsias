## 1. Tier files + per-tier proxy ports (2041-i3nk)
- [ ] 1.1 Split allowlist.txt into images/proxy/tiers/*.txt; union litmus
- [ ] 1.2 Generate one Squid port per tier set; `ssl::server_name` matching; keep 3128 = union

## 2. Declarations and launch wiring (2041-jb57)
- [ ] 2.1 images/<image>/egress.yaml; studios.json `egress`; litmus for missing declarations
- [ ] 2.2 headless picks network + proxy URL from the declaration; undeclared = none

## 3. enclave-fetch MCP service (2041-csm4)
- [ ] 3.1 fetch/feed/docs with catalog, private-IP refusal, robots.txt, caps, Markdown
- [ ] 3.2 Wire into the forge's MCP config (closes 2037-4ptq)

## 4. Search through the service (2041-u7pm)
- [ ] 4.1 search(query) with the key from Vault; result URLs fetchable for the session

## 5. Rate limits and audit (2041-9aiq)
- [ ] 5.1 per-port delay_pools, per-client limits in the service, JSONL audit in both

## 6. Approval queue (2041-j6yt)
- [ ] 6.1 Refusals queued to the tray; session/permanent approval writes a provenance entry

## 7. SNI/destination check (2041-8azp)
- [ ] 7.1 Refuse a CONNECT whose target does not match the SNI's resolution; forged-SNI fixture

## 8. Registry mirrors (2041-54ce)
- [ ] 8.1 Sibling pull-through mirrors for npm/PyPI/Go/crates; shrink `registries`
