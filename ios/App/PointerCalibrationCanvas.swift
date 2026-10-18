import SwiftUI
import UIKit

/// Real UIKit indirect-pointer events only. Finger/Pencil input is never a pointer sample.
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
final class CalibrationCanvasView: UIView {
    weak var model: PilotViewModel?
    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .secondarySystemBackground
        layer.cornerRadius = 20
        let hover = UIHoverGestureRecognizer(target: self, action: #selector(hovered(_:)))
        hover.allowedTouchTypes = [NSNumber(value: UITouch.TouchType.indirectPointer.rawValue)]
        addGestureRecognizer(hover)
        let tap = UITapGestureRecognizer(target: self, action: #selector(marked(_:)))
        tap.allowedTouchTypes = [NSNumber(value: UITouch.TouchType.direct.rawValue)]
        addGestureRecognizer(tap)
        accessibilityLabel = "指针观测安全画布。辅助校准时，请用手指标记你看到的实际指针位置。画布没有模拟指针。"
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func layoutSubviews() {
        super.layoutSubviews()
        guard let window else { return }
        let orientation = window.windowScene?.interfaceOrientation.isLandscape == true ? "landscape" : "portrait"
        model?.updateCalibrationCanvas(width: Double(bounds.width), height: Double(bounds.height),
            context: PointerCalibrationContext(deviceURL: model?.configuration.deviceURL ?? "",
                phoneModel: UIDevice.current.model, orientation: orientation,
                pixelWidth: Int(window.screen.bounds.width * window.screen.scale),
                pixelHeight: Int(window.screen.bounds.height * window.screen.scale), scale: Double(window.screen.scale)))
    }
    @objc private func marked(_ recognizer: UITapGestureRecognizer) {
        guard recognizer.state == .ended else { return }
        let point = recognizer.location(in: self)
        model?.markObservedPointer(x: Double(point.x), y: Double(point.y))
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
        model?.observeCalibrationPointer(x: Double(point.x), y: Double(point.y))
    }
}
