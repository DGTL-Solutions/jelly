import SwiftUI
import UIKit

/// Full-screen, invisible receiver for the Siri Remote while the player has no panel open.
/// SwiftUI on tvOS can't observe touch-surface swipes, which continuous scrubbing needs, so this is a UIKit view.
struct RemoteInput: UIViewRepresentable {
    enum Pan { case began, changed(CGFloat), ended }

    var isActive: Bool
    var onSelect: () -> Void
    var onPlayPause: () -> Void
    var onMenu: () -> Void
    var onMove: (MoveCommandDirection) -> Void
    var onPan: (Pan) -> Void

    func makeUIView(context: Context) -> RemoteInputView {
        let view = RemoteInputView()
        view.input = self
        return view
    }

    func updateUIView(_ view: RemoteInputView, context: Context) {
        let wasActive = view.input?.isActive ?? false
        view.input = self
        // Hand focus back once the panel closes; the view is the only focusable element then.
        if isActive, !wasActive { view.reclaimFocus() }
    }
}

final class RemoteInputView: UIView {
    var input: RemoteInput?

    override var canBecomeFocused: Bool { input?.isActive ?? false }

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .clear
        for (type, action) in [(UIPress.PressType.select, #selector(selectPressed)), (.playPause, #selector(playPausePressed)), (.menu, #selector(menuPressed))] {
            let tap = UITapGestureRecognizer(target: self, action: action)
            tap.allowedPressTypes = [NSNumber(value: type.rawValue)]
            addGestureRecognizer(tap)
        }
        let pan = UIPanGestureRecognizer(target: self, action: #selector(pan(_:)))
        pan.allowedTouchTypes = [NSNumber(value: UITouch.TouchType.indirect.rawValue)]
        addGestureRecognizer(pan)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        reclaimFocus()
    }

    func reclaimFocus() {
        DispatchQueue.main.async { [weak self] in
            self?.setNeedsFocusUpdate()
            self?.updateFocusIfNeeded()
        }
    }

    @objc private func selectPressed() { input?.onSelect() }
    @objc private func playPausePressed() { input?.onPlayPause() }
    @objc private func menuPressed() { input?.onMenu() }

    @objc private func pan(_ recognizer: UIPanGestureRecognizer) {
        switch recognizer.state {
        case .began: input?.onPan(.began)
        case .changed: input?.onPan(.changed(recognizer.translation(in: self).x))
        default: input?.onPan(.ended)
        }
    }

    /// Clicks on the edges of the touch surface or the ring of the newer remote.
    override func pressesBegan(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        var handled = false
        for press in presses {
            switch press.type {
            case .leftArrow: input?.onMove(.left); handled = true
            case .rightArrow: input?.onMove(.right); handled = true
            case .upArrow: input?.onMove(.up); handled = true
            case .downArrow: input?.onMove(.down); handled = true
            default: break
            }
        }
        if !handled { super.pressesBegan(presses, with: event) }
    }
}
