# Architecture

## Components

| Component | Responsibility |
| --- | --- |
| SwiftUI app | Setup, model profiles, consent, calibration, session control and history |
| ReplayKit extension | Receives user-authorized screen frames and supplies selected observations |
| Shared state | App Group session data, cross-process command updates and shared Keychain access |
| Provider adapters | Image requests for Responses, Chat Completions, Anthropic and Gemini |
| ESP32-S3 bridge | Validates session/sequence/deadline, performs BLE keyboard/pointer actions and releases inputs |
| Live Activity | Shows the latest session snapshot and explicit refresh/stop controls |

## Execution modes

The default mode handles the observation loop in the broadcast extension. The optional iOS 26 continued-processing mode moves AI and LAN scheduling into the main app while ReplayKit supplies the latest frame. Neither mode guarantees indefinite background execution. The optional path uses a six-second execution lease and a five-minute session limit; system cancellation and stale commands must stop further work.

## Stop and stale-state handling

Commands are updated under a cross-process lock and scoped to a session ID. Old callbacks must not overwrite a new session. Broadcast termination revokes the active session. A network STOP request is followed by a device-state check for disarmed/not-busy status; an HTTP acknowledgement alone is not displayed as confirmed physical stop.

The hardware ARM/STOP controls remain the last local intervention path. Model classifications and text filters are not a security boundary for high-impact actions.

## Data boundaries

Selected frames and task text go to the configured AI endpoint after consent. LAN commands go directly from phone to ESP32. There is no public streaming service or desktop controller in the architecture. The optional background path temporarily stores a frame in the protected App Group; crash recovery cleans residual state on a later launch/preparation and is not an immediate secure-erasure guarantee.

## Branding compatibility

SightLatch names the Xcode project, shared scheme, targets, products and display strings. Bundle identifiers, App Group / Keychain groups and service names, JSON format markers and device protocol strings deliberately remain unchanged from the historical HIDPilot identity. Display strings and exported filenames are not protocol identifiers.
