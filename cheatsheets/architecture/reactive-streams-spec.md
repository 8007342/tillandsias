---
tags: [reactive-streams, backpressure, async, event-driven, jvm, jdk-flow]
languages: [java, kotlin, scala]
since: 2026-04-25
last_verified: 2026-04-25
sources:
  - https://www.reactive-streams.org/
  - https://github.com/reactive-streams/reactive-streams-jvm
  - https://docs.oracle.com/en/java/javase/21/docs/api/java.base/java/util/concurrent/Flow.html
authority: high
status: current
---

# Reactive Streams (the spec)

@trace spec:agent-cheatsheets
@cheatsheet patterns/gof-observer.md, languages/java/rxjava-event-driven.md

## Provenance

- Reactive Streams official spec: <https://www.reactive-streams.org/> — the cross-vendor specification (Lightbend, Pivotal, Netflix, Red Hat, Twitter, Oracle co-authors)
- Reactive Streams for the JVM (reference impl + TCK): <https://github.com/reactive-streams/reactive-streams-jvm>
- JDK incorporation as `java.util.concurrent.Flow`: <https://docs.oracle.com/en/java/javase/21/docs/api/java.base/java/util/concurrent/Flow.html> (Java 21 LTS)
- **Last updated:** 2026-04-25

## Use when

You have a **stream** of asynchronous events whose producer might outpace its consumer. The Observer pattern alone (`cheatsheets/patterns/gof-observer.md`) breaks under load — the consumer drowns. Reactive Streams adds **backpressure**: the consumer signals how many items it's ready to handle, and the producer obeys.

## The four interfaces (the entire spec, in essence)

```text
interface Publisher<T>:
    method subscribe(s: Subscriber<? super T>)

interface Subscriber<T>:
    method onSubscribe(s: Subscription)
    method onNext(t: T)
    method onError(e: Throwable)
    method onComplete()

interface Subscription:
    method request(n: long)        // demand signal: "I'm ready for n more"
    method cancel()                 // unsubscribe

interface Processor<T, R>:
    extends Subscriber<T>, Publisher<R>
```

That's it — four interfaces. Implementations agree on the semantics encoded in the spec's 43 numbered rules. You almost never implement these by hand; you use a library.

## Common patterns

### Pattern 1 — explicit demand (pull-based backpressure)

```text
class MyConsumer extends Subscriber<Event>:
    Subscription sub
    method onSubscribe(s):
        sub = s
        sub.request(10)           // "send me 10 events"
    method onNext(event):
        process(event)
        sub.request(1)            // "send me 1 more" — strict 1-at-a-time

    method onError(e): log.error(e)
    method onComplete():           log.info("done")
```

### Pattern 2 — `request(Long.MAX_VALUE)` to opt out of backpressure

Useful when consumer is genuinely faster than producer can ever be (memory-bound source, in-memory transformations).

### Pattern 3 — pick a library, not a hand-roll

| Library | Origin | Notes |
|---|---|---|
| RxJava 3.x | Netflix → Reactive-Streams compliant since 2.0 | `Flowable<T>` is the RS-compliant type |
| Project Reactor | Pivotal / VMware | `Flux<T>`, `Mono<T>` — Spring's default |
| `java.util.concurrent.Flow` (JDK 9+) | Doug Lea (JEP 266) | Standard JDK; no convenient operators (you bring your own) |
| Akka Streams | Lightbend | Most enterprise-deep; integrates with Akka actors |

For Kotlin: prefer `kotlinx.coroutines.flow.Flow` — same shape, idiomatic Kotlin, interops with RS via `kotlinx-coroutines-reactive`.

## Common pitfalls

- **Implementing the interfaces by hand** — the spec has 43 numbered rules with subtle ordering / threading constraints. Use a library + Reactive Streams TCK if you must hand-roll.
- **Calling `onNext` after `onComplete` or `onError`** — spec violation. Rule §1.7. The TCK catches this; ad-hoc tests usually don't.
- **`request(0)` or negative** — undefined behaviour by the spec; canonical libraries reject with `IllegalArgumentException` per Rule §3.9.
- **Reentrant `onNext`** — the same thread calls `onNext` again before the first returns. Rule §3.3 forbids it. The library handles this; hand-rolls usually don't.
- **Dropping items silently** — when demand is 0, the producer MUST buffer or drop with `onError`. Silent drop is a common bug — backpressure-violation in `Flowable` will throw `MissingBackpressureException`.
- **Cold vs hot publishers** — `Flowable.fromIterable(...)` is cold (re-emits on each subscribe). `Subject` / `Processor` is hot (shared, one-shot per emission). Mixing them confuses tests.
- **Mixed sync/async scheduling** — `subscribeOn` vs `observeOn` in RxJava have opposite directions. The Reactor equivalent (`publishOn` vs `subscribeOn`) is similarly easy to mis-thread.

## See also

- `patterns/gof-observer.md` — the simpler pattern this builds on
- `languages/java/rxjava-event-driven.md` — RxJava-specific application
- `architecture/event-driven-basics.md` — system-level shape
