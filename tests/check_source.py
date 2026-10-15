#!/usr/bin/env python3
"""Source/packaging regression checks. These are NOT a Swift build or device test."""
from pathlib import Path
import plistlib
import re
import unittest

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
        project = source("ios/HIDPilot.xcodeproj/project.pbxproj")
        for path in (ROOT / "ios").rglob("*.swift"):
            self.assertIn(str(path.relative_to(ROOT / "ios")), project)
        refs = re.findall(r'path = "([^"]+\.(?:swift|plist|entitlements|xcconfig))"', project)
        for ref in refs:
            self.assertTrue((ROOT / "ios" / ref).is_file(), ref)
        self.assertEqual(project.count("isa = PBXNativeTarget"), 3)

    def test_command_mutation_uses_cross_process_lock(self):
        store = source("ios/Shared/SharedStore.swift")
        self.assertIn("flock(descriptor, LOCK_EX)", store)
        self.assertIn("guard current.id == sessionID", store)
        # The only raw command write outside SharedStore is new-session preparation.
        writers = []
        for path in (ROOT / "ios").rglob("*.swift"):
            if path.name == "SharedStore.swift":
                continue
            writers += [(path.name, line) for line in path.read_text().splitlines()
                        if 'write(' in line and 'to: "command.json"' in line]
        self.assertEqual(len(writers), 1, writers)
        self.assertEqual(writers[0][0], "PilotViewModel.swift")

    def test_provider_and_settings_fail_closed(self):
        network = source("ios/Shared/Network.swift")
        self.assertIn('["responses", "openai", "anthropic", "gemini"].contains(provider)', network)
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

    def test_local_secrets_are_ignored(self):
        ignored = source(".gitignore")
        for filename in ["firmware/IPhoneHIDBridge/config.h", "ios/Config/Local.xcconfig", "*.p12", ".env"]:
            self.assertIn(filename, ignored)
        self.assertFalse((ROOT / "firmware/IPhoneHIDBridge/config.h").exists())
        self.assertFalse((ROOT / "ios/Config/Local.xcconfig").exists())

if __name__ == "__main__":
    unittest.main(verbosity=2)
