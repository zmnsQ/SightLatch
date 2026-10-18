#!/usr/bin/env python3
"""Compile production coordinator/calibration extension with fake device and direct marked-position inputs, no UIKit/network."""
from pathlib import Path
import tempfile, subprocess, os
root=Path(__file__).resolve().parents[1]
with tempfile.TemporaryDirectory() as tmp:
 p=Path(tmp)
 models=(root/'ios/Shared/Models.swift').read_text()
 modelTypes='struct PointerCalibrationContext:'+models.split('struct PointerCalibrationContext:',1)[1].split('struct SessionCommand:',1)[0]
 action='struct ActionProposal:'+models.split('struct ActionProposal:',1)[1].split('struct LogEntry:',1)[0]
 error='enum PilotError:'+models.split('enum PilotError:',1)[1].split('struct SharedFrame:',1)[0]
 (p/'Models.swift').write_text('import Foundation\n'+modelTypes+action+error)
 coordinator=(root/'ios/App/PilotAutomaticCalibration.swift').read_text().replace('import UIKit','')
 coordinator=coordinator.split('    func validateAutomaticCalibrationContext()',1)[0]+'}\n'
 coordinator=coordinator.replace('UIDevice.current.userInterfaceIdiom == .phone','true')
 (p/'Coordinator.swift').write_text(coordinator)
 mock=(root/'tests/pointer_calibration_test.swift').read_text().split('@main struct CalibrationTests',1)[0]
 mock=mock.replace('    static var failStop = false','    static var failStop = false\n    static var onMove: ((Int,Int)->Void)?')
 mock=mock.replace('        Self.calls.append("move")','        Self.calls.append("move")\n        Self.onMove?(proposal.dx!, proposal.dy!)')
 mock=mock.replace('    var configuration = PilotConfiguration()', '''    var automaticCalibration = AutomaticCalibrationState()
    var calibrationObservation: CalibrationObservation?
    var calibrationCanvasContext: PointerCalibrationContext?
    var calibrationCanvasWidth = 0.0, calibrationCanvasHeight = 0.0
    var configuration = PilotConfiguration()''')
 mock+='''
@main struct CoordinatorTests {
 @MainActor static func main() async throws {
  let model = PilotViewModel()
  let context = PointerCalibrationContext(deviceURL: model.configuration.deviceURL, phoneModel:"mock",orientation:"portrait",pixelWidth:800,pixelHeight:1200,scale:2)
  model.updateCalibrationCanvas(width:300,height:300,context:context)
  var x=150.0, y=150.0
  HardwareClient.onMove = { dx,dy in x += Double(dx)*1.2; y += Double(dy)*1.6 }
  let marks = Task {
   while !Task.isCancelled {
    if model.automaticCalibration.isAwaitingMarker { model.markObservedPointer(x:x,y:y) }
    try? await Task.sleep(nanoseconds:20_000_000)
   }
  }
  await model.startAssistedCalibration()
  marks.cancel()
  precondition(model.automaticCalibration.phase == .completed)
  precondition(!HardwareClient.device.armed)
  precondition(model.configuration.automaticCalibrationProfile!.observationSource.contains("User-marked"))
  precondition(abs(model.configuration.calibrationX-240)<0.001)
  precondition(abs(model.configuration.calibrationY-320)<0.001)
  precondition(HardwareClient.calls.filter{$0=="move"}.count==6)
  let old = model.configuration.automaticCalibrationProfile!.verifiedAt
  // Finger taps outside explicit waiting phase cannot become pointer observations.
  let previous=model.calibrationObservation!.sequence
  model.markObservedPointer(x:50,y:50)
  precondition(model.calibrationObservation!.sequence==previous)
  // Cancel waiting for first annotation: no move, no new saved grant.
  HardwareClient.calls=[]
  let pending=Task { await model.startAssistedCalibration() }
  try await Task.sleep(nanoseconds:50_000_000)
  await model.cancelAutomaticCalibration()
  await pending.value
  precondition(!HardwareClient.device.armed)
  precondition(!HardwareClient.calls.contains("move"))
  precondition(model.configuration.automaticCalibrationProfile!.verifiedAt==old)
  var rotated=context; rotated.orientation="landscape"
  model.updateCalibrationCanvas(width:300,height:300,context:rotated)
  precondition(!model.configuration.relativeModeConfirmed)
  print("PASS: production assisted coordinator, six bounded moves/seven explicit marked positions, measured fit and held-out validation, verified STOP before save, no idle taps, cancellation zero moves, changed geometry invalidates; mocked inputs only, not iPhone validation")
 }
}
'''
 (p/'Mocks.swift').write_text(mock)
 files=[str(p/'Models.swift'),str(root/'ios/Shared/TaskPlanning.swift'),str(root/'ios/Shared/PointerCalibration.swift'),str(root/'ios/Shared/AutomaticCalibration.swift'),str(root/'ios/App/PilotPointerCalibration.swift'),str(p/'Coordinator.swift'),str(p/'Mocks.swift')]
 subprocess.run([os.environ.get('SWIFTC','swiftc'),'-module-cache-path',str(p/'cache'),*files,'-o',str(p/'test')],check=True)
 subprocess.run([str(p/'test')],check=True,timeout=20)
