# 0.3.3-c3-web — public experimental build

This derives from the frozen local 0.3.3-c3-test feature source. Runtime changes
are limited to the version string and a stable per-chip BLE static-random
identity derived from SHA-256(domain || factory chip MAC). It removes the
private LocalIdentity.h input. The same chip has the same identity across USB
and UART builds/reboots; different chips do not share the developer identity.
Factory identity is read only; no eFuse or NVS identity write is performed.
Existing local-test bonds may need to be forgotten and paired again.

The absolute-HID protocol, encryption/bond/subscription readiness, new-peer
pairing window, boot/session/sequence/TTL/STOP fencing, calibration-only probes,
local ATT completion semantics and bounded renewable-session protocol are
unchanged. HTTP listener retry is included, but observed Wi-Fi/LAN failures
remain unresolved. This public build has NOT had a board/iPhone regression.
Compile/host checks do not establish wireless reliability or task success.

Reference HID implementation: cccat6/iphone-agent-harness
fc727da547da8b78d1a6dda5d49624f641e67c15 (MIT; LICENSE.reference retained).
Development PnP identifiers are inherited for this experimental comparison;
they are not a production vendor allocation.
NimBLE-Arduino 2.5.1 is unmodified upstream (checksum pinned by build tooling).
Do not apply the unrelated Arduino 3.3.5 BLEService patch to this source.
