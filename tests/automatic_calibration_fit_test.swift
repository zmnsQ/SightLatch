import Foundation
@main struct Tests {
 static func main() throws {
  let commands = [(5,0),(-5,0),(10,0),(-10,0),(0,5),(0,-5),(0,10),(0,-10)]
  let rows = commands.map { dx,dy in CalibrationMotionSample(dx: dx, dy: dy, before: .init(x: 100,y: 100), after: .init(x:100 + Double(dx)*1.2,y:100 + Double(dy)*1.6)) }
  let fit = try CalibrationFit.fit(rows)
  precondition(abs(fit.x - 1.2) < 0.001 && abs(fit.y - 1.6) < 0.001)
  let check = CalibrationMotionSample(dx: 7,dy:0,before:.init(x:100,y:100),after:.init(x:108.4,y:100))
  precondition(CalibrationFit.validate(check,x:fit.x,y:fit.y))
  var bad = check; bad.after.x = 120
  precondition(!CalibrationFit.validate(bad,x:fit.x,y:fit.y))
  var inconsistent = rows; inconsistent[0].after.x = 100
  do { _ = try CalibrationFit.fit(inconsistent); fatalError("Zero movement passed") } catch {}
  inconsistent = rows; inconsistent[0].after.y = 110
  do { _ = try CalibrationFit.fit(inconsistent); fatalError("Cross-axis drift passed") } catch {}
  do { _ = try CalibrationFit.fit(Array(rows.prefix(3))); fatalError("Too few samples passed") } catch {}
  var probe = CalibrationProbeWindow(actionID:"one",openedAt:100,deadline:102)
  let point = CalibrationPoint(x:150,y:120)
  probe.observe(point:point,source:.direct,phase:.began,timestamp:100.1,primaryButton:false)
  probe.observe(point:point,source:.direct,phase:.ended,timestamp:100.2,primaryButton:false)
  precondition(probe.down == nil && probe.verifiedPoint == nil, "Finger input cannot be pointer evidence")
  probe.observe(point:point,source:.indirectPointer,phase:.began,timestamp:100.3,primaryButton:true)
  probe.observe(point:point,source:.indirectPointer,phase:.ended,timestamp:100.34,primaryButton:false)
  precondition(probe.verifiedPoint == nil, "UIKit coordinates without matching hardware completion are insufficient")
  probe.completeHardware(actionID:"one"); precondition(probe.verifiedPoint == point)
  var wrongReceipt = CalibrationProbeWindow(actionID:"two",openedAt:100,deadline:102)
  wrongReceipt.completeHardware(actionID:"one"); precondition(wrongReceipt.failure != nil && wrongReceipt.verifiedPoint == nil)
  var late = CalibrationProbeWindow(actionID:"three",openedAt:100,deadline:102)
  late.observe(point:point,source:.indirectPointer,phase:.began,timestamp:102.1,primaryButton:true)
  precondition(late.down == nil && late.failure != nil)
  var wrongButton = CalibrationProbeWindow(actionID:"four",openedAt:100,deadline:102)
  wrongButton.observe(point:point,source:.indirectPointer,phase:.began,timestamp:100.1,primaryButton:false)
  precondition(wrongButton.failure != nil)
  var correlated = CalibrationProbeWindow(actionID:"five",openedAt:100,deadline:102,allowsCorrelatedDirect:true)
  correlated.observe(point:point,source:.direct,phase:.began,timestamp:100.1,primaryButton:false)
  correlated.observe(point:point,source:.direct,phase:.ended,timestamp:100.1,primaryButton:false)
  precondition(correlated.point == point && correlated.verifiedPoint == nil && correlated.eventCount == 2)
  correlated.completeHardware(actionID:"five"); precondition(correlated.verifiedPoint == point)
  correlated.observe(point:point,source:.direct,phase:.began,timestamp:100.2,primaryButton:false)
  precondition(correlated.failure != nil && correlated.verifiedPoint == nil,"Extra direct touch poisons the entire probe")
  var long = CalibrationProbeWindow(actionID:"six",openedAt:100,deadline:102,allowsCorrelatedDirect:true)
  long.observe(point:point,source:.direct,phase:.began,timestamp:100.1,primaryButton:false)
  long.observe(point:point,source:.direct,phase:.ended,timestamp:100.8,primaryButton:false)
  precondition(long.failure!.contains("700"))
  var mixed = CalibrationProbeWindow(actionID:"seven",openedAt:100,deadline:102,allowsCorrelatedDirect:true)
  mixed.observe(point:point,source:.direct,phase:.began,timestamp:100.1,primaryButton:false)
  mixed.observe(point:point,source:.indirectPointer,phase:.ended,timestamp:100.14,primaryButton:false)
  precondition(mixed.failure != nil)
  let absoluteTruth = AbsoluteCalibrationFit.Transform(a: 0.12, b: 0.002, c: 24, d: -0.001, e: 0.26, f: 50)
  let absoluteSamples = AbsoluteCalibrationPlan.targets.map { AbsoluteCalibrationSample(target: $0, screen: absoluteTruth.point($0)) }
  let absoluteFit = try AbsoluteCalibrationFit.fit(AbsoluteCalibrationPlan.fitIndices.map { absoluteSamples[$0] }, tolerancePixels: 4.5)
  for index in AbsoluteCalibrationPlan.validationIndices {
   precondition(AbsoluteCalibrationFit.residual(absoluteSamples[index], transform: absoluteFit.transform) < 1e-8)
  }
  precondition(abs(absoluteFit.transform.c - 24) < 1e-8 && abs(absoluteFit.transform.f - 50) < 1e-8,
               "Absolute origins must come from measured full-screen observations, not relative slopes")
  let collinear = [1000,3000,6000,9000].map { value -> AbsoluteCalibrationSample in
   let target = AbsoluteCalibrationTarget(x:value,y:value)
   return .init(target:target,screen:absoluteTruth.point(target))
  }
  do { _ = try AbsoluteCalibrationFit.fit(collinear,tolerancePixels:4.5); fatalError("Collinear absolute samples passed") } catch {}
  var bent = AbsoluteCalibrationPlan.fitIndices.map { absoluteSamples[$0] }; bent[0].screen.x += 100
  do { _ = try AbsoluteCalibrationFit.fit(bent,tolerancePixels:4.5); fatalError("Non-affine absolute mapping passed") } catch {}
  var invalid = bent; invalid[0].screen.x = .nan
  do { _ = try AbsoluteCalibrationFit.fit(invalid,tolerancePixels:4.5); fatalError("Nonfinite absolute observation passed") } catch {}
  let surface = AbsoluteCalibrationSurface(id:UUID(),originX:0,originY:0,width:420,height:912,screenWidth:420,screenHeight:912,presentationReady:true)
  precondition(surface.isFullScreen)
  var partial = surface; partial.height = 240; precondition(!partial.isFullScreen)
  partial = surface; partial.originY = 20; precondition(!partial.isFullScreen)
  partial = surface; partial.presentationReady = false; precondition(!partial.isFullScreen)
  print("PASS: deterministic measured motion fit, held-out validation, zero/stale movement, cross-axis drift and insufficient samples fail closed")
 }
}
