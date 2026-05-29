---
tags: [design-pattern, gof, observer, event-driven, decoupling, behavioural]
languages: []
since: 2026-04-25
last_verified: 2026-04-27
sources:
  - https://en.wikipedia.org/wiki/Observer_pattern
  - https://refactoring.guru/design-patterns/observer
  - https://reactivex.io/intro.html
authority: community
status: current

# v2 — tier classification (cheatsheets-license-tiered)
tier: pull-on-demand
summary_generated_by: hand-curated
bundled_into_image: false
committed_for_project: false
pull_recipe: see-section-pull-on-demand
---

# Observer pattern (GoF)

@trace spec:agent-cheatsheets
@cheatsheet architecture/event-driven-basics.md

## Provenance

- Wikipedia, "Observer pattern": <https://en.wikipedia.org/wiki/Observer_pattern> (CC-BY-SA 4.0)
- Refactoring.Guru, "Observer": <https://refactoring.guru/design-patterns/observer> (educational)
- Original definition: E. Gamma, R. Helm, R. Johnson, J. Vlissides, *Design Patterns: Elements of Reusable Object-Oriented Software* (1994), p.293
- ReactiveX intro (Observer's reactive descendant): <https://reactivex.io/intro.html>
- **Last updated:** 2026-04-25

## Use when

A **subject** has state changes that an unknown number of **observers** want to react to, AND the subject must NOT depend on the observers (no compile-time or run-time coupling beyond a tiny notification interface).

Classic use cases: UI event handlers, model→view updates in MVC, event-bus subscriptions, reactive streams (Observer is RxJava/Rx*'s structural ancestor — see `cheatsheets/architecture/reactive-streams-spec.md`).

## Quick reference

| Role | Responsibility |
|---|---|
| Subject | Holds state; maintains list of observers; calls `notify()` on change |
| Observer (interface) | Defines `update(event)` contract |
| Concrete Observer | Implements `update(event)` with the reaction-specific behaviour |
| Client | Wires observers to subjects |

## Common patterns

### Pattern 1 — push (subject sends data with the notification)

```text
interface Observer<T>:
    method update(event: T)

class Subject<T>:
    observers = []
    method subscribe(o: Observer<T>): observers.add(o)
    method unsubscribe(o: Observer<T>): observers.remove(o)
    method notify(event: T):
        for o in observers: o.update(event)
```

### Pattern 2 — pull (subject signals "changed", observer queries state)

```text
interface Observer:
    method on_change()

class Subject:
    observers = []
    method state(): ...
    method notify():
        for o in observers: o.on_change()    // observer reads state itself
```

Push is simpler when events are small and self-contained. Pull scales better when state is large, observers want different views, or computing the event eagerly is wasteful.

### Pattern 3 — lambdas / closures over the interface (modern languages)

```text
subject.subscribe { event -> log.info("got {event}") }
```

Most modern languages let you pass a function value where an Observer interface is expected. RxJava's `Observable.subscribe(onNext, onError, onComplete)` is exactly this.

## Common pitfalls

- **Memory leaks via dangling references** — observers hold references that prevent GC. Always provide an `unsubscribe` method AND a way for the observer to forget the subject (weak references work in some languages; explicit lifetimes in Rust).
- **Re-entrancy** — observer callback mutates the subject, which fires another notify, which mutates again. Snapshot the observer list before iterating, OR document strict no-mutation contract.
- **Order of notification** — Observers should NOT depend on the order they were subscribed in. If they do, you've coupled them to subscription order; refactor to explicit dependencies.
- **Synchronous-vs-async confusion** — push is synchronous by default; if observer work is heavy, the subject blocks. Either offload to a worker queue or move to a Reactive Streams model with backpressure.
- **Exception in one observer kills the rest** — `notify()` SHOULD catch per-observer exceptions and continue. The "first failing observer breaks the chain" trap is the classic Java listener bug.
- **Observer thrash** — every state change wakes every observer. Coalesce / debounce when state changes faster than observers can keep up.

## When to NOT use Observer

- One-shot events with a known caller — direct method call is simpler.
- High-throughput streams — use Reactive Streams (proper backpressure) instead. See `architecture/reactive-streams-spec.md`.
- Event bus across processes/network — use a message broker, not in-process Observer.

## Pull on Demand

> This cheatsheet's underlying source is NOT bundled into the forge image.
> Reason: upstream license redistribution status not granted (or off-allowlist).
> See `cheatsheets/license-allowlist.toml` for the per-domain authority.
>
> When you need depth beyond the summary above, materialize the source into
> the per-project pull cache by following the recipe below. The proxy
> (HTTP_PROXY=http://proxy:3128) handles fetch transparently — no credentials
> required.

<!-- TODO: hand-curate the recipe before next forge build -->

### Source

- **Upstream URL(s):**
  - `https://en.wikipedia.org/wiki/Observer_pattern`
- **Archive type:** `single-html`
- **Expected size:** `~1 MB extracted`
- **Cache target:** `~/.cache/tillandsias/cheatsheets-pulled/$PROJECT/en.wikipedia.org/wiki/Observer_pattern`
- **License:** see-license-allowlist
- **License URL:** https://en.wikipedia.org/wiki/Observer_pattern

### Materialize recipe (agent runs this)

```bash
set -euo pipefail
TARGET="$HOME/.cache/tillandsias/cheatsheets-pulled/$PROJECT/en.wikipedia.org/wiki/Observer_pattern"
mkdir -p "$(dirname "$TARGET")"
curl --fail --silent --show-error \
  "https://en.wikipedia.org/wiki/Observer_pattern" \
  -o "$TARGET"
```

### Generation guidelines (after pull)

1. Read the pulled file for the structure relevant to your project.
2. If the project leans on this tool/topic heavily, generate a project-contextual
   cheatsheet at `<project>/.tillandsias/cheatsheets/patterns/gof-observer.md` using
   `cheatsheets/TEMPLATE.md` as the skeleton.
3. The generated cheatsheet MUST set frontmatter:
   `tier: pull-on-demand`, `summary_generated_by: agent-generated-at-runtime`,
   `committed_for_project: true`.
4. Cite the pulled source under `## Provenance` with `local: <cache target above>`.

## See also

- `architecture/event-driven-basics.md` — Observer is the in-process building block; EDA is the system shape
- `architecture/reactive-streams-spec.md` — the modern descendant with backpressure
- `languages/java/rxjava-event-driven.md` — Observer applied in Java/RxJava
- `patterns/gof-strategy.md` — sister behavioural pattern
