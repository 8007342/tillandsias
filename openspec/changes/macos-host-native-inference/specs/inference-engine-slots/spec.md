## ADDED Requirements

### Requirement: SLOT-10 — On macOS the default slot is a tray-managed host-native service behind an allowlist

On macOS the active slot MUST default to a host-native inference service that the tray starts, leases and
stops, bound behind SLOT-6. A container-resident CPU slot MUST remain the fallback when the host service
is absent, refused or unhealthy, and the fallback MUST be named in status, never silent. The service MUST
satisfy every SLOT-6 condition. In addition:

1. It MUST listen on a loopback address or a unix socket only, and the guest MUST reach it only through the
   tray's vsock relay. No guest-routable address is ever exposed.
2. It MUST run in the platform process sandbox with no network access of its own, an empty environment,
   and no credential store. Model files arrive through the model cache, never through the service.
3. Between the relay and the service, an allowlist MUST pass only the chat-completion and embedding
   operations, and only for models named in the tier table. Every model-management operation (pull,
   create, copy, delete, push, template or modelfile edits) MUST be refused by name.
4. Each VM MUST present its own per-run credential (SLOT-6.5). The service MUST cap concurrent requests,
   prompt and completion tokens, and context length per credential, and a cap MUST refuse rather than
   queue without bound.
5. Model residency MUST be admitted against the host's one memory budget defined in `job-admission-queue`.
   The tray MUST NOT load a model that admission refuses.

The Linux and Windows NPU and GPU slots and this slot MUST present the same OpenAI-compatible contract
(SLOT-2), so agents see one interface on every platform.

> Delta: on 2026-11-25 the host route was opt-in (`TILLANDSIAS_HOST_VSOCK_PORT`) and every macOS model ran
> on the guest CPU. Operator ruling 2381-778w.

@trace spec:inference-engine-slots, order:2381-iy9u, order:2381-t39p

#### Scenario: A Mac with the host service uses it and the forge sees no change
- **WHEN** the tray starts on macOS and the host service is healthy
- **THEN** the active slot is the host service
- **AND** a forge container still resolves inference at `http://inference:11434`

#### Scenario: Model management is refused at the allowlist
- **WHEN** a request for a pull, create or delete operation arrives from the guest
- **THEN** it is refused by name before it reaches the service
- **AND** the service's model set is unchanged

#### Scenario: The service cannot connect out
- **WHEN** a connection to any address is attempted from inside the service process
- **THEN** it fails

#### Scenario: A missing host service falls back by name
- **WHEN** the host service is absent or unhealthy
- **THEN** the guest CPU slot serves
- **AND** status names the fallback and why

### Requirement: SLOT-11 — Apple Foundation Models is an optional first tier on macOS

On macOS a host MAY offer Apple's on-device Foundation Models as a first tier, for classification, routing
and short structured output. The tier MUST be offered only when the model reports itself available
(Apple Intelligence enabled, a supported language, any licence accepted by the operator). Otherwise it
MUST be skipped with a named reason. Its requests MUST pass through the same SLOT-10 allowlist and caps.
It MUST NOT be offered for embeddings, and MUST NOT be offered for any request whose context exceeds the
model's reported size. When it is unavailable or refuses, the request MUST fall through to the SLOT-10
default service.

@trace spec:inference-engine-slots, order:2381-rt4e

#### Scenario: An unavailable Foundation Model is skipped, not failed
- **WHEN** Apple Intelligence is disabled on the host
- **THEN** the tier is skipped with a named reason
- **AND** the request is served by the default host service

#### Scenario: Embeddings never take the Foundation Models tier
- **WHEN** an embedding request arrives
- **THEN** it is served by the default host service
