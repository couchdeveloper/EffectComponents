# Runtime Design

This note describes the runtime model behind `EffectView`.

It is not an API tutorial. The goal is to make the runtime's invariants explicit, explain why the implementation looks the way it does, and preserve the design intent as the library evolves.

In short, `EffectView` is an event-driven runtime built around a finite state machine model of computation. Events drive state transitions, effects describe operations to perform, and the runtime executes and manages those operations while preserving ordered state reduction.

At a high level, effects come in two forms:

- Actions are inline effect steps in the current computation cycle. Unlike tasks, they remain part of the current event chain even when they suspend.
- tasks are managed asynchronous operations; they run outside the current reduction step, may be tracked by logical identifier, and can feed events back into the system later

Two earlier articles describe adjacent concerns from the public API side:

- [Taming async tasks in SwiftUI views](TamingAsyncTasksInSwiftUIViews.md) explains why the library needs runtime-managed effects instead of relying on SwiftUI's `.task` modifier.
- [Using Env for dependency injection](UsingEnvForDependencyInjection.md) explains how dependencies are captured and forwarded into effects.

This document focuses on the runtime itself: event processing, back pressure, cancellation, continuations, and the split between domain work and runtime control.

---

## The problem this runtime solves

At the feature level, `EffectView` wants a simple contract:

- state changes only in `update`
- effects are declared, not performed inline
- async work can send events back into the system
- callers can choose how to dispatch an event: post it and return immediately, send it and wait for the current computation cycle, or request it and suspend until the terminal result is available

That contract becomes significantly harder to uphold once async actions and runtime-managed tasks exist.

In particular, the runtime must answer these questions:

1. Can event processing be re-entered while an async action is suspended?
2. What happens when a hard cancellation or fatal runtime error arrives while an event chain is mid-flight?
3. Who owns a request continuation at each phase of execution?
4. How should overlapping callers apply back pressure to the system?
5. Which concerns belong to the transducer state machine, and which belong to the runtime itself?

The current design answers those questions explicitly rather than implicitly.

---

## Design goals

The runtime is intentionally designed around the following goals:

1. Preserve a single ordered mutation path for domain state.
2. Support async effects and async actions without pushing buffering logic into transducer state.
3. Allow callers to use ordinary suspending functions as the back pressure mechanism.
4. Permit immediate runtime interruption while a regular event chain is suspended.
5. Keep the implementation small enough that the invariants are locally understandable.

These goals are Swift-shaped. They rely on actor isolation, structured concurrency, typed continuations, and `Sendable` boundaries. The same design may not map directly to languages that lack those tools.

---

## The two-path model

The runtime has two distinct execution paths:

- `compute(...)` processes regular domain events.
- `control(...)` processes runtime control events.

This split is fundamental.

### `compute(...)`

`compute(...)` is the domain path. It:

- reads and mutates transducer state
- calls `update`
- executes returned effects
- may suspend while awaiting async actions
- may transfer a request continuation into a managed task

Because `compute(...)` is the path that can mutate state, it must not be re-entered.

### `control(...)`

`control(...)` is the runtime path. It:

- does not call `update`
- must not mutate transducer storage
- may cancel the runtime or latch a system failure
- may run while a regular `compute(...)` invocation is suspended

This is not merely acceptable. Once async actions exist, it is the correct model. A hard-stop control path must be able to intercept a suspended event chain immediately. Otherwise shutdown would be delayed until the action returns, which would weaken runtime cancellation semantics substantially.

---

## Core invariants

The runtime is designed around these invariants:

1. `compute(...)` is never re-entered.
2. `control(...)` may interleave with a suspended `compute(...)`.
3. `control(...)` must never mutate transducer storage.
4. All regular event entry points pass through the same gate before entering `compute(...)`.
5. After every suspension point inside `compute(...)`, runtime cancellation must be re-checked before more work is committed.
6. A thrown `compute(...)` does not consume the request continuation; the caller remains responsible for resuming or failing it.
7. Shutdown and latched failure state remain centralized in one runtime authority.

If future changes violate one of these rules, they should be treated as a design change, not as an incidental refactor.

---

## Why `compute(...)` is gated

Without a gate, an awaited async action yields the system actor, allowing another task to enter the runtime and call `compute(...)` again. That would break the single ordered mutation model.

The runtime therefore uses a gate in front of `compute(...)`.

Conceptually, the gate means:

- if no regular event chain is active, the caller enters immediately
- if a regular event chain is already active, the next caller suspends until admission

This is a strict back pressure model.

The runtime does not primarily buffer events. Instead, callers wait.

### Why not an event buffer?

An event buffer is viable, but it encodes a different policy:

- the runtime owns queued events
- overflow policy becomes part of the design
- buffering and scheduling concerns become more prominent than caller suspension

The current design chooses the opposite center of gravity:

- the caller owns its event until admitted
- suspension is the back pressure mechanism
- structured concurrency expresses the waiting relationship directly

In practice, this lets call sites remain simple: they use suspending functions, and back pressure emerges from the language's existing async model rather than from a separate buffering abstraction.

### Why the gate can stay simple

The gate itself can stay small because it lives on the system actor. It does not need mutexes or cross-thread synchronization primitives. Its job is only to serialize admission to `compute(...)`.

Implementation details may evolve, but conceptually the gate is a FIFO of waiting senders or continuations, not a mailbox of events.

---

## Event entry semantics

The runtime exposes three relevant caller-facing modes:

- fire-and-forget event submission
- synchronous event submission
- request-style submission with a result continuation

These modes differ in how much of the event chain the caller waits for, but they all rely on the same underlying serialization rules for regular events.

### Fire-and-forget dispatch (`post`)

A fire-and-forget call schedules work and returns immediately. The caller does not wait for `compute(...)` to run.

This is intentionally the weakest back pressure mode. It is useful, but it is also the deliberate escape hatch: callers can create pending work without themselves awaiting admission.

### Synchronous disaptch (`send`)

A synchronous `send` means:

- the caller waits for the event chain it started
- the caller does not directly await unrelated managed tasks unless the chain reaches a request-style effect
- the system guarantees that regular event reduction remains serialized

The important nuance is that "synchronous" here is semantic, not literally non-suspending. If an async action runs inline, `send` may suspend while still preserving single-entry regular event reduction.

### Request/response dispatch (`request`) 

A request carries a continuation through the event chain until the chain terminates, transfers the continuation into a managed task, or throws out of `compute(...)`.

This is the runtime's bridge between event-driven logic and ordinary async/await callers.

### When dispatch fails 

Dispatching an event into the runtime can fail for various reasons. For example: an internal event buffer may be full, the actor may have been cancelled, the actor may already be deinitialized, or the transducer may have been cancelled.

Depending on the context, some of these failures are benign. For example, in a SwiftUI Button action: 

```swift
Button("Start") { 
  send(.start) 
}
```
In this case, when sending the "start" event fails, it is often not a critical error. A user may just try again.
 
However, there are other cases where a failure means a critical error. For example, in an operation when it finishes and the transducer logic awaits and requires a completion event: 
 
 ```swift
 static func refreshMovies() -> Effect {
    run(id: "refresh") { input, env in
        let result = await env.movieFetch()
        try? input(.fetchMoviesCompletion(result)) // Do not use `try?` when dispatching completion events
    }
}
```   
In the case above, if event dispatch fails and the error is ignored (`try?`), the transducer will never receive a completion event. This might mean it stays in "loading" mode indefinitely and silently ignores any other event unless it sees the completion event.

Thus, when the event cannot be dispatched, it is better to forward the failure into the system, that is, letting it throw the error:
 ```swift
 static func refreshMovies() -> Effect {
    run(id: "refresh") { input, env in
        let result = await env.movieFetch()
        try input(.fetchMoviesCompletion(result))
    }
}
```
The runtime now detects the error, treats it as a critical failure, and cancels the transducer. Now, the transducer "knows" it is in a failure mode, and any attempt to send events into it will fail early at the call site.


---

## Async actions

Async actions exist to model a bounded awaited step that must remain logically inside the current event chain.

They are intentionally different from managed tasks.

An async action:

- runs inline as part of the current `compute(...)` chain
- does not create its own task identity
- does not participate in task overlap policies like `subscribe` or `switchToLatest`
- may suspend
- must be followed by a cancellation re-check before its result is trusted

This makes async actions suitable for short prerequisite steps such as:

- actor bootstrap before later events are allowed to proceed
- establishing an authorization token or capability handle
- awaiting a bounded dependency precondition before the next event can be interpreted correctly

Async actions are not the right tool for long-running background work, subscriptions, retry loops, or overlapping work that needs runtime-managed identity. Those belong to managed tasks.

---

## Post-suspension cancellation checks

Because `control(...)` may intercept a suspended `compute(...)`, an awaited async action cannot simply resume and continue as if nothing happened.

After an async suspension point, `compute(...)` must re-check runtime cancellation through the runtime's central cancellation state before it:

- resumes a request continuation
- feeds the returned event back into the loop
- mutates more state indirectly through another call to `update`

The important detail is that this re-check should use the runtime's central cancellation mechanism rather than ad-hoc boolean tests.

That preserves the latched shutdown reason and keeps the thrown error consistent with the rest of the runtime's boundary behavior.

---

## Shutdown and failure authority

The runtime needs one authoritative place for shutdown and latched failure state.

In the current implementation, much of that responsibility lives in `TaskManager`. A future runtime `Context` could own that state more directly while still preserving the same semantic contract.

Conceptually, this authority owns:

- managed task tracking
- overlap policy for logically identified tasks
- task waiter sets
- latched cancellation and shutdown state
- the distinction between normal managed cancellation and fatal runtime failure

This is why `checkCancellation()` is such a central primitive. It turns internal runtime state into a public execution rule: if the runtime is no longer accepting work, the current path must stop.

Keeping this authority centralized prevents the runtime from drifting into multiple slightly different notions of cancellation.

---

## Continuation ownership

Request continuations intentionally have asymmetric ownership.

During regular synchronous computation, the continuation is owned by the current `compute(...)` frame.

If the chain reaches a managed task, ownership transfers to `TaskManager`, which resumes the waiting caller when that task completes, fails, or is cancelled.

If `compute(...)` throws, the continuation is not consumed by `compute(...)`. The caller that entered `compute(...)` remains responsible for resuming or failing it.

This rule is especially important for interrupted async actions:

- the async action resumes
- `compute(...)` re-checks cancellation
- `compute(...)` throws because the runtime was invalidated mid-flight
- the outer caller maps or forwards that failure and resumes the continuation exactly once

That ownership discipline avoids double-resume bugs and keeps failure propagation localized.

---

## Managed tasks and overlap semantics

Managed tasks solve a different problem from async actions.

They represent asynchronous work that should be tracked by logical identifier and governed by overlap policy.

The runtime currently supports at least two overlap behaviors:

- `switchToLatest`: cancel the current physical task instance, keep the waiter set, and move those waiters to the replacement task
- `subscribe`: keep the running task and attach the new waiter to the existing logical work

This model gives the runtime a principled answer to overlapping requests without requiring feature code to store task handles manually.

It also means the runtime can express request/response style behavior without forcing every transducer to implement its own queue or subscription bookkeeping in domain state.

---

## Why `control(...)` is a promising extension point

The `compute(...)` / `control(...)` split does more than enable interruption.

It also creates a real control plane.

Because `control(...)` is runtime-facing and storage-safe, it can host future runtime features without polluting the domain event model.

Plausible extensions include:

- diagnostics and runtime introspection
- fault injection in tests
- tracing and instrumentation
- runtime lifecycle commands
- reporting current gate or task-manager state

For example, a diagnostic control event could print or export current runtime context, including task-manager state, without pretending that diagnostics are part of the feature's domain event vocabulary.

This is one of the design's strongest architectural consequences: operational concerns get a dedicated channel with dedicated rules.

---

## Why this is a Swift-native design

This runtime model leans heavily on Swift's specific features:

- actor isolation provides serialization boundaries
- structured concurrency expresses back pressure naturally as suspension
- continuations bridge event-driven logic to async/await callers
- `Sendable` strengthens boundary discipline
- first-class closures make dependency injection through `Env` lightweight

That combination makes it realistic to implement what is effectively an FSM effect actor without introducing a large framework or an elaborate supervisory architecture.

Other languages may need different primitives, especially if they lack actor isolation or typed continuation-style suspension. In Swift, this design maps naturally onto the language rather than fighting it.

---

## Testable consequences

The following behaviors should remain pinned down by tests:

1. `compute(...)` is not re-entered while another regular event chain is active.
2. A control event may cancel the runtime while `compute(...)` is suspended in an async action.
3. After that interruption, the suspended `compute(...)` frame does not continue processing returned events.
4. A request interrupted during an async action completes with the correct runtime failure semantics.
5. Managed task overlap policies continue to preserve waiter ownership correctly.
6. Control events never mutate transducer storage.

These tests are not implementation details. They are executable statements of the design.

---

## Summary

The runtime is intentionally built around four ideas:

1. regular event reduction is serialized through gated `compute(...)`
2. runtime control is separated into ungated `control(...)`
3. caller suspension provides the primary back pressure mechanism
4. `TaskManager` centralizes shutdown and task-lifecycle semantics

This gives `EffectView` a runtime that stays small in code size while still supporting async actions, request/response bridging, runtime-managed tasks, immediate interruption, and future runtime control features.

The design is intentional, not accidental.
