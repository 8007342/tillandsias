# Tasks — workload-identity-plane

Packet orders in brackets; dependency order top to bottom. Each task's
closure is the refusal arm named in its packet's exit criteria, written red
against today's code first.

## 1. Close the open doors (v0.5)

- [ ] 1.1 The git mirror refuses `git://` pushes; the SSH-CA lane is the only
      receive path [1685-kwmr]
- [ ] 1.2 SELinux labelling on by default; `label=disable` only from a named
      exception allow-list in `policy.rs` [1693-9qfb]

## 2. Measure the enclave (v0.6)

- [ ] 2.1 Enclave listener inventory with client-auth mode; `none` needs a
      waiver that names the row removing it [1688-ideu]

## 3. One name (v0.6)

- [ ] 3.1 SPIFFE-form workload ID grammar and its single parser; carried in
      the SSH lane cert Key ID [1686-7miz]
- [ ] 3.2 Signed, per-project pseudonymous agent provenance trailer on forge
      commits; the mirror verifies at receive [1687-ipmx]

## 4. Two-way TLS (v0.6)

- [ ] 4.1 Lane client certs (Vault PKI `lane-client`, 1 h, URI SAN) and Vault
      requires them [1689-echb]
- [ ] 4.2 TLS-terminating front requiring lane certs before every inference
      engine, all three platforms [1690-iqh5]
- [ ] 4.3 Router and egress proxy authenticate the calling lane by cert
      [1691-96gk]

## 5. Sockets, twice (v0.6)

- [ ] 5.1 Kernel-attested peer check (SO_PEERCRED + cgroup container id) on
      the ssh-agent and per-lane control sockets [1692-37qz]
- [ ] 5.2 Lane sockets labelled with the lane's MCS pair; confined role types
      for forge, mirror, router, proxy [1694-j2sk]

## 6. Fleet (v0.7, deferred)

- [ ] 6.1 Enclave-CA bundle exchange in SPIFFE federation form [1695-h8bu]
