#!/usr/bin/env python3
"""Type-check actual Activity code against iPhoneOS, without signing or a device.
Only unrelated storage/hardware/session dependencies use small compile stubs.
"""
from pathlib import Path
import subprocess, tempfile, shutil
ROOT=Path(__file__).resolve().parents[1]
SDK='/Applications/Xcode-beta.app/Contents/Developer/Platforms/iPhoneOS.platform/Developer/SDKs/iPhoneOS27.0.sdk'
SWIFTC='/Applications/Xcode-beta.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/swiftc'
out=Path(tempfile.mkdtemp(prefix='pilot-activity-sdk-'))
try:
    text=(ROOT/'ios/Shared/Models.swift').read_text()
    attrs='struct PilotActivityAttributes'+text.split('struct PilotActivityAttributes',1)[1].split('enum PilotError:',1)[0]
    status='struct PilotStatus'+text.split('struct PilotStatus',1)[1].split('struct ActionProposal',1)[0]
    (out/'Attributes.swift').write_text('import Foundation\nimport ActivityKit\n'+attrs+status)
    (out/'CompileDependencies.swift').write_text('''import Foundation
struct SessionCommand {
    struct Execution { enum Phase { case awaitingCapture, startingHardware, active }; var phase:Phase; var startedAt:Date?; var expiresAt:Date?; var isUnlimited=false }
    struct Scope { var stopGeneration:String?; func matches(sessionID:String,generation:Int,task:String)->Bool { true } }
    var id:String; var generation=0; var running=true; var task=""; var execution:Execution?; var messageScope:Scope?
    var executionStartedAt:Date? { execution?.startedAt }
}
struct ActivityCompileConfiguration { var uploadConsent=true }
final class SharedStore {
    static let shared=SharedStore(); var command:SessionCommand?; var status=PilotStatus.idle
    var stopGeneration:String?; var configuration=ActivityCompileConfiguration()
    func claimActivityAlert(sessionID:String,key:String)->Bool { false }
    func write<T:Encodable>(_ value:T,to name:String) throws {}
    func invalidatePendingStarts() throws {}
    func updateCommand(sessionID:String,_ change:(inout SessionCommand)->Void) throws {}
    func remove(_ name:String) {}
}
struct HardwareClient {
    init(configuration:ActivityCompileConfiguration) {}
    func stopAndVerify(expectedSessionID:String?) async throws {}
}
''')
    base=[SWIFTC,'-typecheck','-sdk',SDK,'-target','arm64-apple-ios18.0','-swift-version','5','-module-cache-path',str(out/'cache')]
    common=[str(out/'Attributes.swift'),str(out/'CompileDependencies.swift'),str(ROOT/'ios/Shared/PilotActivityPresentation.swift')]
    groups=[('App',[],['ios/App/PilotActivityManager.swift','ios/Shared/PilotIntents.swift']),
            ('Widget',['-application-extension'],['ios/Widget/PilotWidget.swift','ios/Shared/PilotIntents.swift']),
            ('Broadcast',['-application-extension'],[])]
    for label,flags,sources in groups:
        subprocess.run(base+flags+['-module-name','PilotActivity'+label]+common+[str(ROOT/p) for p in sources],check=True)
        print('PASS: actual iPhoneOS SDK activity '+label,flush=True)
finally: shutil.rmtree(out)
