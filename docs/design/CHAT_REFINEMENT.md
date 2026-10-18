# Chat-first refinement

## Information architecture

- Chat: task history on the left, labeled Settings gear on the right. Empty state uses a short invitation and restrained brand mark. One bottom composer contains text, an icon-only microphone, and one send/stop action.
- Goal planning: send invokes only `submitGoal` after explicit text-upload consent. A real AI plan is labeled as based on the goal, with no screen observation. A separate permission card identifies the screenshot recipient, five-minute control bound, and subsequent system broadcast confirmation. Only `allowPlannedTask(requestID:)` may prepare control.
- Running/preparing: send changes to stop using `isSessionActive`, which already includes preparation, pending ARM, active control, and stopping fences. ReplayKit remains a separate, explicit system-confirmed step after preparation. No control or permission is granted by navigation or dictation.
- Conversation: actual task, session-matched status and execution log summaries are visible. The execution section starts expanded; no fabricated reasoning or transcript is added.
- Settings: Device, AI account, Permissions & safety. Appearance, advanced data tools and the guide are secondary. Device URL/token fields have one authoritative location.
- Device: progress in the check button and a native result sheet show connection, real failure/success and retry/next steps. Dismissal cancels an in-flight probe. Bluetooth pairing uses the same single-sheet route, showing a device diagram, system Bluetooth instructions, live deadline countdown and actual board-reported encrypted connection. Closing pending pairing invokes its cancellation fence. A short result also remains beneath the check button. The top toolbar always offers emergency stop; the control panel retains its own stop. No blanket disabled modifier can disable either during ARM/preparation.
- Introduction: four pages, one primary Continue action. Overview → device → AI/upload consent → calibration/stopping. Configuration links open the actual settings; reaching the end only records that the introduction was seen. It does not mark readiness or approve upload/control.

## Accessibility and appearance

System fonts and semantic system colors support Dynamic Type and light/dark appearance. Empty-state spacing reduces at accessibility sizes. Text fields grow vertically, content scrolls, icon controls have 44-point targets and spoken labels. Glass is limited to the composer action, with an opaque fallback when Reduce Transparency is enabled. No custom animation was introduced.

## Validation

- `swiftc -frontend -parse` passes for HomeView, WorkspaceViews and VoiceTaskComposer (Swift 6.0.3 Linux).
- Existing Python source, branding, C3, ChatGPT integration and shortcut contracts pass.
- ChatGPT OAuth source boundary and compiled Swift SSE completion/failure tests pass.
- Nine new source contracts in `tests/check_chat_refinement.py` pass.
- `chat-refinement-preview.html` is a self-contained interactive design reference. It explicitly labels itself as a design preview, not an iOS screenshot. Buttons do not operate hardware or authorize anything.

This environment has no Apple SDK or iOS simulator. Syntax and source tests do not establish SwiftUI type-checking, layout, VoiceOver behavior or physical-device operation. Validate those on iPhone before release, including large text, light/dark, Reduce Transparency, keyboard overlap, permission denial, disconnected device, probe failure/retry, ARM-in-flight stop, ReplayKit start and actual stop confirmation.

## Integration dependency

Integrate the device-probe/pairing and goal-planning patches with this UI. Dependencies: `probeState`, `probing`, `cancelProbe()`, `pairingState`, `startPairing()`, `cancelPairing()`, `taskFlow`, `submitGoal()`, `allowPlannedTask(requestID:)`, `cancelPlannedTask()`, and `configuration.textPlanningConsent`. No ViewModel, transport, OAuth, stop-fence, Siri or Activity implementation was changed here.

## Subsequent device-test feedback

- Planning permission, native connection results and Bluetooth pairing sheets replace the previous direct-prepare and inline-only interaction.
- Calibration is now a graphical automatic-observation guide. A single explicit approval starts the at-most-60-second pointer-only test. The UI embeds the real PointerCalibrationCanvas, displays only backend observation states, and has no direction pad, technical parameter inputs or manual success checkbox. Missing hover support is reported as unavailable, never success. Closing or leaving the foreground cancels and ends the bounded test.
- The accessory picker is only shown for the declared matching custom service and supported OS; picker selection never substitutes for board-reported encrypted connection. Old firmware keeps the system Bluetooth steps.
- Chat, device and AI fields own their FocusState. Background-only tap targets and interactive scroll dismissal clear focus; send and sheet dismissal do so explicitly. No root high-priority gesture or Return-to-send handler was added.
- Local Chromium failed to launch because of the environment's socket sandbox; an approved escalation also failed in sandbox initialization. Preview rendering is being handled separately; this document does not claim a local screenshot or iOS render.

## Visual refinement

The latest design uses a black dark-mode canvas, consistent dark-gray rounded groups, generous row padding, outline controls, restrained blue accents and circular sheet-close controls. Light mode remains semantic and readable. Sheets use a 32-point corner radius and visible drag handle. `PilotConnectionIllustration` uses the original transparent `DeviceConnectionIllustration` asset when supplied, with a simple symbol fallback; reference screenshots are never bundled or republished.

`reference-refinement-preview.html` is the current dark-mode visual draft: chat, grouped settings and a connection-result sheet with success/failure/loading state switches. The two earlier preview filenames now mirror this draft to prevent stale visual review. It remains a design preview, not an iOS rendering or proof of SwiftUI visual correctness.

`calibration-guide-preview.html` illustrates preparation, observation and unsupported-device messaging. These are expressly labeled design states, not measured results.

## iPhone calibration path

iPhone uses explicitly guided finger markers of the real mouse pointer, because UIHover cannot be assumed to provide cursor observations on iPhone. The UI calls `startAssistedCalibration`, receives marker requests through `isAwaitingMarker` and leaves touch collection to PointerCalibrationCanvas. Calculation, independent validation and stop verification remain automatic. Actual hover-capable environments can use `startAutomaticCalibration`. There is no numeric input or manual success checkbox, and no finger sample is mislabeled as hover evidence.
