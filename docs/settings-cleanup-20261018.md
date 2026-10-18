# Secondary settings cleanup

The chat home layout and its actions are unchanged.

## Page changes

- Device: persistent address/Token labels, full-height sheet, equally wide check/pair buttons. Removed the redundant save instruction and in-card stop button. Emergency stop remains fixed in the device toolbar, and in both probe/pair result sheets; it is not disabled by probing or a running session.
- AI account: choose a service first; only the matching ChatGPT or API setup is expanded. API endpoint examples are optional disclosure content. Model profiles live here, with no circular profile → account sheet path.
- Permissions and safety: screenshot consent has one settings location, with the receiving service named. Everyday upload/system/safety controls precede optional background coordination. No consent is granted by opening or switching pages.
- Credentials: destructive deletion is inside an advanced disclosure with its actual scope (current API key and device token); the existing confirmation remains.
- Advanced/data, model profiles, gateway and transfer: shared 56-point minimum rows, background, inline navigation title, keyboard dismissal and explicit close control. Removed obsolete build-status copy and the incorrect statement that no ChatGPT OAuth exists.
- Calibration: keep explicit 60-second movement permission and cancellation; constrain the bottom action to the same content width as the test canvas on larger screens.
- Feedback: AI save failure is visible in a dedicated error section; account and export errors share an icon, readable multiline text and error color.
- Guide: removed the obsolete manual “allow control for five minutes” instructions. The actual five-minute session safety ceiling remains accurately documented, because the runtime still enforces 300 seconds.

## Verification

- Swift 6 frontend parsing of all changed Swift files: passed (syntax only, not iOS type-checking).
- All tests/check_*.py source/asset contracts passed with SWIFTC configured, including seven new settings-structure tests and nine chat-refinement tests.
- OAuth test also compiled and executed real Swift SSE completion/error tests.
- git diff --check: passed.

Real Xcode three-target build and device layout testing remain integration checks. No simulator screenshots or device visual acceptance are claimed here.

## Device review checklist

1. On a small iPhone and larger text size, edit the device URL and Token, dismiss the keyboard, check connection and retry a failure. Confirm the fixed stop action remains reachable.
2. Toggle each AI service; only its fields should be shown. Open/close profiles and gateway; each close returns one level without cycling back through AI settings.
3. Confirm a failed AI save keeps the sheet open and shows the failure. Verify changing service/endpoint still resets text/upload permissions.
4. In Permissions and safety, inspect the named screenshot recipient, revoke consent, and expand optional background coordination. During a session, editing stays disabled but stop/revoke remains available.
5. Start calibration only from its explicit allow button; cancel or background the app and verify cancellation. Check the action width on iPad.
