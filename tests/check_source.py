#!/usr/bin/env python3
"""Source/packaging regression checks. These are NOT a Swift build or device test."""
from pathlib import Path
import plistlib
import re
import unittest
import xml.etree.ElementTree as ET

ROOT = Path(__file__).resolve().parents[1]
def source(name):
    return (ROOT / name).read_text()

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
        project = source("ios/SightLatch.xcodeproj/project.pbxproj")
        for path in (ROOT / "ios").rglob("*.swift"):
            self.assertIn(str(path.relative_to(ROOT / "ios")), project)
        refs = re.findall(r'path = "([^"]+\.(?:swift|plist|entitlements|xcconfig))"', project)
        for ref in refs:
            self.assertTrue((ROOT / "ios" / ref).is_file(), ref)
        self.assertEqual(project.count("isa = PBXNativeTarget"), 3)

    def test_sightlatch_project_scheme_products_and_embedding(self):
        project_path = ROOT / "ios/SightLatch.xcodeproj"
        self.assertFalse((ROOT / "ios/HIDPilot.xcodeproj").exists())
        project = source("ios/SightLatch.xcodeproj/project.pbxproj")
        # Objects occupy one line in this checked-in project. Follow UUID links,
        # rather than merely asserting that the new names occur somewhere.
        objects = dict(re.findall(r'^\s*([A-F0-9]{24}) = (.+);$', project, re.M))
        def field(obj, key):
            match = re.search(r'\b' + key + r' = ("[^"\n]*"|[^;]+);', obj)
            self.assertIsNotNone(match, (key, obj))
            return match[1].strip('"')
        def ids(obj, key):
            return field(obj, key).strip('()').strip(',').split(',')
        targets = {field(obj, "name"): (uid, obj) for uid, obj in objects.items()
                   if "isa = PBXNativeTarget;" in obj}
        self.assertEqual(set(targets), {"SightLatch", "SightLatchBroadcast", "SightLatchWidget"})
        products = {}
        for name, (uid, obj) in targets.items():
            self.assertEqual(field(obj, "productName"), name)
            product = field(obj, "productReference")
            products[name] = product
            suffix = ".app" if name == "SightLatch" else ".appex"
            self.assertEqual(field(objects[product], "path"), name + suffix)
            configs = objects[field(obj, "buildConfigurationList")]
            for config_id in ids(configs, "buildConfigurations"):
                self.assertEqual(field(objects[config_id], "PRODUCT_NAME"), name)
        app_id, app = targets["SightLatch"]
        dependencies = [objects[uid] for uid in ids(app, "dependencies")]
        self.assertEqual({field(obj, "target") for obj in dependencies},
                         {targets[name][0] for name in targets if name != "SightLatch"})
        for dependency in dependencies:
            target_id = field(dependency, "target")
            proxy = objects[field(dependency, "targetProxy")]
            self.assertEqual(field(proxy, "remoteGlobalIDString"), target_id)
            self.assertEqual(field(proxy, "remoteInfo"), field(objects[target_id], "name"))
        embed = [objects[uid] for uid in ids(app, "buildPhases")
                 if "isa = PBXCopyFilesBuildPhase;" in objects[uid]]
        self.assertEqual(len(embed), 1)
        self.assertEqual(field(embed[0], "dstSubfolderSpec"), "13")
        self.assertEqual({field(objects[uid], "fileRef") for uid in ids(embed[0], "files")},
                         {products["SightLatchBroadcast"], products["SightLatchWidget"]})
        schemes = list(project_path.glob("xcshareddata/xcschemes/*.xcscheme"))
        self.assertEqual([p.name for p in schemes], ["SightLatch.xcscheme"])
        refs = ET.parse(schemes[0]).findall(".//BuildableReference")
        self.assertGreaterEqual(len(refs), 2)
        for ref in refs:
            self.assertEqual(ref.get("BlueprintIdentifier"), app_id)
            self.assertEqual(ref.get("BlueprintName"), "SightLatch")
            self.assertEqual(ref.get("BuildableName"), "SightLatch.app")
            self.assertEqual(ref.get("ReferencedContainer"), "container:SightLatch.xcodeproj")
        for folder, display in (("App", "SightLatch"), ("Broadcast", "SightLatch Broadcast"),
                                ("Widget", "SightLatch Widget")):
            info = plistlib.loads((ROOT / "ios" / folder / "Info.plist").read_bytes())
            self.assertEqual(info["CFBundleDisplayName"], display)
            self.assertEqual(info["CFBundleName"], "$(PRODUCT_NAME)")
            self.assertEqual(info["CFBundleExecutable"], "$(EXECUTABLE_NAME)")
        broadcast = plistlib.loads((ROOT / "ios/Broadcast/Info.plist").read_bytes())
        self.assertEqual(broadcast["NSExtension"]["NSExtensionPrincipalClass"],
                         "$(PRODUCT_MODULE_NAME).SampleHandler")

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
        config = source("ios/Config/Project.xcconfig")
        self.assertIn('#include? "Local.xcconfig"', config)
        self.assertNotRegex(config, r'(?m)^#include\s')
        self.assertIn("CODE_SIGN_STYLE = Automatic", config)
        self.assertNotRegex(config, r'(?m)^DEVELOPMENT_TEAM\s*=')
        # Copying the optional template unchanged must not introduce placeholders.
        example = source("ios/Config/Local.example.xcconfig")
        self.assertFalse(any(line.strip() and not line.strip().startswith("//")
                             for line in example.splitlines()))
        project = source("ios/SightLatch.xcodeproj/project.pbxproj")
        configs = re.findall(r'isa = XCBuildConfiguration;[^\n]+', project)
        target_configs = [line for line in configs if "PRODUCT_BUNDLE_IDENTIFIER" in line]
        self.assertEqual(len(target_configs), 6)  # three targets, Debug and Release
        for line in target_configs:
            self.assertIn("baseConfigurationReference = 34B9BDFA2199BFE7B0D4BD9F", line)
            self.assertNotIn("DEVELOPMENT_TEAM", line)
            self.assertNotIn("CODE_SIGN_STYLE", line)
        for suffix in ("", ".Broadcast", ".Widget"):
            self.assertEqual(project.count('PRODUCT_BUNDLE_IDENTIFIER = "$(PILOT_BUNDLE_PREFIX)' + suffix + '"'), 2)

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
        explicit = ui.split('func requestDeviceControl(', 1)[1].split('func prepare()', 1)[0]
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
        start = ui.split('func prepare()', 1)[1].split('func stop()', 1)[0]
        self.assertIn('if device.supportsSoftwareControl, !device.armed', start)
        self.assertIn('guard taskFlow.consumePermission(goal:', start)
        self.assertLess(start.index('taskFlow.consumePermission'), start.index('sessionClient.armSoftwareControl'))
        self.assertIn('task.trimmingCharacters(in: .whitespacesAndNewlines) == preparedGoal', start)
        self.assertIn('guard device.control_lease_mode != "calibration"', start)
        calibration = source("ios/App/PilotPointerCalibration.swift")
        begin_calibration = calibration.split('func beginPointerCalibration()', 1)[1].split('private func calibrationIsCurrent', 1)[0]
        self.assertIn('guard !isSessionActive, !taskFlow.isBusy, !probing, !calibrationRequestInFlight', begin_calibration)
        self.assertIn('guard !device.armed', begin_calibration)
        self.assertIn('client.armSoftwareControl(expected: device, mode: "calibration")', begin_calibration)
        self.assertIn('device.control_lease_mode == "calibration"', begin_calibration)
        self.assertIn('remaining > 0, remaining <= 60_000', begin_calibration)
        self.assertIn('guard calibrationIsCurrent(id, phase: .starting) else { try await client.stopAndVerify(); return }', begin_calibration)
        self.assertIn('guard preparationID == token', start)
        self.assertIn('requestedSoftwareArm = true', start)
        self.assertIn('try await sessionClient.stopAndVerify()', start)
        resume = ui.split('func resumeAfterManual()', 1)[1].split('func manual(', 1)[0]
        self.assertNotIn('armSoftwareControl', resume)
        stop = ui.split('func stop() async', 1)[1].split('func recoverDamagedSettings()', 1)[0]
        self.assertIn('deviceControlID = UUID()', stop)
        self.assertIn('deviceObservationID = UUID()', stop)
        self.assertIn('lastDeviceStatus = nil', stop)
        self.assertIn('while preparingRequestInFlight || controllingDevice', stop)
        self.assertIn('let hadControlRequestInFlight = preparingRequestInFlight || controllingDevice', stop)
        view = source("ios/App/HomeView.swift")
        for title in ['允许屏幕上传与设备控制', '开始蓝牙配对', '允许并自动校准', '停止控制']:
            self.assertIn(title, view)

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
        self.assertIn('Text(model.status.detail)', view)
        self.assertIn('$0.sessionID == model.status.sessionID', view)
        self.assertIn('model.status.sessionID == command.id', view)
        self.assertIn('DisclosureGroup("执行过程', view)
        self.assertIn('VoiceTaskComposer(text: $model.task)', view)
        self.assertIn('GlassEffectContainer(spacing:', view)
        self.assertIn('buttonStyle(.glassProminent)', view)
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
        self.assertIn("sessionClient.armSoftwareControl(expected: device)", ui)
        calibration = source("ios/App/PilotPointerCalibration.swift")
        self.assertIn('client.armSoftwareControl(expected: device, mode: "calibration")', calibration)
        self.assertIn('device.control_epoch == calibrationFlow.controlEpoch', calibration)
        self.assertIn('device.boot_id == calibrationFlow.bootID', calibration)
        self.assertIn('device.session_id == calibrationFlow.sessionID', calibration)
        # Exactly the task-permit and explicit short calibration paths may call ARM.
        arm_calls = []
        for path in (ROOT / "ios" / "App").glob("*.swift"):
            for line in path.read_text().splitlines():
                if '.armSoftwareControl(' in line:
                    arm_calls.append((path.name, line.strip()))
        self.assertEqual({name for name, _ in arm_calls}, {"PilotViewModel.swift", "PilotPointerCalibration.swift"})
        self.assertEqual(len(arm_calls), 2)
        cancel = network.split('func closePairingWindow(', 1)[1].split('func armSoftwareControl(', 1)[0]
        self.assertIn('Cancellation(boot_id: expected.boot_id, control_epoch: expected.control_epoch)', cancel)
        self.assertIn('request("v1/cancel_pairing", method: "POST"', cancel)
        self.assertIn('error.statusCode == 409', cancel)
        self.assertNotIn('stopAndVerify', cancel)

    def test_activity_start_rechecks_command_after_suspension(self):
        manager = source("ios/App/PilotActivityManager.swift")
        start = manager.split("func start(sessionID:", 1)[1].split("func publish(", 1)[0]
        self.assertIn("command.id == sessionID, command.running", start)
        self.assertIn("current.id == sessionID, current.running", start)
        self.assertLess(start.index("await activity.end"), start.index("current.id == sessionID"))
        self.assertLess(start.index("current.id == sessionID"), start.index("Activity.request"))

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
        self.assertIn("func stopAndVerify() async throws", network)
        self.assertIn("if !current.armed && !current.busy { return }", network)
        ui = source("ios/App/PilotViewModel.swift")
        self.assertIn("但未确认硬件停止送达", ui)
        intent = source("ios/Shared/PilotIntents.swift")
        self.assertLess(intent.index("catch { localRevoked = false }"), intent.index("stopAndVerify()"))

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
        self.assertFalse((ROOT / "firmware/IPhoneHIDBridge/config.h").exists())
        self.assertFalse((ROOT / "ios/Config/Local.xcconfig").exists())

if __name__ == "__main__":
    unittest.main(verbosity=2)
