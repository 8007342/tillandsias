# Microsoft Linux guest migration research — Azure Linux 4.0 as WSL2 guest OS

- **Date**: 2026-07-02
- **Host**: windows (windows-next)
- **Status**: research complete — verdict **DEFER with conditions** (order 160; conditional
  migration packet at order 161)
- **Operator prompt**: evaluate migrating the WSL2 guest from Fedora 44 Container Base to
  "Microsoft Linux 4.0 for cloud containers", hoping for better native resource sharing
  ("podman sharing kernel resources natively instead of a reserved-and-limited finite
  pre-allocated RAM at VM launch").

## 1. What the product actually is (naming discrepancy resolved)

There is no product named "Microsoft Linux 4.0". The operator most plausibly means
**Azure Linux 4.0**, announced at Open Source Summit North America (2026-05-18) and
released as **public preview at Microsoft Build (2026-06-02)** — successor to Azure
Linux 3.0 (the CBL-Mariner line). Two adjacent announcements share the news cycle and
are easy to conflate:

- **Azure Container Linux (ACL)** — a *separate*, Flatcar-derived, **immutable**
  container-optimized OS, GA'd at the same summit, SELinux enforcing by default. Updated
  by whole-image replacement, not dnf — structurally incompatible with our mutable,
  recipe-provisioned WSL guest. Not a candidate.
- **wslc ("WSL container", `container.exe`)** — a new Windows container-management CLI/API
  in WSL 2.9.3 public preview (GA targeted fall 2026). Relevant to the resource question
  (§4) but it is a management surface, not a distro.

Verified facts for **Azure Linux 4.0** (citations in §7):

| Property | Value |
|---|---|
| Heritage | **Fedora-derived — currently a Fedora 43 snapshot** (major break from CBL-Mariner lineage); "every deviation from Fedora carries a written description of why it exists" |
| Kernel | 6.18 LTS, Microsoft fork, Hyper-V/GPU/AI-accelerator tuned (irrelevant under WSL2 — see §4) |
| Package manager | **dnf5** (replaces tdnf; standard dnf tooling + plugin ecosystem) |
| Init | systemd 258 |
| Userland | glibc 2.42, OpenSSL 3.5 (post-quantum suites), Python 3.14, RPM 6.0 |
| SELinux | "supported on every image"; ACL variant ships **enforcing by default**; FIPS 140-3 in progress |
| Servicing | Monthly security updates, signed packages/repos, SBOMs; maintained by the team that runs Azure's fleet |
| Availability (2026-07-02) | Azure VMs/VMSS (preview, **"strict not-for-production warning"**), MCR container base images (`mcr.microsoft.com/azurelinux-beta/base/core:4.0` — note **-beta namespace**), ISO installers. **AKS and WSL: announced, not yet shipped** |
| WSL story | `wsl --install -d AzureLinux` demoed at Build as "coming shortly after"; still unavailable as of 2026-06-29 press coverage and our check today |

## 2. Package-parity audit (verified against packages.microsoft.com, 2026-07-02)

Every package in our Recipefile dnf list plus the podman stack exists in the Azure Linux
4.0 beta base repo (`packages.microsoft.com/azurelinux/4.0/beta/base/x86_64/`). Exact
NVRs observed:

| Need (images/vm/Recipefile + SELinux staging) | Azure Linux 4.0 beta base repo |
|---|---|
| podman | podman-5.8.0-2.azl4 (+ -remote, -machine, -docker) |
| netavark / aardvark-dns | netavark-1.17.2-2.azl4 / aardvark-dns-1.17.0-2.azl4 |
| crun | crun-1.26-2.azl4 |
| container-selinux | container-selinux-2.246.0-2.azl4 |
| systemd / -resolved / -networkd | systemd-258.4-4.azl4, systemd-resolved-258.4-4.azl4 |
| openssh-server | openssh-server-10.0p1-7.azl4 |
| dbus-broker | dbus-broker-37-3.azl4 |
| libcap / shadow-utils / openssl | libcap-2.76-4, shadow-utils-4.18.0-4, openssl-3.5.4-7 |
| selinux-policy-targeted / -devel | selinux-policy-targeted-43.4-4.azl4, selinux-policy-devel-43.4-4.azl4 |
| policycoreutils / checkpolicy / socat | policycoreutils-3.9-8, checkpolicy-3.9-3, socat-1.8.0.3-3 |

No ecosystem gap for our current install set. Caveat: **selinux-policy is 43.4** (Fedora
43 lineage) vs whatever Fedora 44 ships — our staged policies in `images/selinux/` must
be validated against the older policy base if we migrate.

## 3. Footprint comparison (verified via registry manifests, 2026-07-02)

| Image | Compressed size (amd64, single layer) |
|---|---|
| `mcr.microsoft.com/azurelinux-beta/base/core:4.0` | **42.6 MB** |
| `registry.fedoraproject.org/fedora:44` (our base) | **68.2 MB** |

~25 MB compressed (~40–60 MB installed) smaller; Azure Linux base omits pager/docs/locale
baggage ("does not even ship a pager"). This is a **disk/VHD** win, not a RAM win. Resident
RAM is dominated by our services (podman containers, headless, Ollama), which are identical
on either distro. Press claims of "~300 MB base" refer to the VM image, not the container
base.

## 4. Memory-model reality check — the operator's hypothesis does not hold

The hoped-for "native podman sharing kernel resources instead of pre-allocated RAM" is
**not how WSL2 allocates memory on either distro, and a distro swap changes nothing**:

- **All WSL2 distros share ONE utility VM and ONE Microsoft-built kernel.** The guest
  kernel is the same `WSL2-Linux-Kernel` whether the rootfs is Fedora, Ubuntu, or Azure
  Linux. Azure Linux 4.0's own 6.18 kernel and Hyper-V tuning are *not used under WSL* —
  the `.wslconfig [wsl2] kernel` is the inbox Microsoft kernel unless the user overrides it.
  Corollary: **our AF_HYPERV/vsock control wire (port 42420) is a kernel feature and is
  completely unaffected by distro choice.**
- **WSL2 memory is already dynamic, not pre-allocated.** The VM balloons up to the
  `.wslconfig` `memory=` cap (default **50% of host RAM** — hence our 7.3 GiB on the 16 GB
  reference laptop) and returns freed pages to Windows. `autoMemoryReclaim` now defaults
  to `dropCache` (immediate cache reclaim; `gradual` also available), plus `sparseVhd`
  for disk. There is no "finite pre-allocated RAM at VM launch" to escape; the cap is a
  ceiling, not a reservation.
- **Azure Linux has no special WSL resource-sharing integration.** Nothing in Microsoft's
  announcements claims a different memory model for Azure Linux under WSL; the WSL distro
  isn't even shipped yet. The closest real development is **wslc** (WSL 2.9.3 preview):
  virtiofs (~2x faster Windows file access), Consomme networking for VPN/proxy
  compatibility, and "improved memory reclaim mechanisms" — but wslc containers still run
  inside the same single utility VM under the same cap. It is an alternative container
  management surface (and one to watch — it could eventually compete with our
  distro+rootful-podman design), not a different resource model.

**What actually helps on 16 GB hosts** (independent of distro):

1. `.wslconfig` tuning: explicit `memory=` cap sized to coexist with the host browser/IDE,
   `[experimental] autoMemoryReclaim=gradual` (or keep default `dropCache`), `sparseVhd=true`,
   right-sized `swap=` (default 25% of RAM).
2. Fewer/lighter resident services in the VM — order 159 (Ollama dying at ~32 s, likely OOM
   against 7.3 GiB) is the live example; smaller inference models or lazy-start inference
   dwarf any base-image saving.
3. Smaller base image — real but minor (§3), mostly disk.

## 5. Benefit/cost assessment

**Real benefits of migrating:**
- ~37% smaller compressed base; leaner default install (smaller attack surface).
- Microsoft servicing: monthly signed updates, SBOMs, FIPS-track — attractive for the
  enclave's supply-chain story; same vendor as WSL itself once the official WSL distro ships.
- SELinux is first-class (ACL sibling ships enforcing) — aligned with our Phase-6 plan.
- Full package parity for our stack **verified** (§2), including the modern podman 5.8 /
  netavark / crun line; dnf5 is what Fedora 41+ already uses, so our `dnf install`
  invocations run unchanged.

**Costs and risks:**
- **Public preview with an explicit not-for-production warning; no GA date.** Our guest is
  the security boundary for the enclave — pinning it to a preview OS is a regression in
  posture, not an upgrade.
- **MCR namespace churn**: `azurelinux-beta/*` will move to `azurelinux/*` at GA; digests
  and URLs in `images/vm/manifest.toml` would need a second touch.
- **Fedora 43 snapshot** — one release *behind* our current Fedora 44 (selinux-policy 43.4,
  older toolchain); we'd be trading forward servicing for a temporarily older userland.
- No published `oci.tar.xz` artifact like Fedora's Container-Base download; we'd pull from
  MCR (buildah already does this in the materialize path; only the CI-fetch artifact story
  changes).
- WSL-specific behaviors (systemd-as-PID1 via wsl.conf, drvfs interop) are untested by us
  on azl4 and unsupported by Microsoft until the official WSL distro ships.

**Migration surface if/when we go** (small, by design of vm-recipe-provisioning):
1. `images/vm/Recipefile`: `FROM registry.fedoraproject.org/fedora:44` →
   `FROM mcr.microsoft.com/azurelinux/base/core:4.0` (post-GA namespace). dnf lines unchanged.
2. `images/vm/manifest.toml`: repin base digests per arch; repoint/retire the
   Fedora-Container-Base artifact URLs (MCR pull instead of fedoraproject download).
3. `crates/tillandsias-vm-layer/src/recipe/mod.rs` tests that assert the Fedora URLs.
4. `images/selinux/`: rebuild/validate staged policies against selinux-policy 43.4.
5. Litmus: `scripts/run-litmus-test.sh --size instant --phase pre-build` + full e2e forge
   launch on an imported azl4 guest; wsl.conf systemd boot + vsock wire + rootful podman
   + enclave bring-up.
Estimated effort: 8–16 h. Risk: moderate (preview churn is the dominant term; the pipeline
itself is parameterized and container images are distro-independent OCI).

## 6. Verdict: **DEFER with conditions**

The motivating hypothesis (better native memory sharing) **does not hold** — WSL2's memory
model is per-VM, dynamic, kernel-shared, and identical for every distro (§4). The genuine
wins (smaller base, Microsoft servicing, first-class SELinux) are real but modest, and today
they come bundled with a not-for-production preview, a beta registry namespace, an
unshipped WSL story, and a Fedora 43-era userland. Migrating now buys risk without solving
the stated problem.

**Re-evaluate and likely GO when ALL of:**
1. Azure Linux 4.0 reaches **GA** (non-beta MCR namespace, production support statement);
2. the **official WSL distro ships** (`wsl --install -d AzureLinux`) — evidence Microsoft
   tests the systemd/WSL path we depend on;
3. selinux-policy in azl4 validates our staged `images/selinux/` policies (or the Phase-6
   packet absorbs the delta);
4. a spike import (flatten MCR image → `wsl --import` → litmus instant + e2e forge launch)
   is green.

Meanwhile, capture the actual 16 GB-host wins in existing work: `.wslconfig` defaults
shipped by the tray (memory cap + autoMemoryReclaim + sparseVhd) and the order-159
inference-footprint fix.

## 7. Sources

- Microsoft Open Source blog (OSS Summit NA 2026 announcement):
  https://opensource.microsoft.com/blog/2026/05/18/from-open-source-to-agentic-systems-microsoft-at-open-source-summit-north-america-2026/
- Azure Linux 4.0 public-preview announcement (Microsoft Community Hub):
  https://techcommunity.microsoft.com/blog/linuxandopensourceblog/announcing-azure-linux-4-0-purpose-built-for-azure-now-in-public-preview/4524267
- heise online — "Azure Linux 4.0 launches with new container variant" (kernel 6.18 LTS,
  dnf5, systemd 258, SELinux/ACL, WSL "planned for later release"):
  https://www.heise.de/en/news/Azure-Linux-4-0-launches-with-new-container-variant-11351610.html
- Thurrott — Azure Linux 4.0 + Azure Container Linux GA:
  https://www.thurrott.com/cloud/336269/microsoft-announces-azure-linux-4-0-and-release-of-azure-container-linux
- Box of Cables — "Azure Linux 4.0 is Microsoft's first general-purpose Linux" (Fedora 43
  snapshot, dnf5 replaces tdnf, RPM 6.0, `wsl --install -d AzureLinux` coming soon):
  https://www.boxofcables.dev/azure-linux-4-0-is-microsofts-first-general-purpose-linux/
- Box of Cables — Azure Linux "Desktop" wslc mashup (no official WSL distro yet; manual
  container-image route): https://www.boxofcables.dev/azure-linux-desktop-a-build-2026-mashup-of-wslc-winui-reactor-and-azure-linux-4-0/
- Windows Latest (2026-06-29) — availability status, ~300 MB VM image, "not for production":
  https://www.windowslatest.com/2026/06/29/microsoft-called-linux-a-cancer-now-ships-its-own-free-distro-thats-nothing-like-ubuntu-or-fedora/
- WSL container (wslc) public preview (WSL 2.9.3; virtiofs, Consomme, memory-reclaim
  improvements; GA fall 2026):
  https://devblogs.microsoft.com/commandline/wsl-container-is-now-available-for-public-preview/
- WSL advanced settings (memory default 50% of host, autoMemoryReclaim default dropCache,
  sparseVhd, swap 25%): https://learn.microsoft.com/en-us/windows/wsl/wsl-config
- microsoft/azurelinux repo (3.0 + 4.0 branches; KIWI NG image builds; MCR/ISO/Marketplace
  publishing): https://github.com/microsoft/azurelinux
- Package listings verified directly (2026-07-02):
  https://packages.microsoft.com/azurelinux/4.0/beta/base/x86_64/Packages/
- Image sizes verified via registry manifest APIs (2026-07-02):
  `mcr.microsoft.com/v2/azurelinux-beta/base/core/manifests/4.0` (42.6 MB compressed) and
  `registry.fedoraproject.org/v2/fedora/manifests/44` (68.2 MB compressed).
