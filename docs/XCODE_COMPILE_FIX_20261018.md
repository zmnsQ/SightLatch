# Xcode compilation correction, 2026-10-18

This fixes the reported pointer-calibration fence type mismatch and ReplayKit
`@Sendable` closure captures. Linux checks below do not substitute for the
unsigned Apple-SDK build or installation on a phone.

## Broadcast isolation audit

`SampleHandler` uses explicit `@unchecked Sendable` because ReplayKit callbacks,
Dispatch closures and the async network task share the handler. This does not
turn off compiler concurrency checking. The invariant is:

- All mutable capture/session state, including `CIContext` use, is confined to
  its private serial capture queue.
- Queue-only helpers assert that queue at runtime with `dispatchPrecondition`.
- Frame pixel reads/encoding complete synchronously on the capture queue before
  the ReplayKit callback returns; borrowed sample data never enters an escaping closure.
- Stale-generation queued pause/completion/recovery callbacks recheck the generation.
- The network task receives immutable value snapshots. It reads/updates capture
  state only through `queue.sync`/`queue.async`.
- The immutable SharedStore reference may be used by the network task because
  SharedStore serializes file operations itself and locks cross-process writes.
- STOP now snapshots `config` on the capture queue before launching its task.
  Previously pause/finish/stop closures could read changing configuration off
  that queue. All three call the same queue-only helper now.

The explicit discarded result on `updateCommand` removes the reported unused
`try?` warning; the existing fail-safe command revocation behavior is unchanged.

## Regression checks

- `python3 tests/run_broadcast_concurrency_tests.py` compiles the actual production
  STOP helper under Swift 6, complete concurrency checking, warnings as errors.
  100 queued STOPs retain their original configuration when the owner replaces
  it immediately. Structural checks require queue assertions on every helper.
- Calibration test runners compile production state, device response and store
  definitions rather than parallel copies of their field types.
- `python3 tests/check_source.py` checks project and safety wiring.

The broadcast harness does not compile ReplayKit, CoreImage or Apple SDK imports.
The repository's unsigned iOS workflow must compile all three real targets with
Xcode 26+ to establish the actual build result. No signing/device validation is
claimed here.
