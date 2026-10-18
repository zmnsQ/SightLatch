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
  print("PASS: deterministic measured motion fit, held-out validation, zero/stale movement, cross-axis drift and insufficient samples fail closed")
 }
}
