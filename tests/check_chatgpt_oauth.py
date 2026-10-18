#!/usr/bin/env python3
"""Run the actual Foundation SSE accumulator, plus source boundary checks.
Apple UI/framework typechecking and real OAuth are explicitly outside this test.
"""
import os
from pathlib import Path
import shutil
import subprocess
import tempfile

root = Path(__file__).resolve().parents[1]
source = (root / "ios/Shared/ChatGPTPlanClient.swift").read_text()
swift = os.environ.get("SWIFTC") or shutil.which("swiftc")
assert swift, "Set SWIFTC to a Swift compiler"
parser = source[source.index("struct ChatGPTSSEAccumulator"):source.index("actor ChatGPTPlanClient")]
tests = r'''
import Foundation
enum ChatGPTAuthError: LocalizedError {
    case message(String)
    var errorDescription: String? { if case .message(let text) = self { return text }; return nil }
}
'''+parser+r'''
func event(_ json: String, _ parser: inout ChatGPTSSEAccumulator) throws {
    try parser.consume(line: "data: " + json)
    try parser.consume(line: "")
}
func fails(_ body: () throws -> Void) { do { try body(); fatalError("Expected failure") } catch {} }
var success = ChatGPTSSEAccumulator()
try event(#"{"type":"response.output_text.delta","delta":"{\"type\":\"wait\"}"}"#, &success)
fails { _ = try success.result() }
try event(#"{"type":"response.completed","response":{"status":"completed"}}"#, &success)
let output = try success.result()
assert(output == #"{"type":"wait"}"#)
for terminal in ["response.failed", "response.incomplete", "error"] {
    var parser = ChatGPTSSEAccumulator()
    try event(#"{"type":"response.output_text.delta","delta":"{\"type\":\"click\"}"}"#, &parser)
    fails { try event("{\"type\":\"" + terminal + "\"}", &parser) }
    fails { _ = try parser.result() }
}
var bad = ChatGPTSSEAccumulator()
fails { try event(#"{"type":"response.completed","response":{"status":"incomplete"}}"#, &bad) }
fails { try event("[DONE]", &bad) }
fails { try event("not-json", &bad) }
var empty = ChatGPTSSEAccumulator()
try event(#"{"type":"response.completed","response":{"status":"completed"}}"#, &empty)
fails { _ = try empty.result() }
var large = ChatGPTSSEAccumulator()
fails { try event("{\"type\":\"response.output_text.delta\",\"delta\":\"" + String(repeating: "x", count: 8000) + "\"}", &large) }
var comment = ChatGPTSSEAccumulator()
try comment.consume(line: ": keepalive")
try comment.consume(line: "")
assert(!comment.completed)
print("PASS: real Swift SSE completion, failure, malformed, size, empty and partial-output tests")
'''
with tempfile.TemporaryDirectory() as directory:
    path = Path(directory)
    (path / "main.swift").write_text(tests)
    subprocess.run([swift, "-module-cache-path", str(path / "cache"), str(path / "main.swift"), "-o", str(path / "test")], check=True)
    subprocess.run([str(path / "test")], check=True)
auth = (root / "ios/Shared/ChatGPTOAuth.swift").read_text()
ui = (root / "ios/App/ChatGPTSignIn.swift").read_text()
assert '"store": false, "stream": true' in source
assert 'max_output_tokens' not in source
assert 'https://api.openai.com/v1/responses' in source
assert 'backend-api' not in source + auth + ui
assert 'code_challenge_method": "S256"' in ui
assert 'single("state") == state' in ui
assert 'expectedSubject == nil || expectedSubject == identity.subject' in auth
assert 'SecKeyVerifySignature' in auth and 'claims["nonce"] as? String == nonce' in auth
assert 'LOCK_EX | LOCK_NB' in auth and 'kSecItem' not in auth  # no fake constant
assert 'parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1"' in ui
assert 'resumeCallback(.failure(CancellationError()))' in ui
assert 'vault.pendingClientID = clientID' in auth
print("PASS: OAuth source boundary checks (not an iOS runtime test)")
