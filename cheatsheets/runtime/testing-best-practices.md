---
tags: [testing, unit-tests, integration-tests, tdd, rust, aws, azure, google-cloud]
languages: [rust, bash]
since: 2026-05-12
last_verified: 2026-05-12
sources:
  - https://doc.rust-lang.org/stable/cargo/guide/tests.html
  - https://doc.rust-lang.org/book/ch11-01-writing-tests.html
  - https://doc.rust-lang.org/book/ch11-02-running-tests.html
  - https://docs.aws.amazon.com/wellarchitected/latest/devops-guidance/qa.ft.1-ensure-individual-component-functionality-with-unit-tests.html
  - https://docs.aws.amazon.com/wellarchitected/latest/framework/ops_dev_integ_test_val_chg.html
  - https://docs.aws.amazon.com/prescriptive-guidance/latest/best-practices-cdk-typescript-iac/development-best-practices.html
  - https://learn.microsoft.com/en-us/azure/well-architected/operational-excellence/testing
  - https://cloud.google.com/docs/terraform/best-practices/testing
authority: high
status: current
tier: bundled
summary_generated_by: hand-curated
bundled_into_image: true
committed_for_project: false
---

# Testing Best Practices

@trace spec:podman-container-spec, spec:podman-container-handle, spec:podman-orchestration, spec:security-privacy-isolation

**Use when**: designing Rust unit tests, layered verification chains, or
pure spec/handle builders that should be testable without live infrastructure.

## Provenance

- Rust testing guide: <https://doc.rust-lang.org/book/ch11-01-writing-tests.html>
- Cargo test guide: <https://doc.rust-lang.org/stable/cargo/guide/tests.html>
- Rust test control guide: <https://doc.rust-lang.org/book/ch11-02-running-tests.html>
- AWS Well-Architected unit testing guidance: <https://docs.aws.amazon.com/wellarchitected/latest/devops-guidance/qa.ft.1-ensure-individual-component-functionality-with-unit-tests.html>
- AWS change validation guidance: <https://docs.aws.amazon.com/wellarchitected/latest/framework/ops_dev_integ_test_val_chg.html>
- AWS TDD guidance for CDK: <https://docs.aws.amazon.com/prescriptive-guidance/latest/best-practices-cdk-typescript-iac/development-best-practices.html>
- Azure testing strategies: <https://learn.microsoft.com/en-us/azure/well-architected/operational-excellence/testing>
- Google Cloud Terraform testing guidance: <https://cloud.google.com/docs/terraform/best-practices/testing>
- **Last updated:** 2026-05-12

## Source-backed takeaways

- Rust unit tests are ordinary functions annotated with `#[test]`, and Cargo can run them directly from crate sources or `tests/` integration files.
- `cargo test` accepts filters, and arguments after `--` are forwarded to the test harness, which is useful for narrow litmus loops.
- Rust docs distinguish unit tests, integration tests, and doctests; keep pure builders and small state machines in unit tests.
- AWS guidance recommends isolated unit tests with fakes or mocks for external dependencies, so component tests stay fast and repeatable.
- AWS change-validation guidance says testing should cover code, configuration, security controls, and operations procedures before delivery.
- AWS CDK guidance recommends fine-grained assertions over overreliance on snapshots alone when the desired contract is specific.
- Azure guidance recommends testing early, testing continuously, and using layered test coverage so failures are easier to isolate.
- Google Cloud Terraform guidance recommends breaking infrastructure into modules and testing those modules individually rather than treating the whole architecture as one unit.

## Project notes

- For Tillandsias, pure spec builders such as `ContainerSpec` should be tested with deterministic unit tests and no live Podman daemon.
- Higher-level orchestration should use fake backends or command-shape litmuses first, then widen to runtime-backed checks.

## See also

- `openspec/specs/podman-container-spec/spec.md`
- `openspec/specs/podman-container-handle/spec.md`
- `openspec/specs/podman-orchestration/spec.md`
