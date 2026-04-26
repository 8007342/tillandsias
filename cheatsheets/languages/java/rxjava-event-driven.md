---
tags: [java, rxjava, async, event-driven, reactive-streams, backpressure]
languages: [java, kotlin]
since: 2026-04-25
last_verified: 2026-04-25
sources:
  - https://github.com/ReactiveX/RxJava
  - https://reactivex.io/
  - https://www.reactive-streams.org/
authority: high
status: current
---

# RxJava — async / event-driven

@trace spec:agent-cheatsheets
@cheatsheet patterns/gof-observer.md, architecture/reactive-streams-spec.md

## Provenance

- RxJava 3.x repository (Apache 2.0): <https://github.com/ReactiveX/RxJava>
- ReactiveX project landing (cross-language family): <https://reactivex.io/>
- Reactive Streams cross-vendor spec (which RxJava implements via `Flowable`): <https://www.reactive-streams.org/>
- **Last updated:** 2026-04-25

## Use when

You have an asynchronous data source (UI events, sensor readings, network responses, message bus) and need to compose, filter, throttle, or join streams without thread-pool plumbing. If the source can produce faster than the consumer (high-frequency events, file streaming), use `Flowable` (with backpressure). If it's bounded and well-paced, `Observable` is fine.

For Tillandsias' forge: `java-21-openjdk-devel` is baked; add RxJava as a Maven/Gradle dependency per project (the forge has neither pre-installed but proxy allowlists Maven Central).

## Quick reference

| Type | Backpressure? | When |
|---|---|---|
| `Observable<T>` | No | UI events, ≤ ~1000/s, finite sources |
| `Flowable<T>` | Yes | High-volume streams, file IO, network firehose |
| `Single<T>` | n/a | Exactly one item or error |
| `Maybe<T>` | n/a | Zero or one item, or error |
| `Completable` | n/a | Side-effect, no value, just done/error |

```xml
<!-- Maven coordinates — note this is the io.reactivex.rxjava3 group -->
<dependency>
  <groupId>io.reactivex.rxjava3</groupId>
  <artifactId>rxjava</artifactId>
  <version>3.1.10</version>  <!-- check Maven Central for current -->
</dependency>
```

## Common patterns

### Pattern 1 — basic event-driven subscription

```java
import io.reactivex.rxjava3.core.Flowable;
import io.reactivex.rxjava3.schedulers.Schedulers;

Flowable.fromCallable(() -> fetchHttp("https://example.com"))
    .subscribeOn(Schedulers.io())               // do work on IO pool
    .observeOn(Schedulers.computation())        // observe on compute pool
    .subscribe(
        body  -> log.info("got {}", body),
        error -> log.error("failed", error),
        ()    -> log.info("done")
    );
```

### Pattern 2 — debounce + distinct (UI event firehose)

```java
keyEvents
    .map(KeyEvent::text)
    .debounce(300, TimeUnit.MILLISECONDS)
    .distinctUntilChanged()
    .switchMapSingle(query -> searchApi.search(query))
    .observeOn(uiScheduler)
    .subscribe(this::renderResults);
```

### Pattern 3 — combine two streams

```java
Flowable.combineLatest(
    cpuTemperatureStream,
    fanRpmStream,
    (temp, rpm) -> new Snapshot(temp, rpm)
).subscribe(snap -> dashboard.update(snap));
```

### Pattern 4 — error recovery

```java
publisher
    .retryWhen(errors -> errors
        .zipWith(Flowable.range(1, 3), (e, attempt) -> attempt)
        .flatMap(attempt -> Flowable.timer(attempt * 1000L, TimeUnit.MILLISECONDS))
    )
    .onErrorReturn(e -> Snapshot.empty())
    .subscribe(...);
```

### Pattern 5 — disposing on lifecycle

```java
import io.reactivex.rxjava3.disposables.CompositeDisposable;

CompositeDisposable disposables = new CompositeDisposable();
disposables.add(stream.subscribe(...));
// on shutdown:
disposables.dispose();   // unsubscribes ALL added subscriptions
```

## Common pitfalls

- **Forgetting to dispose** — leaks subscriptions and the threads behind them. Use `CompositeDisposable` tied to your component's lifecycle (Activity, Service, Scope).
- **`Observable` for high-volume** — no backpressure → OOM under load. Use `Flowable` whenever the source can outrun the consumer.
- **`subscribeOn` vs `observeOn` confusion** — `subscribeOn` sets the thread the upstream RUNS on (sticks to the topmost call). `observeOn` switches threads for everything DOWNSTREAM. Multiple `subscribeOn`s get reduced to the FIRST.
- **Blocking inside `onNext`** — blocks the scheduler thread. Use `flatMap`/`switchMap` to dispatch async work.
- **`Schedulers.computation()` for IO** — wrong pool. `computation()` is fixed-size CPU pool; IO needs `Schedulers.io()` (cached, expandable). Reversing them starves CPU work or balloons the IO pool.
- **`subscribe()` with no `onError`** — exceptions become `OnErrorNotImplementedException` and crash the process via the global error handler. Always handle `onError`.
- **Mixing `Single`/`Maybe`/`Completable` arithmetic** — composing them needs explicit `.toFlowable()` or `.toObservable()` adaptors. Forgetting yields cryptic compile errors.
- **`merge` vs `concat`** — `merge` interleaves; `concat` waits for the first to complete. Picking the wrong one silently changes ordering.

## When to use Kotlin Flow instead

If the project is Kotlin-first, `kotlinx.coroutines.flow.Flow` is more idiomatic and integrates with structured concurrency. RxJava interop is one-way via `kotlinx-coroutines-reactive`. New Kotlin code: prefer `Flow`. Polyglot Java/Kotlin codebase: pick one and stick with it.

## See also

- `architecture/reactive-streams-spec.md` — the spec underneath `Flowable`
- `patterns/gof-observer.md` — the structural ancestor
- `languages/java.md` (DRAFT) — Java syntax baseline
- `build/maven.md` (DRAFT) — adding the dep
