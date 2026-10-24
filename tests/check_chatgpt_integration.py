#!/usr/bin/env python3
"""Read-only integration source contracts; not Apple SDK typechecking."""
from pathlib import Path
import json
import re
import unittest
ROOT = Path(__file__).resolve().parents[1]

def source(path):
    return (ROOT / path).read_text()

class ChatGPTIntegration(unittest.TestCase):
    def test_visual_prompt_keys_match_gate_and_wait_needs_no_pointer(self):
        network = source("ios/Shared/Network.swift")
        prompt = network.split('var system = """', 1)[1].split('"""', 1)[0]
        advertised = re.search(r"Ordinary key actions support only ([A-Z,]+)\.", prompt)
        self.assertIsNotNone(advertised)
        key_gate = network.split("enum SafetyGate {", 1)[1].split("case .key:", 1)[1].split("case .text:", 1)[0]
        allowed = re.search(r'(\["ESC"[^\]]*\])\.contains\(action.key', key_gate)
        self.assertIsNotNone(allowed)
        self.assertEqual(set(advertised[1].split(",")), set(json.loads(allowed[1])))
        self.assertIn("A pure wait sends no HID, needs no visible pointer", prompt)
        self.assertIn("For move/click the pointer and next target must be visually located in this frame", prompt)
        self.assertIn("The floating AssistiveTouch menu/control is not the mouse pointer", prompt)

    def test_key_creation_has_explicit_string_keys(self):
        auth = source("ios/Shared/ChatGPTOAuth.swift")
        self.assertIn("[kSecAttrKeyType as String: kSecAttrKeyTypeRSA, kSecAttrKeyClass as String: kSecAttrKeyClassPublic] as CFDictionary", auth)

    def test_import_export_and_profile_selection_reset_plan_consent(self):
        workspace = source("ios/App/Workspace.swift")
        export = workspace.split("func exportSettings()", 1)[1].split("func importSettings", 1)[0]
        imported = workspace.split("func importSettings", 1)[1].split("func exportDiagnostics", 1)[0]
        select = workspace.split("func selectProfile", 1)[1].split("func removeProfile", 1)[0]
        self.assertIn("profiles[i].configuration.chatGPTPlanConsent = false", export)
        self.assertIn("profile.configuration.chatGPTPlanConsent = false", imported)
        self.assertIn('"chatgpt-plan"].contains(profile.configuration.provider)', imported)
        self.assertIn("candidate.chatGPTPlanConsent = false", select)

    def test_oauth_branch_precedes_api_key_load_and_uses_fixed_endpoint(self):
        network = source("ios/Shared/Network.swift")
        branch = network.index('if configuration.provider == "chatgpt-plan"')
        credential = network.index("let apiKey = try SecretStore.load(configuration.apiAccount)")
        self.assertLess(branch, credential)
        direct = network[branch:credential]
        self.assertIn("configuration.chatGPTPlanConsent == true", direct)
        self.assertIn('configuration.endpoint == "https://api.openai.com/v1/responses"', direct)
        self.assertIn("ChatGPTPlanClient.shared.response", direct)

    def test_system_auth_and_loopback_use_real_public_interfaces(self):
        login = source("ios/App/ChatGPTSignIn.swift")
        self.assertIn('ASWebAuthenticationSession(url: url, callbackURLScheme: nil)', login)
        self.assertIn('parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)', login)
        self.assertIn("try NWListener(using: parameters)", login)
        self.assertIn("self.webSession?.cancel()", login)
        self.assertIn("try Task.checkCancellation()", login)

if __name__ == "__main__":
    unittest.main(verbosity=2)
