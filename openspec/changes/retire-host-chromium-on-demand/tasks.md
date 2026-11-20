## 1. Retire host-chromium-on-demand (2118-fk3w)

- [x] 1.1 Prove nothing calls scripts/install-chromium.sh or reads ~/.cache/tillandsias/chromium (evidence in proposal.md)
- [x] 1.2 Delete scripts/install-chromium.sh and litmus:host-chromium-on-demand-shape
- [x] 1.3 Delta spec: REMOVE all four requirements
- [x] 1.4 Bindings: host-chromium-on-demand obsolete with tombstone; litmus:browser-ephemeral rebound to host-browser-mcp
- [x] 1.5 Repoint @trace spec:host-chromium-on-demand (crates, cheatsheets, host-browser-mcp, host-chromium tombstone)
- [ ] 1.6 Archive this change after it lands; the main spec then becomes the tombstone
