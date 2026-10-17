#if canImport(UIKit)
import UIKit
import UltraView

/// Captures public recognizer observations and actual scroll delegate writes.
@MainActor
final class GestureRecorderController: UIViewController, UIScrollViewDelegate {
    private let scroll = UIScrollView(), name = UITextField(), record = UIButton(type: .system), save = UIButton(type: .system)
    private var start: Double = 0
    private var recording: GestureRecording?
    override func viewDidLoad() {
        super.viewDidLoad(); view.backgroundColor = .systemBackground
        scroll.delegate = self; scroll.contentInsetAdjustmentBehavior = .never; scroll.accessibilityIdentifier = "gestureCanvas"
        scroll.panGestureRecognizer.addTarget(self, action: #selector(panChanged))
        name.text = "medium-flick"; name.borderStyle = .roundedRect; name.accessibilityIdentifier = "recordingName"
        record.setTitle("Record", for: .normal); record.addTarget(self, action: #selector(begin), for: .touchUpInside)
        record.accessibilityIdentifier = "beginGestureRecording"
        save.setTitle("Save", for: .normal); save.addTarget(self, action: #selector(finish), for: .touchUpInside)
        save.accessibilityIdentifier = "saveGestureRecording"
        let bar = UIStackView(arrangedSubviews: [name, record, save]); bar.spacing = 8
        for v in [bar, scroll] { v.translatesAutoresizingMaskIntoConstraints = false; view.addSubview(v) }
        NSLayoutConstraint.activate([
            bar.topAnchor.constraint(equalTo: view.topAnchor), bar.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 12), bar.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -12), bar.heightAnchor.constraint(equalToConstant: 44),
            scroll.topAnchor.constraint(equalTo: bar.bottomAnchor, constant: 8), scroll.bottomAnchor.constraint(equalTo: view.bottomAnchor), scroll.leadingAnchor.constraint(equalTo: view.leadingAnchor), scroll.trailingAnchor.constraint(equalTo: view.trailingAnchor),
        ])
        for index in 0..<100 {
            let label = UILabel(frame: .init(x: 20, y: index * 80, width: 300, height: 70))
            label.text = "UIKit gesture sample \(index)"; label.backgroundColor = index % 2 == 0 ? .secondarySystemBackground : .tertiarySystemBackground
            label.layer.cornerRadius = 12; label.clipsToBounds = true; scroll.addSubview(label)
        }
    }
    override func viewDidLayoutSubviews() { super.viewDidLayoutSubviews(); scroll.contentSize = .init(width: scroll.bounds.width, height: 8000) }
    @objc private func begin() {
        view.endEditing(true)
        let fixture = name.text ?? "gesture"
        let maximum = 8000 - scroll.bounds.height
        scroll.setContentOffset(.init(x: 0, y: fixture == "into-bottom" ? maximum - 600 : fixture == "overscroll" ? maximum : 0), animated: false)
        start = CACurrentMediaTime()
        recording = .init(name: name.text ?? "gesture", viewport: scroll.bounds.height, edges: .init(minimum: 0, maximum: 8000 - scroll.bounds.height), scale: traitCollection.displayScale)
        record.setTitle("Recording", for: .normal)
    }
    func scrollViewDidScroll(_ scrollView: UIScrollView) {
        guard recording != nil else { return }
        let pan = scroll.panGestureRecognizer, tr = pan.translation(in: scroll), velocity = pan.velocity(in: scroll)
        recording?.frames.append(.init(time: CACurrentMediaTime() - start, offset: scroll.contentOffset.y, dragging: scroll.isDragging, translation: .init(x: tr.x, y: tr.y), velocity: .init(x: velocity.x, y: velocity.y)))
    }
    @objc private func panChanged() {
        guard recording != nil else { return }
        let pan = scroll.panGestureRecognizer, tr = pan.translation(in: scroll), velocity = pan.velocity(in: scroll)
        let phase: GestureRecording.Event.Phase
        switch pan.state {
        case .began: phase = .began
        case .changed: phase = .changed
        case .ended: phase = .ended
        case .cancelled: phase = .cancelled
        default: return
        }
        recording?.events.append(.init(time: CACurrentMediaTime() - start, phase: phase, translation: .init(x: tr.x, y: tr.y), velocity: .init(x: velocity.x, y: velocity.y)))
    }
    @objc private func finish() {
        guard let recording else { return }
        self.recording = nil
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        if let data = try? encoder.encode(recording), let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first {
            let directory = documents.appendingPathComponent("Gestures")
            try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try? data.write(to: directory.appendingPathComponent(recording.name + ".json"))
            print("GESTURE-SAVED \(recording.name) frames=\(recording.frames.count) events=\(recording.events.count)")
        }
        record.setTitle("Record", for: .normal)
    }
}
#endif