# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

## [0.1.0] – 2026-05-07

### Added
- `EffectView` — SwiftUI view implementing an Elm-style update loop with explicit side effects.
- `Effect` — enum with `.task`, `.action`, `.event`, `.cancel`, and `.sequence` cases.
- `Input` — event dispatcher with `send(_:)` (sync), `enqueue(_:)` (any actor), and `perform(_:)` (async, suspends until the update chain completes).
- `EnvReader` — helper view for reading an environment value and passing it to a content closure.
- `initialEvent` parameter on `EffectView` for firing a startup event on first appear.
- `initialEnv` parameter for injecting dependencies captured for the lifetime of the view identity.
- Hosted test suite covering lifecycle, state propagation, `initialEvent`, `perform`, task effects, cancel, action chains, sequence effects, identity reset, and env forwarding.
- GitHub Actions CI workflow (`swift test` on macOS).

[Unreleased]: https://github.com/couchdeveloper/EffectView/compare/0.1.0...HEAD
[0.1.0]: https://github.com/couchdeveloper/EffectView/releases/tag/0.1.0
