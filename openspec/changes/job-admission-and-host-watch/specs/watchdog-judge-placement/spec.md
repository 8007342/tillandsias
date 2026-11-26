# watchdog-judge-placement delta — watchdog-judge-placement

@trace order:2094-65yz, order:2094-s3ub, order:2094-p3i3, order:2094-zzg9, order:2094-7t4f, order:2094-3r2k

## ADDED Requirements

### Requirement: Placement is a table keyed by hardware capability

Where the watchdog's judge runs MUST be chosen from a data table whose rows
are keyed by what the capability probe reports, and MUST NOT be keyed by a
host's name. The first usable row MUST win and a CPU row MUST always be
last. A row MUST be taken only when its capability has been measured usable
on a host of that kind; a listed device with no engine MUST fall to the next
row with a named reason. `watch.status` MUST name the row that decided each
verdict.

> Delta: on 2026-11-17 the 2081 design placed the judge on NPU, GPU or CPU
> for one probed host and on CPU for every macOS and Windows host; the
> fleet matrix listed two XDNA2 NPUs and an Intel NPU as `engine-missing`
> and one integrated GPU as unscheduled by policy.

#### Scenario: An NPU with no engine is not taken
- **WHEN** the probe reports an NPU as present and `engine-missing`
- **THEN** the NPU row is refused by that name and the next row is tried
- **AND** no verdict is reported as decided on the NPU

#### Scenario: A host with no usable engine runs rules only
- **WHEN** no row is usable
- **THEN** every ambiguous episode escalates
- **AND** `watch.register` and `queue.submit` are still accepted

### Requirement: The integrated GPU row never touches the discrete GPU

On a host with an integrated and a discrete GPU, the integrated row MUST
name its device explicitly, MUST NOT load any part of the model on the
discrete device, and MUST NOT evict or delay a holder of the discrete
device.

> Delta: on 2026-11-17 the integrated GPU of a two-GPU host was unscheduled
> under `discrete-gpu-preferred`.

#### Scenario: A render on the discrete card is not delayed
- **WHEN** a verdict is decided on the integrated GPU while a job holds the discrete GPU
- **THEN** the discrete device's memory in use is unchanged by the verdict
- **AND** `gpu.status` lists the judge on the integrated device only

### Requirement: The judge has a memory ceiling set by the host

The judge tier a host may load MUST be bounded by the host's memory: none
under 12 GiB, a tier resident under 1 GiB from 12 to 24 GiB, a tier resident
under 3 GiB above 24 GiB. The judge's context window MUST be set explicitly
and MUST NOT be left at a runtime default. The judge MUST NOT load unless
the pressure level is `calm` and available memory covers its ceiling plus 1
GiB; otherwise the episode MUST escalate.

> Delta: on 2026-11-17 a 397 MB model was resident at 936 MB under the
> runtime's default 32,768-token context on macuahuitl, and a 7B model was
> resident at 6.9 GB.

#### Scenario: A laptop does not load a large judge
- **WHEN** a host with 16 GiB of memory is offered a tier resident above 1 GiB
- **THEN** that tier is refused by name and a smaller tier or rules-only is used

#### Scenario: The judge does not load under pressure
- **WHEN** an ambiguous episode occurs while the pressure level is `tight`
- **THEN** no judge is started
- **AND** the episode escalates

### Requirement: A judge outside a container is offered only with its own offline proof

A judge MAY run as a host process only on a platform where the accelerator
is unreachable from the guest, and only when enabled by an operator ruling
recorded for that platform. Such a judge MUST be denied all network by the
platform's process sandbox, MUST listen on no TCP port, MUST be started with
an empty environment and no access to a credential store, and MUST be
reachable by the tray only. A platform on which an outbound connection
attempted from inside the judge process succeeds MUST NOT take a host-judge
row.

> Delta: on 2026-11-17 the 2081 design required `--network none`, which
> exists only for a container, and so excluded Metal and the Windows-side
> NPU and integrated GPU.
>
> Ruling recorded for macOS, 2026-11-25 (2381-778w): the operator approved host-native inference as the
> macOS default ("I approve your suggestions on what we should reconsider", tlatoanis-macbook-air session).
> On macOS the host-judge row MAY therefore be taken, served by the same sandboxed host service as
> `inference-engine-slots` SLOT-10, and only while every condition above holds: no network, no TCP
> port, empty environment, no credential store, reachable by the tray only. Its residency is admitted
> under `job-admission-queue` (2381-zueb). No ruling is recorded yet for Windows.

#### Scenario: The host judge cannot connect out
- **WHEN** a connection to any address is attempted from inside the host judge process
- **THEN** it fails
- **AND** the row is recorded as taken only on a platform where it failed

#### Scenario: No ruling means the guest's CPU
- **WHEN** no operator ruling enables a host judge on a platform
- **THEN** the judge runs on CPU in the guest there
