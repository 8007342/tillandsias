---
title: Install IaC tooling (terraform/tofu, kubectl, helm)
gap: "missing_tools: terraform, tofu, kubectl, helm — infrastructure-as-code and Kubernetes tooling"
category: runtime-tool
status: proposed
proposed_at: 2026-06-16T08:00:00Z
changes:
  - file: images/default/Containerfile
    description: |
      Install terraform (or OpenTofu as free alternative) via microdnf or
      hashicorp repo. Install kubectl and helm via microdnf or upstream
      releases.
---

## Gap

Multiple diagnostic runs (`diagnostics_20260604T002348Z-summary.md`,
`diagnostics_20260614T062505Z-summary.md`) report missing IaC tooling.

Terraform/OpenTofu are the industry standard for infrastructure provisioning.
Kubectl and Helm are essential for Kubernetes workload management. These tools
are frequently needed in cloud-native development workflows.

## Evidence

- `diagnostics_20260604T002348Z-summary.md`: missing_tools includes terraform, tofu
- `diagnostics_20260614T062505Z-summary.md`: missing_tools includes kubectl, helm, terraform

## Privacy/Isolation Assessment

- terraform/tofu: single static Go binaries; configure provider auth at runtime
- kubectl: single static Go binary; configure kubeconfig at runtime
- helm: single static Go binary; uses kubectl for deployment
- All tools are local executables with no daemon requirement
- Kubeconfig/credentials would need to be provided by the user at runtime
- **Safe within the existing privacy/isolation envelope**
