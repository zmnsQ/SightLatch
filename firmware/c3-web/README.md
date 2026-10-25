# C3 public test firmware — 0.3.3-c3-web

This is an **experimental ESP32-C3 release**, not a stability claim. It derives
from the local 0.3.3-c3-test feature source, with a public per-chip BLE identity
instead of the developer board's fixed identity. The public USB and UART images
have compiled and passed host checks; **neither public variant has completed a
board/iPhone regression**. Wi-Fi/LAN timeouts and disconnects observed with the
local candidate remain unresolved. Do not use it for unattended operation.
ESP32 and ESP32-S3 remain historical 0.2.3 builds, not 0.3.3 ports.

## Source and dependencies

`IPhoneHIDBridge/` is the complete credential-free C3 sketch. The feature protocol
includes standard encrypted/bonded/subscribed HID, absolute positioning and
calibration-only probes, session/boot/control epoch/sequence/TTL fences, STOP,
and explicitly authorized renewable sessions. Completion means **local ATT
submission**, not an iOS click or task-success acknowledgement. The App must
verify the screen separately. The public change does not fix wireless failures.

Pinned tools are Arduino CLI 1.3.1, Arduino-ESP32 3.3.11, NimBLE-Arduino 2.5.1,
and ArduinoJson 7.0.4. `dependencies.lock.json` pins both library archives by
SHA-256. NimBLE is stock upstream: **no hidden/local library patch is needed**.
Resource limits are forced into sketch and library compilation by `build_opt.h`.
The sketch supplies the narrowly scoped linker wrappers for NVS full-erase
protection, early peer admission and repeat-pairing policy; the build script
passes every required `--wrap`. Do not compile by simply opening the `.ino` with
default Arduino flags. Do not apply the old Arduino 3.3.5 BLEService patch here.
The reference HID descriptor and MIT licence are retained; see `CHANGES.md` and
`LICENSE.reference`. Inherited development PnP identifiers are experimental,
not a production vendor allocation.

The BLE static-random address is derived from domain-separated SHA-256 of the
read-only factory identity. It is stable for the same chip across USB/UART and
reboots and does not use the developer's address. No identity is printed or
written to eFuse/NVS. Distinct chips have independently derived identities; as
with any truncated hash, mathematical collision freedom is not asserted.

## Rebuild from a clean checkout

Install Arduino CLI **1.3.1** and Python 3. Run from the repository root:

```sh
python3 scripts/prepare_c3_web_toolchain.py
python3 tests/check_c3_web_identity.py
python3 tests/check_c3_web_absolute.py
python3 tests/check_c3_web_renewal.py
python3 scripts/build_c3_web.py --config-file build/c3-web/toolchain/arduino-cli.yaml
python3 scripts/compose_web_manifest.py
python3 scripts/verify_firmware.py
python3 scripts/verify_c3_web.py
```

Setup installs only into ignored `build/c3-web/toolchain/`. Supply
`--arduino-cli /path/to/arduino-cli` to setup/build if it is not on PATH. No USB,
flashing, provisioning, ARM, publication or deployment occurs in these commands.
The builder rejects `config.h`, `LocalIdentity.h` and generated source artifacts;
verifies installed library bytes against the pinned archives; normalizes build
paths; embeds the sorted source fingerprint; and rejects workstation paths in
the application. `SOURCE_DATE_EPOCH` is fixed. This records build inputs, not an
unverified promise that every host emits bit-identical binaries.

Both variants are DIO 40MHz / 4MiB / huge_app. Native USB uses CDC on boot; UART
uses UART0 for USB-UART boards. Confirm actual board wiring. At least 4MiB Flash
is required; chip/Flash detection does not establish all board compatibility.

## Images and existing installations

- `manifest-c3-web.json` records current C3 source and image SHA-256.
- `manifest-legacy-0.2.3.json` preserves the historical release and its provenance.
- Main `manifest.json` selects new C3 and historical ESP32/S3 with explicit
  per-target version labels; `C3_WEB_SHA256SUMS` covers the four new files.
- Full images are 4MiB at offset 0. They intentionally reuse the public 0.2.3
  Arduino 3.3.5 bootloader/partition prefix already used by the local C3
  application-only candidates. Generated 3.3.11 partitions must match exactly.
- Full install requires explicit erase consent and removes all previous NVS,
  Wi-Fi/token and BLE bonds. Provision new values locally afterwards.
- Application-only images write **only offset 0x10000**. Before writing, the
  website reads and verifies only bootloader and partition regions, never NVS.
  A mismatched prefix is rejected; it never falls back to full erase.
- Compatible existing C3 installations preserve Wi-Fi and token through the
  application-only upgrade. The public identity differs from local fixed-identity
  test builds, so forget the old phone BLE record and explicitly pair again if
  needed. Recalibrate after upgrading. No automatic ARM or task resume occurs.

NVS full-partition auto-erasure is blocked by the wrappers. This is distinct
from a user-confirmed full-flash erase in the installer. Device credentials and
BLE bonds are stored locally in unencrypted NVS, not included in these images.

## Website publishing

`firmware-web.yml` rebuilds current C3 variants and uploads build-only artifacts.
It does not deploy. `publish-installer.yml` validates the checked-in packaged
bytes and publishes the static site through GitHub Pages on manual dispatch or
a **main-branch change to `web-installer/public/firmware/manifest.json`**. Pages
must use the GitHub Actions source. A branch commit is not a deployed website;
use the workflow's deployment output URL and verify the selected version after
root's integration/push. No deployment was performed as part of this build.
