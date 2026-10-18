# Bounded agent harness

SightLatch accepts one goal for a session. ReplayKit supplies observations; the harness requests one structured tool action, validates it, executes it through ESP32, waits for its completion acknowledgement, then observes a newer screen and continues the same goal. It does not require a user prompt for each step. `ask_user`, safety rejection, uncertainty, completion, cancellation and budgets end or pause the loop.

Both execution owners (Broadcast extension and optional iOS 26 continued-processing task) use `AgentSession`:

- The next model request includes the session ID, planning round and the last 12 tool/result records. Only current JPEG is sent, not a growing screenshot history. Model reasoning is neither requested nor stored.
- Hardware completion is explicitly **not** UI success. A subsequent observation verifies the effect; the model may finish only from visible evidence. Human confirmation of the overall result remains necessary.
- Post-tool observation uses a strict timestamp watermark. Frames received before or during execution cannot become that tool's next observation. The timestamp is sampled at the ReplayKit callback, before dispatch to the encoding queue; it is not proof of the physical display's exact presentation time.
- One pending model/action task is allowed per execution owner. The two modes are mutually exclusive. Authorization is checked after asynchronous results, before dispatch and during acknowledgement polling. STOP revokes session authorization, cancels work, asks firmware to disarm and release inputs; stale firmware session/sequence IDs reject delayed commands. Network loss cannot guarantee delivery of STOP: the app must show uncertainty and the user must use physical STOP when needed.
- A stale/changed observation or failed model request can re-observe at most twice before dispatch. There is no automatic resend after a possibly accepted HID action. Firmware/transport uncertainty pauses and requests STOP.
- Four consecutive visually unchanged transitions pause the harness. This coarse image heuristic can also pause legitimate static-screen work and cannot detect all semantic loops; the round/time limits remain independent safeguards.
- All planning requests count toward the configured 1–50 round limit, including waits and discarded proposals. Total time is bounded to five minutes from session creation. Missing frames time out after 45 seconds. Manual intervention does not reset the budgets or replay the old proposal.
- Responses, Chat Completions, Anthropic and Gemini must explicitly report a completed terminal response. Partial/truncated JSON is never acted on, even if it happens to parse. OAuth provider uses its own equally strict completion parser.

## iOS constraints

The default loop runs in a user-started ReplayKit Broadcast extension with iOS-controlled memory, lifetime and capture restrictions. It cannot secretly start recording or guarantee indefinite execution across interruptions, lock, termination, protected content or unavailable pointer capture. The optional iOS 26 task requires system admission and a live renewable lease; expiration cancels the session. A Live Activity shows progress but grants no extra execution time. Losing screenshots, permission, lease or device authorization fails closed.

## Verification

`tests/run_agent_tests.sh` compiles/runs platform-independent Swift tests and unchanged production HardwareClient/AIClient slices with deterministic fake transport. These tests make no API request or HID action. They cover session history and watermarks, no-progress/budgets, cancellation around asynchronous hardware acknowledgements, and terminal-response/context handling for four providers. `SWIFTC=/path/to/swiftc` selects a compiler. Apple framework source can be syntax-parsed on Linux; that does **not** validate Apple SDK types, signing, ReplayKit lifecycle, BLE behavior or real hardware stop/release. Full Xcode and device acceptance is still required.
