# Device check feedback repair

## Verified source causes (base f9acee9)

- The old settings button (`HomeView.swift`, “保存并检查局域网 / BLE”) only started a task. Its text did not reflect `probing`; notices were rendered several sections below the button.
- `probe()` called `save()` before enabling `probing`. Address validation required `http://`; entering the private IP shown by the board therefore failed before any network request. The error was below the visible device controls.
- `guard !refreshingDeviceStatus` silently ignored a manual check while the foreground polling request was pending.
- The shared refresh catch discarded the underlying network/HTTP error.
- Full settings validation allowed an empty model but an unfinished AI endpoint could still block hardware onboarding.

The reported device and exact installed binary have not been inspected. These are verified source paths, not a claim that the physical device or its token is faulty. This checkout does not contain commit fb2b790, so the binary-to-source mapping remains unverified.

## Repair

`probeState` provides `.saving`, `.checking`, `.success`, `.failure`, an inline message and typed error. The UI owner renders it immediately below the device button and displays progress during `probing`.

Hardware-only saving persists the explicitly entered device address/token without validating or saving an unfinished model/API form. Address normalization adds `http://` only when missing and trims surrounding whitespace. Existing full endpoint strings are retained; credentials are never copied from one endpoint account to another. Only RFC1918 IPv4 or `.local` hosts are permitted, with no user info, query, fragment or additional path. Device changes invalidate prior calibration confirmation. Failed saving does not send a request. Network failure retains the entered token; only a successful check clears its input field, and stored Keychain credentials are not deleted.

A manual probe supersedes older background observations and cannot be blocked by their in-flight flag. Repeated taps are coalesced. `cancelProbe()` cancels the network task and invalidates the probe identity; closing/reopening the sheet cannot let an old result overwrite a retry or clear its spinner. Both target and STOP-generation checks reject stale completion. It only reads `GET /v1/status`; no BLE scan, pairing, ARM, HID action or token logging is introduced. Existing epoch/STOP control paths remain unchanged.

`URLRequest.timeoutInterval` remains 3 seconds and the ephemeral URLSession resource timeout remains 15 seconds (including body reads); connectivity waiting is explicitly off. Failures distinguish HTTP 401/403, timeout, known permission denial, ATS and credential/save failures. iOS can report a denied local-network permission as a generic network error, so the UI does not falsely assert permission was granted or denied from an ambiguous error.

## ATS review

Both app and broadcast extension already declare `NSAllowsLocalNetworking = YES` and local-network usage text. Apple's current documentation describes this key as covering unqualified domains, `.local`, and IPv4/IPv6 addresses. There is no evidence here that ATS is the reported failure and no broad `NSAllowsArbitraryLoads` exception was added.

https://developer.apple.com/documentation/bundleresources/information-property-list/nsapptransportsecurity/nsallowslocalnetworking

## Validation

- `tests/run_probe_tests.sh` compiles actual production address policy, error classification, `saveDeviceConnection`, `refreshDeviceStatus`, and `probe` with fake persistence/hardware seams. Tests exercise bare IP/port, unsafe-address rejection, independent AI form, Keychain/App Group write failure, 401/403, timeout, permission/ATS error mapping, loading, repeated taps, late background result, target changes, close/retry with a late old response and STOP cancellation.
- `tests/run_agent_tests.sh` passes existing agent lifecycle, hardware cancellation/epoch and provider-completion tests.
- `tests/check_source.py` passes the source/packaging assertions.
- Linux Swift is available; Apple SDK, Xcode build, entitlement/runtime Keychain access, on-device local-network prompts and actual URLSession wall-clock timeouts have NOT been tested. Timeout error-path tests use a throwing mock; they are not a real LAN timeout benchmark.

## Shortest existing-build check

For the existing build, enter the board's shown address as `http://<private IP>` and use the already configured token; after one tap, scroll to the settings form's bottom to read its notice. Do not delete credentials, rotate the token, or reflash firmware merely because the button lacks feedback. If the notice mentions App Group or Keychain, fix signing configuration rather than changing the board. The repaired build puts this outcome beside the button.

## Pairing state and safe cancellation follow-up

`pairingState` exposes idle/opening/waiting/connected/expired/error/cancelled, an explanatory message and a deadline-based countdown. `startPairing()` is also reached through `requestDeviceControl(pairing: true)`; `cancelPairing()` immediately marks cancellation but drains the pending open response before conditional cleanup. A second local start is locked until that cleanup ends. Polling only reads `/v1/status` and requires the same boot/window epoch; `hid_connected` is the current firmware's `connected && encrypted`, not merely an open advertising window. A final status read on return from Settings prevents an already completed connection being mistaken for a timeout after app suspension.

The UI's idle device summary is simply “设备已连接” or “局域网已响应 · 蓝牙尚未连接”. Task permission remains in the task flow; pairing never grants control.

Cancellation uses only authenticated `POST /v1/cancel_pairing` with the opened window's `boot_id` and `control_epoch`. Firmware must enforce this atomically and reject an armed/new session. The client expects `{ok:true,pairing_open:false,boot_id,control_epoch}`. HTTP 409 means the state changed; 404/405 means old firmware does not support conditional cancellation. Neither causes a fallback `/v1/stop`: the old window is allowed to expire naturally. Lost LAN/unknown reply is reported honestly and the user is told to wait for the window's own expiry.

The status decoder tolerates older firmware and additionally exposes optional `ble_connected`, `pairing_open` and `accessorySetupServiceUUID` (decoded from `accessory_setup_service_uuid`). These capability fields support a separate AccessorySetupKit adapter; no private Settings URL or fake CoreBluetooth auto-pairing is implemented here. The existing supported fallback is iPhone Settings → Bluetooth → SightLatch: https://support.apple.com/en-us/105108 . Public AccessorySetupKit HID setup exists subject to Apple's documented requirements; it must not be described as universally impossible or as silent binding. The adapter and matching firmware custom service are being developed separately.

Additional compiled mock tests cover window expiration, encrypted status, duplicate taps, cancellation during opening, local-session exclusion, changed epoch/armed refusal, lost LAN, old firmware fallback, exact conditional-cancel payloads, server 409 races and absence of unconditional STOP. These do not establish true C3/iOS pairing, HID report subscription, ASK UI behavior or Apple SDK compilation.
