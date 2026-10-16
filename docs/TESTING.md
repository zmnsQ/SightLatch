# Validation and acceptance

## Recorded results

The [2026-10-15 validation record](../CURRENT_VALIDATION_20261015.zh-CN.md) and [raw independent results](../tests/independent-results-20261015.txt) record eight Python source-contract checks plus C++ tests of shared firmware primitives. They are not a Swift build, full firmware build or device test.

```sh
python3 tests/check_source.py
c++ -std=c++17 tests/protocol_primitives_test.cpp -o /tmp/sightlatch-primitives
/tmp/sightlatch-primitives
```

These checks cover structural contracts, property-list parsing, cross-process state handling, source-level fail-closed paths, ASCII mappings and deadline wraparound.

## Required device verification

- Build all three Apple targets with the intended signing configuration.
- Compile and flash the complete ESP32-S3 firmware.
- Pair HID with the same phone running the app and test manual pointer/keyboard input.
- Confirm whether ReplayKit captures the pointer reliably on the target system.
- Validate one real model request and one low-risk action, including malformed response handling.
- Test physical STOP, app STOP, broadcast end, network loss, stale session, task cancellation, app termination and device restart.
- Verify that saved configuration, credentials and history survive expected restarts without reviving stopped commands.

The provided Apple workflow uses manual dispatch only. It does not run automatically on pushes and does not sign or install the application. Runner minutes may incur charges; confirm billing before triggering it.

Older `LINUX_VALIDATION.zh-CN.md` and `STATIC_REVIEW.zh-CN.md` documents are historical evidence. They do not supersede current results or establish native compatibility.
