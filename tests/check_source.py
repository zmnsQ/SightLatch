#!/usr/bin/env python3
"""Source/packaging regression checks. These are NOT a Swift build or device test."""
from pathlib import Path
import plistlib
import subprocess
import re
import unittest
import xml.etree.ElementTree as ET

ROOT = Path(__file__).resolve().parents[1]
def source(name):
    return (ROOT / name).read_text()


def published_source(name):
    """The index is the publishable snapshot; the local signed worktree may differ."""
    return subprocess.check_output(["git", "show", ":" + name], cwd=ROOT, stderr=subprocess.PIPE).decode()


def project_objects(text):
    """Parse OpenStep object links independently of Xcode's line formatting."""
    tokens = re.findall(r'//[^\n]*|/\*.*?\*/|"(?:\\.|[^"\\])*"|[{}()=;,]|[^\s{}()=;,]+', text, re.S)
    tokens = [t for t in tokens if not t.startswith(("//", "/*"))]
    index = 0
    def value():
        nonlocal index
        token = tokens[index]; index += 1
        if token == "{":
            result = {}
            while tokens[index] != "}":
                key = value()
                if tokens[index] != "=": raise ValueError("Invalid PBX dictionary")
                index += 1; result[key] = value()
                if tokens[index] != ";": raise ValueError("Invalid PBX assignment")
                index += 1
            index += 1; return result
        if token == "(":
            result = []
            while tokens[index] != ")":
                result.append(value())
                if tokens[index] == ",": index += 1
            index += 1; return result
        return token[1:-1].replace('\\"', '"').replace('\\\\', '\\') if token.startswith('"') else token
    result = value()
    if index != len(tokens): raise ValueError("Trailing PBX data")
    return result["objects"]

class SourceContracts(unittest.TestCase):
    def test_plists_parse_and_local_network_policy(self):
        for path in (ROOT / "ios").rglob("*.plist"):
            with path.open("rb") as f:
                obj = plistlib.load(f)
            self.assertNotIn("NSAllowsArbitraryLoads", obj.get("NSAppTransportSecurity", {}))
        for path in (ROOT / "ios").rglob("*.entitlements"):
            with path.open("rb") as f:
                plistlib.load(f)

    def test_all_swift_files_are_referenced(self):
        objects = project_objects(source("ios/SightLatch.xcodeproj/project.pbxproj"))
        refs = {obj["path"] for obj in objects.values() if obj.get("isa") == "PBXFileReference" and "path" in obj}
        for path in (ROOT / "ios").rglob("*.swift"):
            self.assertIn(str(path.relative_to(ROOT / "ios")), refs)
        for ref in refs:
            if ref.endswith((".swift", ".plist", ".entitlements", ".xcconfig", ".xcassets")):
                self.assertTrue((ROOT / "ios" / ref).exists(), ref)
        self.assertEqual(sum(o.get("isa") == "PBXNativeTarget" for o in objects.values()), 3)

    def test_sightlatch_project_scheme_products_and_embedding(self):
        self.assertFalse((ROOT / "ios/HIDPilot.xcodeproj").exists())
        objects = project_objects(published_source("ios/SightLatch.xcodeproj/project.pbxproj"))
        targets = {obj["name"]: (uid, obj) for uid, obj in objects.items() if obj.get("isa") == "PBXNativeTarget"}
        self.assertEqual(set(targets), {"SightLatch", "SightLatchBroadcast", "SightLatchWidget"})
        products = {}
        for name, (uid, obj) in targets.items():
            self.assertEqual(obj["productName"], name)
            products[name] = obj["productReference"]
            suffix = ".app" if name == "SightLatch" else ".appex"
            self.assertEqual(objects[products[name]]["path"], name + suffix)
            configs = objects[obj["buildConfigurationList"]]
            for config_id in configs["buildConfigurations"]:
                self.assertEqual(objects[config_id]["buildSettings"]["PRODUCT_NAME"], name)
        app_id, app = targets["SightLatch"]
        dependencies = [objects[uid] for uid in app["dependencies"]]
        self.assertEqual({obj["target"] for obj in dependencies}, {targets[n][0] for n in targets if n != "SightLatch"})
        for dependency in dependencies:
            proxy = objects[dependency["targetProxy"]]
            self.assertEqual(proxy["remoteGlobalIDString"], dependency["target"])
            self.assertEqual(proxy["remoteInfo"], objects[dependency["target"]]["name"])
        embed = [objects[uid] for uid in app["buildPhases"] if objects[uid]["isa"] == "PBXCopyFilesBuildPhase"]
        self.assertEqual(len(embed), 1)
        self.assertEqual(embed[0]["dstSubfolderSpec"], "13")
        self.assertEqual({objects[uid]["fileRef"] for uid in embed[0]["files"]},
                         {products["SightLatchBroadcast"], products["SightLatchWidget"]})
        # Inspect published schemes; extra local extension-debug schemes are not a packaging failure.
        scheme = ET.fromstring(published_source("ios/SightLatch.xcodeproj/xcshareddata/xcschemes/SightLatch.xcscheme"))
        refs = scheme.findall(".//BuildableReference")
        self.assertGreaterEqual(len(refs), 2)
        for ref in refs:
            self.assertEqual(ref.get("BlueprintIdentifier"), app_id)
            self.assertEqual(ref.get("BlueprintName"), "SightLatch")
            self.assertEqual(ref.get("BuildableName"), "SightLatch.app")
            self.assertEqual(ref.get("ReferencedContainer"), "container:SightLatch.xcodeproj")
        for folder, display in (("App", "SightLatch"), ("Broadcast", "SightLatch Broadcast"), ("Widget", "SightLatch Widget")):
            info = plistlib.loads((ROOT / "ios" / folder / "Info.plist").read_bytes())
            self.assertEqual(info["CFBundleDisplayName"], display)
            self.assertEqual(info["CFBundleName"], "$(PRODUCT_NAME)")
            self.assertEqual(info["CFBundleExecutable"], "$(EXECUTABLE_NAME)")
        broadcast = plistlib.loads((ROOT / "ios/Broadcast/Info.plist").read_bytes())
        self.assertEqual(broadcast["NSExtension"]["NSExtensionPrincipalClass"], "$(PRODUCT_MODULE_NAME).SampleHandler")

    def test_rename_preserves_persistent_identities(self):
        self.assertIn("PILOT_BUNDLE_PREFIX = com.sightlatch.team$(DEVELOPMENT_TEAM).HIDPilot",
                      source("ios/Config/Project.xcconfig"))
        for path in ("ios/Shared/SharedStore.swift", "ios/Shared/ChatGPTOAuth.swift"):
            self.assertIn('kSecAttrService as String: "HIDPilot"', source(path))
        self.assertIn('var format = "HIDPilot-settings"', source("ios/App/Workspace.swift"))
        self.assertIn('archive.format == "HIDPilot-settings"', source("ios/App/Workspace.swift"))
        ui = source("ios/App/WorkspaceViews.swift")
        self.assertIn('"SightLatch-settings"', ui)
        self.assertIn('"SightLatch-diagnostics"', ui)

    def test_fresh_clone_signing_configuration(self):
        config = published_source("ios/Config/Project.xcconfig")
        self.assertIn('#include? "Local.xcconfig"', config)
        self.assertNotRegex(config, r'(?m)^#include\s')
        self.assertIn("CODE_SIGN_STYLE = Automatic", config)
        self.assertNotRegex(config, r'(?m)^DEVELOPMENT_TEAM\s*=')
        example = source("ios/Config/Local.example.xcconfig")
        self.assertFalse(any(line.strip() and not line.strip().startswith("//") for line in example.splitlines()))
        objects = project_objects(published_source("ios/SightLatch.xcodeproj/project.pbxproj"))
        target_configs = [o for o in objects.values() if o.get("isa") == "XCBuildConfiguration" and "PRODUCT_BUNDLE_IDENTIFIER" in o.get("buildSettings", {})]
        self.assertEqual(len(target_configs), 6)
        for obj in target_configs:
            self.assertEqual(objects[obj["baseConfigurationReference"]]["path"], "Config/Project.xcconfig")
            settings = obj["buildSettings"]
            # Never include the offending dictionary in a failure: it could contain a local Team value.
            self.assertFalse("DEVELOPMENT_TEAM" in settings, "Published project must not contain a local Team override")
            self.assertFalse("CODE_SIGN_STYLE" in settings, "Target must inherit the shared signing policy")
        identifiers = [o["buildSettings"]["PRODUCT_BUNDLE_IDENTIFIER"] for o in target_configs]
        for suffix in ("", ".Broadcast", ".Widget"):
            self.assertEqual(identifiers.count("$(PILOT_BUNDLE_PREFIX)" + suffix), 2)

    def test_signing_identifier_derivation(self):
        # Model only the simple variable references used by this xcconfig.
        # This is a source contract, NOT Xcode build-settings evaluation/signing.
        settings = dict(re.findall(r'(?m)^(\w+) = (.+)$', source("ios/Config/Project.xcconfig")))
        def resolve(value, values):
            for _ in range(10):
                if "$(" not in value:
                    return value
                value = re.sub(r'\$\((\w+)\)', lambda m: values[m[1]], value)
            self.fail("cyclic build setting reference")
        prefixes = []
        for team in ("", "AB12CD34EF", "ZY98XW76VU"):
            values = dict(settings, DEVELOPMENT_TEAM=team, AppIdentifierPrefix="LEGACY1234.")
            prefix = resolve(values["PILOT_BUNDLE_PREFIX"], values)
            prefixes.append(prefix)
            self.assertRegex(prefix, r'^[A-Za-z0-9-]+(?:\.[A-Za-z0-9-]+)+$')
            self.assertEqual(resolve(values["PILOT_APP_GROUP"], values), "group." + prefix)
            self.assertEqual(resolve(values["PILOT_KEYCHAIN_GROUP"], values), "LEGACY1234." + prefix + ".shared")
        self.assertEqual(len(set(prefixes)), 3)
        # A legacy prefix-only override carries both shared groups with it.
        values = dict(settings, PILOT_BUNDLE_PREFIX="com.legacy.HIDPilot", AppIdentifierPrefix="OLDPREFIX.")
        self.assertEqual(resolve(values["PILOT_APP_GROUP"], values), "group.com.legacy.HIDPilot")
        self.assertEqual(resolve(values["PILOT_KEYCHAIN_GROUP"], values), "OLDPREFIX.com.legacy.HIDPilot.shared")

    def test_shared_entitlements_remain_consistent(self):
        for target in ("App", "Broadcast", "Widget"):
            with (ROOT / "ios" / target / (target + ".entitlements")).open("rb") as f:
                entitlements = plistlib.load(f)
            self.assertEqual(entitlements["com.apple.security.application-groups"], ["$(PILOT_APP_GROUP)"])
            if target != "Widget":
                self.assertEqual(entitlements["keychain-access-groups"], ["$(PILOT_KEYCHAIN_GROUP)"])
            else:
                self.assertNotIn("keychain-access-groups", entitlements)
            with (ROOT / "ios" / target / "Info.plist").open("rb") as f:
                info = plistlib.load(f)
            self.assertEqual(info["PilotAppGroup"], "$(PILOT_APP_GROUP)")
            self.assertEqual(info["PilotKeychainGroup"], "$(PILOT_KEYCHAIN_GROUP)")

    def test_software_control_is_explicit_and_old_firmware_safe(self):
        network = source("ios/Shared/Network.swift")
        self.assertIn('var control_mode: String?', network)
        self.assertIn('control_mode == "software"', network)
        self.assertIn('request("v1/pair", method: "POST"', network)
        self.assertIn('request("v1/arm", method: "POST"', network)
        self.assertIn('reply.armed, reply.hid_connected', network)
        ui = source("ios/App/PilotViewModel.swift")
        refresh = ui.split('func refreshDeviceStatus()', 1)[1].split('func probe()', 1)[0]
        self.assertNotIn('armSoftwareControl', refresh)
        self.assertNotIn('beginPairing', refresh)
        explicit = ui.split('func requestDeviceControl(', 1)[1].split('func prepare(', 1)[0]
        # The compatibility entry point can only open pairing, never bypass a task permit.
        self.assertIn('guard pairing else', explicit)
        self.assertIn('await startPairing()', explicit)
        self.assertNotIn('armSoftwareControl', explicit)
        self.assertNotIn('stopAndVerify', explicit)
        pairing = ui.split('private func runPairing(', 1)[1].split('func requestDeviceControl(', 1)[0]
        self.assertIn('guard current.supportsSoftwareControl', pairing)
        self.assertIn('guard !current.armed', pairing)
        self.assertIn('deviceControlID == operationID', pairing)
        self.assertIn('SharedStore.shared.stopGeneration == stopGeneration', pairing)
        self.assertIn('client.beginPairing(expected: current)', pairing)
        self.assertIn('client.closePairingWindow(expected: receipt!, stillOwned: ownsOperation)', pairing)
        self.assertNotIn('armSoftwareControl', pairing)
        self.assertNotIn('stopAndVerify', pairing)  # No unconditional STOP on window cancellation.
        start = ui.split('func prepare(', 1)[1].split('func stop()', 1)[0]
        self.assertIn('device.preparedHardwareAuthorization(configuration: configuration)', start)
        self.assertNotIn('.armSoftwareControl(', start)
        self.assertIn('guard taskFlow.consumePermission(goal:', start)
        self.assertLess(start.index('taskFlow.consumePermission'), start.index('HardwareClient(configuration: configuration)'))
        self.assertIn('task.trimmingCharacters(in: .whitespacesAndNewlines) == preparedGoal', start)
        prepared = network.split('func preparedHardwareAuthorization(', 1)[1].split('func hasVerifiedPointerCalibration(', 1)[0]
        self.assertIn('control_lease_mode != "calibration"', prepared)
        calibration = source("ios/App/PilotPointerCalibration.swift")
        begin_calibration = calibration.split('func beginPointerCalibration(', 1)[1].split('private func calibrationIsCurrent', 1)[0]
        self.assertIn('guard !isSessionActive, !taskFlow.isBusy, !probing, !calibrationRequestInFlight', begin_calibration)
        self.assertIn('guard !device.armed', begin_calibration)
        self.assertIn('client.armSoftwareControl(expected: device, mode: "calibration")', begin_calibration)
        self.assertIn('device.control_lease_mode == "calibration"', begin_calibration)
        self.assertIn('remaining > 0, remaining <= 60_000', begin_calibration)
        self.assertIn('guard calibrationIsCurrent(id, phase: .starting) else { try await client.stopAndVerify(); return }', begin_calibration)
        self.assertIn('guard preparationID == token', start)
        self.assertIn('command.execution = SessionExecution(stopGeneration: expectedStopGeneration', start)
        self.assertIn('stopAndVerify(expectedSessionID: createdSessionID)', start)
        end_paused = ui.split('func endPausedSession() async', 1)[1].split('func manual(', 1)[0]
        self.assertIn('await stop()', end_paused)
        for forbidden in ['armSoftwareControl', 'generation +=', 'submitGoal()', 'prepare()']:
            self.assertNotIn(forbidden, end_paused)
        stop = ui.split('func stop() async', 1)[1].split('func recoverDamagedSettings()', 1)[0]
        self.assertIn('deviceControlID = UUID()', stop)
        self.assertIn('deviceObservationID = UUID()', stop)
        self.assertIn('lastDeviceStatus = nil', stop)
        self.assertIn('while preparingRequestInFlight || controllingDevice', stop)
        self.assertIn('let hadControlRequestInFlight = preparingRequestInFlight || controllingDevice', stop)
        view = source("ios/App/HomeView.swift")
        for binding in ['isOn: $model.configuration.uploadConsent', 'await model.startPairing()', 'await model.startAutomaticCalibration()', 'await model.stop()']:
            self.assertIn(binding, view)

    def test_device_status_expires_and_foreground_polling_never_arms(self):
        ui = source("ios/App/PilotViewModel.swift")
        self.assertIn('Date().timeIntervalSince(checkedAt) < 10', ui)
        self.assertIn('UIApplication.shared.applicationState == .active', ui)
        self.assertIn('observedDeviceURL == configuration.deviceURL', ui)
        refresh = ui.split('func refresh()', 1)[1].split('func save()', 1)[0]
        self.assertIn('lastDeviceStatus = nil', refresh)
        self.assertNotIn('armSoftwareControl', refresh)
        readiness = source("ios/App/Workspace.swift")
        self.assertIn('deviceStatusIsFresh && lastDeviceStatus?.armed == true', readiness)

    def test_chat_ui_uses_real_state_and_accessible_native_glass(self):
        view = source("ios/App/HomeView.swift")
        self.assertIn('Text(command.task)', view)
        self.assertIn('Text(model.presentedStatusDetail(model.status.detail))', view)
        self.assertIn('model.status.userMessage', view)
        self.assertIn('$0.sessionID == model.status.sessionID', view)
        self.assertIn('model.status.sessionID == command.id', view)
        self.assertIn('DisclosureGroup(isExpanded: $showExecution)', view)
        self.assertIn('VoiceTaskComposer(text: $model.task)', view)
        self.assertIn('GlassEffectContainer(spacing:', view)
        action = view.split('private struct PilotActionStyle:', 1)[1].split('extension View', 1)[0]
        self.assertIn('if #available(iOS 26.0, *), !reduceTransparency', action)
        self.assertIn('label.glassEffect(.regular.tint(tint).interactive()', action)
        self.assertIn('else if reduceTransparency', action)
        self.assertIn('label.background(Color.primary.opacity(0.08)', action)
        self.assertIn('accessibilityReduceTransparency', view)
        self.assertIn('dynamicTypeSize.isAccessibilitySize', view)
        shortcut = view.split('private func receiveShortcut()', 1)[1].split('struct DeviceSettingsView', 1)[0]
        self.assertNotIn('model.prepare()', shortcut)
        self.assertIn('model.task = task', shortcut)

    def test_control_requests_are_bound_to_fresh_device_epoch(self):
        network = source("ios/Shared/Network.swift")
        self.assertIn("var control_epoch: String?", network)
        self.assertIn("ControlRequest(boot_id: expected.boot_id, control_epoch: epoch, mode: mode)", network)
        self.assertIn("let epoch = expected.control_epoch, epoch.count == 32", network)
        self.assertIn("func beginPairing(expected: DeviceStatus)", network)
        self.assertIn("func armSoftwareControl(expected: DeviceStatus, mode: String? = nil)", network)
        self.assertIn("reply.control_epoch == expected.control_epoch", network)
        ui = source("ios/App/PilotViewModel.swift")
        self.assertIn("client.beginPairing(expected: current)", ui)
        self.assertNotIn("client.armSoftwareControl(expected: current)", ui)  # Removed bypass.
        self.assertNotIn(".armSoftwareControl(", ui.split("func prepare(", 1)[1].split("func stop()", 1)[0])
        first_arm = network.split('func beginPreparedExecution(', 1)[1].split('func renewExecution(', 1)[0]
        self.assertIn('armSoftwareControl(expected: device, mode:', first_arm)
        for guard in ['stillAuthorized()', 'Date() < deadline', 'device.boot_id == authorization.bootID',
                      'device.control_epoch == authorization.controlEpoch', 'device.hid_generation == authorization.hidGeneration',
                      'guard device.supportsSoftwareControl, !device.armed']:
            self.assertIn(guard, first_arm)
        capture = source("ios/Broadcast/SampleHandler.swift")
        self.assertLess(capture.index('self.latestFingerprint = self.fingerprint(oriented)'), capture.index('self.store.claimCaptureExecution('))
        self.assertLess(capture.index('self.store.claimCaptureExecution('), capture.index('self.startHardwareAfterFirstCapture(claimed)'))
        startup = capture.split('private func startHardwareAfterFirstCapture(', 1)[1].split('private func', 1)[0]
        self.assertIn('execution.phase == .startingHardware', startup)
        self.assertIn('execution.captureOwnerID == captureOwnerID', startup)
        self.assertLess(startup.index('.beginPreparedExecution('), startup.index('.activateCaptureExecution('))
        calibration = source("ios/App/PilotPointerCalibration.swift")
        self.assertIn('client.armSoftwareControl(expected: device, mode: "calibration")', calibration)
        self.assertIn('device.control_epoch == calibrationFlow.controlEpoch', calibration)
        self.assertIn('device.boot_id == calibrationFlow.bootID', calibration)
        self.assertIn('device.session_id == calibrationFlow.sessionID', calibration)
        # Task ARM moved to the STOP-fenced first-capture helper; short calibration remains explicit.
        arm_calls = []
        for path in (ROOT / "ios").rglob("*.swift"):
            for line in path.read_text().splitlines():
                if '.armSoftwareControl(' in line or 'try await armSoftwareControl(' in line:
                    arm_calls.append(path.name)
        self.assertEqual(sorted(arm_calls), ["Network.swift", "PilotPointerCalibration.swift"])
        cancel = network.split('func closePairingWindow(', 1)[1].split('func armSoftwareControl(', 1)[0]
        self.assertIn('Cancellation(boot_id: expected.boot_id, control_epoch: expected.control_epoch)', cancel)
        self.assertIn('request("v1/cancel_pairing", method: "POST"', cancel)
        self.assertIn('error.statusCode == 409', cancel)
        self.assertNotIn('stopAndVerify', cancel)

    def test_activity_start_rechecks_command_after_suspension(self):
        manager = source("ios/App/PilotActivityManager.swift")
        start = manager.split("func start(sessionID:", 1)[1].split("func retry()", 1)[0]
        current = manager.split("private func isCurrent(", 1)[1].split("private func deferUntilForeground", 1)[0]
        for gate in ["command.id == id", "command.running", "configuration.uploadConsent", "stopGeneration == stopGeneration"]:
            self.assertIn(gate, current)
        after_old_end = start.split("await activity.end", 1)[1]
        self.assertLess(after_old_end.index("isCurrent(sessionID, stopGeneration: fence)"), after_old_end.index("Activity.request"))
        self.assertLess(after_old_end.index("UIApplication.shared.applicationState == .active"), after_old_end.index("Activity.request"))
        after_request = start.split("Activity.request", 1)[1]
        self.assertLess(after_request.index("isCurrent(sessionID, stopGeneration: fence)"), after_request.index("await activity.end"))

    def test_command_mutation_uses_cross_process_lock(self):
        store = source("ios/Shared/SharedStore.swift")
        self.assertIn("flock(descriptor, LOCK_EX)", store)
        self.assertIn("guard current.id == sessionID", store)
        # New-session preparation uses the atomic STOP-fenced SharedStore API.
        writers = []
        for path in (ROOT / "ios").rglob("*.swift"):
            if path.name == "SharedStore.swift":
                continue
            writers += [(path.name, line) for line in path.read_text().splitlines()
                        if 'write(' in line and 'to: "command.json"' in line]
        self.assertEqual(len(writers), 0, writers)
        self.assertIn("startCommand(command, expectedStopGeneration:", source("ios/App/PilotViewModel.swift"))
        self.assertIn("current == expectedStopGeneration", store)
        self.assertIn("invalidatePendingStarts()", source("ios/Shared/PilotIntents.swift"))

    def test_provider_and_settings_fail_closed(self):
        network = source("ios/Shared/Network.swift")
        self.assertIn('["responses", "openai", "anthropic", "gemini", "chatgpt-plan"].contains(provider)', network)
        self.assertIn("try configuration.validate()", network)
        self.assertIn("components.count == 4 && parts.count == 4", network)
        self.assertIn("calibrationX.isFinite, calibrationY.isFinite", network)
        self.assertIn("current.boot_id == device.boot_id", network)

    def test_stop_has_confirmed_and_uncertain_paths(self):
        network = source("ios/Shared/Network.swift")
        self.assertRegex(network, r'func stopAndVerify\(expectedSessionID: String\? = nil, captureOwnerID: String\? = nil,\s+heldChannel: HardwareChannelLease\? = nil\) async throws')
        stop = network.split('func stopAndVerify(', 1)[1].split('private func performStopAndVerify()', 1)[0]
        self.assertIn('acquireStopHardwareChannel', stop)
        self.assertIn('throw StopFailure.staleOwner', stop)
        self.assertIn('confirmed: !mayHavePosted', stop)
        self.assertIn('try await performStopAndVerify()', stop)
        self.assertIn("if !current.armed && !current.busy { return }", network)
        ui = source("ios/App/PilotViewModel.swift")
        self.assertIn("但未确认硬件停止送达", ui)
        self.assertIn('let stopCommandID = store.command?.id', ui)
        self.assertIn('stopAndVerify(expectedSessionID: stopCommandID)', ui)
        intent = source("ios/Shared/PilotIntents.swift")
        self.assertLess(intent.index("catch { localRevoked = false }"), intent.index("stopAndVerify(expectedSessionID: stopCommandID)"))
        self.assertIn('hardwareConfirmed = true', intent)

    def test_persistence_failures_are_not_success(self):
        workspace = source("ios/App/Workspace.swift")
        self.assertIn("func persistWorkspace() -> Bool", workspace)
        self.assertIn("guard persistWorkspace() else { return false }", workspace)
        self.assertIn("guard persistWorkspace() else { throw PilotError.message(notice) }", workspace)
        self.assertIn("try recordSession(command)", source("ios/App/PilotViewModel.swift"))

    def test_broadcast_end_revokes_both_modes(self):
        code = source("ios/Broadcast/SampleHandler.swift")
        end = code.split("private func endCaptureSession()", 1)[1].split("private func stopAndFinish", 1)[0]
        self.assertIn("updateCommand(sessionID: sessionID)", end)
        self.assertNotIn("guard config.continuedProcessingEnabled", end)

    def test_agent_loop_preserves_context_and_post_tool_frame_boundary(self):
        broadcast = source("ios/Broadcast/SampleHandler.swift")
        continued = source("ios/App/ContinuedSession.swift")
        for code in [broadcast, continued]:
            self.assertIn("AgentSession(", code)
            self.assertIn("context:", code)
            self.assertIn("recoverBeforeDispatch", code)
            self.assertIn("sessionAuthorized:", code)
            self.assertIn("accepts(frameID:", code)
        harness = source("ios/Shared/AgentSession.swift")
        self.assertIn("capturedAt > observeAfter", harness)
        self.assertIn("unchangedRounds < 4", harness)
        self.assertIn("results.suffix(12)", harness)
        self.assertIn("rounds >= maxRounds", harness)

    def test_local_secrets_are_ignored(self):
        ignored = source(".gitignore")
        for filename in ["firmware/IPhoneHIDBridge/config.h", "ios/Config/Local.xcconfig", "*.p12", ".env"]:
            self.assertIn(filename, ignored)
        # Local configuration is allowed to exist. It must remain ignored and absent from the publishable index.
        for filename in ["firmware/IPhoneHIDBridge/config.h", "ios/Config/Local.xcconfig"]:
            self.assertEqual(subprocess.run(["git", "check-ignore", "-q", filename], cwd=ROOT).returncode, 0)
            self.assertNotEqual(subprocess.run(["git", "ls-files", "--error-unmatch", filename], cwd=ROOT,
                stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL).returncode, 0)

if __name__ == "__main__":
    unittest.main(verbosity=2)
