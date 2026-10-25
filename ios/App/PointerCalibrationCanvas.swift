import SwiftUI
import UIKit

/// UIKit event metadata stays typed; direct touches never become hardware-click evidence here.
struct PointerCalibrationCanvas: UIViewRepresentable {
    let model: PilotViewModel
    func makeUIView(context: Context) -> CalibrationCanvasView {
        let view = CalibrationCanvasView()
        view.model = model
        return view
    }
    func updateUIView(_ uiView: CalibrationCanvasView, context: Context) { uiView.model = model }
    static func dismantleUIView(_ uiView: CalibrationCanvasView, coordinator: ()) {
        uiView.model?.calibrationCanvasDetached()
    }
}
/// The public host marks its surface ready after the full-screen presentation completes.
struct AbsoluteCalibrationCanvas: UIViewControllerRepresentable {
    let model: PilotViewModel
    func makeUIViewController(context: Context) -> AbsoluteCalibrationCanvasController {
        AbsoluteCalibrationCanvasController(model: model)
    }
    func updateUIViewController(_ controller: AbsoluteCalibrationCanvasController, context: Context) {
        controller.canvas.model = model
    }
    static func dismantleUIViewController(_ controller: AbsoluteCalibrationCanvasController, coordinator: ()) {
        controller.canvas.detachFromModel()
    }
}
final class AbsoluteCalibrationCanvasController: UIViewController {
    let canvas = CalibrationCanvasView()
    init(model: PilotViewModel) {
        super.init(nibName: nil, bundle: nil)
        canvas.model = model
        canvas.isFullScreenCalibration = true
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func loadView() { view = canvas }
    override var prefersStatusBarHidden: Bool { true }
    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        canvas.presentationReady = true
        canvas.setNeedsLayout(); canvas.layoutIfNeeded()
    }
    override func viewWillDisappear(_ animated: Bool) {
        canvas.presentationReady = false
        canvas.setNeedsLayout(); canvas.layoutIfNeeded()
        super.viewWillDisappear(animated)
    }
}
final class CalibrationCanvasView: UIView {
    weak var model: PilotViewModel?
    var isFullScreenCalibration = false
    var presentationReady = false
    private weak var geometryWindow: UIWindow?
    private var geometryID = UUID()
    private var measurementID: UUID?
    private var measurementFlowID: UUID?
    private var lockedWindowFrame: CGRect?
    private weak var lockedWindow: UIWindow?
    private var discardedMeasurementID: UUID?
    private var beganPrimaryButtons: [ObjectIdentifier: Bool] = [:]
    func detachFromModel() {
        model?.calibrationCanvasDetached(surfaceID: isFullScreenCalibration ? geometryID : nil)
    }
    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .secondarySystemBackground
        layer.cornerRadius = 20
        let hover = UIHoverGestureRecognizer(target: self, action: #selector(hovered(_:)))
        hover.allowedTouchTypes = [NSNumber(value: UITouch.TouchType.indirectPointer.rawValue)]
        addGestureRecognizer(hover)
        accessibilityLabel = "安全指针测试画布。自动测量期间请勿触碰屏幕，设备将通过受控点击提供实际坐标。"
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func layoutSubviews() {
        super.layoutSubviews()
        guard let window else { return }
        if geometryWindow !== window { geometryWindow = window; geometryID = UUID() }
        let orientation = window.windowScene?.interfaceOrientation.isLandscape == true ? "landscape" : "portrait"
        let screen = window.screen
        let frame = window.convert(convert(bounds, to: window), to: screen.coordinateSpace)
        let surface = isFullScreenCalibration ? AbsoluteCalibrationSurface(id: geometryID,
            originX: Double(frame.minX - screen.bounds.minX), originY: Double(frame.minY - screen.bounds.minY),
            width: Double(frame.width), height: Double(frame.height), screenWidth: Double(screen.bounds.width), screenHeight: Double(screen.bounds.height),
            presentationReady: presentationReady && window.windowScene?.activationState == .foregroundActive) : nil
        model?.updateCalibrationCanvas(width: Double(bounds.width), height: Double(bounds.height),
            context: PointerCalibrationContext(deviceURL: model?.configuration.deviceURL ?? "",
                phoneModel: UIDevice.current.model, orientation: orientation,
                pixelWidth: Int(window.screen.bounds.width * window.screen.scale),
                pixelHeight: Int(window.screen.bounds.height * window.screen.scale), scale: Double(window.screen.scale)), surface: surface)
    }
    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        let primary = event?.buttonMask.contains(.primary) == true
        for touch in touches {
            beganPrimaryButtons[ObjectIdentifier(touch)] = primary
            recordProbeTouch(touch, phase: .began, primaryButton: primary)
        }
        super.touchesBegan(touches, with: event)
    }
    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
        for touch in touches {
            let primary = beganPrimaryButtons.removeValue(forKey: ObjectIdentifier(touch)) == true ||
                event?.buttonMask.contains(.primary) == true
            recordProbeTouch(touch, phase: .ended, primaryButton: primary)
        }
        super.touchesEnded(touches, with: event)
    }
    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) {
        for touch in touches {
            let primary = beganPrimaryButtons.removeValue(forKey: ObjectIdentifier(touch)) == true ||
                event?.buttonMask.contains(.primary) == true
            recordProbeTouch(touch, phase: .cancelled, primaryButton: primary)
        }
        super.touchesCancelled(touches, with: event)
    }
    private func recordProbeTouch(_ touch: UITouch, phase: CalibrationProbeTouchPhase, primaryButton: Bool) {
        guard let model else { return }
        let point = touch.location(in: self)
        guard let window else { return }
        let screen = window.screen
        let screenPoint = window.convert(touch.location(in: window), to: screen.coordinateSpace)
        let observed = isFullScreenCalibration
            ? CGPoint(x: (screenPoint.x - screen.bounds.minX) * screen.scale, y: (screenPoint.y - screen.bounds.minY) * screen.scale)
            : point
        let source: CalibrationProbeTouchSource
        switch touch.type {
        case .indirectPointer: source = .indirectPointer
        case .direct: source = .direct
        default: source = .other
        }
        let timestamp = touch.timestamp
        withStableObservationFrame(at: point) {
            model.observeCalibrationProbeTouch(x: Double(observed.x), y: Double(observed.y), source: source,
                phase: phase, timestamp: timestamp, primaryButton: primaryButton)
        }
    }
    override func draw(_ rect: CGRect) {
        super.draw(rect)
        let border = UIBezierPath(roundedRect: bounds.insetBy(dx: 20, dy: 20), cornerRadius: 12)
        UIColor.separator.setStroke(); border.lineWidth = 1; border.stroke()

    }
    @objc private func hovered(_ recognizer: UIHoverGestureRecognizer) {
        guard recognizer.state == .began || recognizer.state == .changed else { return }
        let point = recognizer.location(in: self)
        guard bounds.contains(point) else { return }
        guard let model else { return }
        withStableObservationFrame(at: point) {
            model.observeCalibrationPointer(x: Double(point.x), y: Double(point.y))
        }
    }
    private func withStableObservationFrame(at point: CGPoint, observe: () -> Void) {
        guard let model, point.x.isFinite, point.y.isFinite else { return }
        let id = model.automaticCalibration.id
        let flowID = model.calibrationFlow.id
        guard discardedMeasurementID != id else { return }
        let measuring = model.automaticCalibration.isBusy && model.calibrationActive &&
            model.calibrationFlow.purpose == .measurement && model.automaticCalibration.phase != .positioning
        if measurementID != id || measurementFlowID != flowID || !measuring {
            measurementID = id
            measurementFlowID = flowID
            lockedWindowFrame = nil
            lockedWindow = nil
        }
        var observedFrame: CGRect?
        if measuring {
            guard let window else { return }
            let frame = convert(bounds, to: window)
            if let locked = lockedWindowFrame {
                let changes = [frame.minX - locked.minX, frame.minY - locked.minY,
                               frame.width - locked.width, frame.height - locked.height]
                guard lockedWindow === window, changes.allSatisfy({ $0.isFinite && abs($0) <= 0.5 }) else {
                    model.calibrationCanvasPositionChanged(requestID: id)
                    discardedMeasurementID = model.automaticCalibration.id
                    return
                }
            }
            observedFrame = frame
        }
        let previousSequence = model.calibrationObservation?.sequence
        let probeActionID = model.automaticCalibration.probeWindow?.actionID
        let previousProbeDown = model.automaticCalibration.probeWindow?.down
        let previousProbePoint = model.automaticCalibration.probeWindow?.point
        observe()
        let probe = model.automaticCalibration.probeWindow
        let acceptedProbeTouch = probeActionID != nil && probe?.actionID == probeActionID && probe?.failure == nil &&
            ((previousProbeDown == nil && probe?.down != nil) || (previousProbePoint == nil && probe?.point != nil))
        // Keep the first real observation's origin across every probe in this measurement.
        // Initial layout/positioning and each probe's pending-window creation do not lock/reset it.
        if measuring, model.automaticCalibration.id == id, model.calibrationFlow.id == flowID,
           model.calibrationObservation?.sequence != previousSequence || acceptedProbeTouch,
           lockedWindowFrame == nil {
            lockedWindowFrame = observedFrame
            lockedWindow = window
        }
    }
}

extension PilotViewModel {
    func calibrationCanvasPositionChanged(requestID: UUID) {
        guard automaticCalibration.id == requestID, automaticCalibration.isBusy,
              calibrationFlow.purpose == .measurement else { return }
        let cancellationID = UUID()
        let flowID = calibrationFlow.id
        let reason = "测量期间画布位置改变，请重新定位。"
        // Invalidate the sampling coroutine before awaiting any network work; it cannot save.
        automaticCalibration.id = cancellationID
        automaticCalibration.isAwaitingMarker = false
        automaticCalibration.isAwaitingProbe = false
        automaticCalibration.probeWindow = nil
        automaticCalibration.phase = .detecting
        automaticCalibration.detail = reason + " 正在确认停止，未保存新的校准。"
        calibrationObservation = nil
        notice = automaticCalibration.detail
        Task { [weak self] in
            guard let self, self.automaticCalibration.id == cancellationID,
                  self.calibrationFlow.id == flowID else { return }
            await self.endPointerCalibration()
            guard self.automaticCalibration.id == cancellationID,
                  self.calibrationFlow.id == flowID else { return }
            self.automaticCalibration.phase = .error
            self.automaticCalibration.detail = reason + " 未保存新的校准。 " +
                (self.calibrationFlow.stopConfirmed ? "设备已确认停止。" :
                    (self.calibrationFlow.errorMessage ?? "未确认设备停止，请按物理 STOP 或拔掉 USB 电源。"))
            self.notice = self.automaticCalibration.detail
        }
    }
}
