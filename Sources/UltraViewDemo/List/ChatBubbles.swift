#if canImport(UIKit)
import UIKit
import UltraView

/// Curves and sizes for the chat's bubble animations. Every animation inside
/// a bubble takes its timing from the list pass that changes the row, so
/// these choose the passes' transitions.
struct BubbleAnimationConfig {
    /// A reply growing word by word, an edit, a rewrap. A curve that starts
    /// fast keeps chained retargets moving.
    var growth: ListTransition = .spring(0.35)
    /// Sending: the pass that inserts the message. The composer's shrink
    /// shares its timing.
    var send: ListTransition = .easeInOut(0.3)
    /// A reply's first appearance.
    var incoming: ListTransition = .easeInOut(0.3)
    /// A new reply's bubble grows from this scale about its tail corner.
    var appearScale: CGFloat = 0.82
    /// Time between streamed tokens.
    var streamInterval: Duration = .milliseconds(100)

    /// Defaults, with launch-argument overrides: `-bubbleGrowthDuration`,
    /// `-bubbleSendDuration`, `-bubbleStreamInterval` (milliseconds) and
    /// `-bubbleAppearScale`.
    static var current: BubbleAnimationConfig {
        var config = BubbleAnimationConfig()
        let defaults = UserDefaults.standard
        if defaults.double(forKey: "bubbleGrowthDuration") > 0 { config.growth = .spring(defaults.double(forKey: "bubbleGrowthDuration")) }
        if defaults.double(forKey: "bubbleSendDuration") > 0 { config.send = .easeInOut(defaults.double(forKey: "bubbleSendDuration")) }
        if defaults.integer(forKey: "bubbleStreamInterval") > 0 { config.streamInterval = .milliseconds(defaults.integer(forKey: "bubbleStreamInterval")) }
        if defaults.double(forKey: "bubbleAppearScale") > 0 { config.appearScale = defaults.double(forKey: "bubbleAppearScale") }
        config.growth = withinEnds(config.growth); config.send = withinEnds(config.send); config.incoming = withinEnds(config.incoming)
        return config
    }

    /// Bubble rows never resize on a spring that overshoots. A one-line
    /// bubble is exactly as tall as its corners are round, so sizes past
    /// either end would flatten its corners, and late content can't follow
    /// such a spring (it takes a short catch-up instead). A damped spring
    /// becomes the list's spring curve, which settles without overshoot.
    static func withinEnds(_ transition: ListTransition) -> ListTransition {
        guard case .dampedSpring = transition.curve else { return transition }
        return ListTransition(duration: transition.duration, curve: .spring, durationFactor: transition.durationFactor)
    }
}

struct ChatMessage: Sendable, Equatable {
    let id: String
    var text: String
    var outgoing: Bool
    var time: String
    /// An edit swaps in this text and back.
    var alternate: String?
}

/// Where a bubble sits in a run of messages from the same sender, oldest
/// first.
enum BubbleGroupPosition: Sendable, Equatable {
    case single, first, middle, last

    var startsGroup: Bool { self == .single || self == .first }
    var endsGroup: Bool { self == .single || self == .last }
}

/// The conversation, newest first, and the list rows that show it. A
/// message's revision changes whenever what its bubble shows changes,
/// including its corners when a neighbor arrives.
@MainActor
final class ChatThread {
    private struct Entry {
        var revision: UInt64
        var look: BubbleLook
        var row: NodeRow
    }

    private struct BubbleLook: Equatable {
        var message: ChatMessage
        var position: BubbleGroupPosition
    }

    private(set) var messages: [ChatMessage] = []
    private var entries: [String: Entry] = [:]
    private var appearances: [String: NodeRowAppearance] = [:]
    var config = BubbleAnimationConfig.current
    var pinnedID: String?
    var attachments: ((ChatMessage, Int) -> [String: any ListAttachment])?
    /// Called on the main thread when a bubble is tapped.
    var onTap: ((String) -> Void)?
    /// The swipe actions of a message's row.
    var swipeActions: ((String) -> (leading: [ListSwipeAction], trailing: [ListSwipeAction]))?

    init(seeded count: Int) {
        let samples = ChatThread.samples
        var outgoing = false
        var run = 0
        var minutes = 14 * 60 + 20
        for index in 0..<count {
            if run == 0 {
                outgoing.toggle()
                run = 1 + (index * 7 + 3) % 3
            }
            run -= 1
            let sample = samples[index % samples.count]
            let text = index == 0 ? "Tap Stream to watch a reply grow word by word, or tap any bubble to edit it." : sample
            messages.append(ChatMessage(
                id: "message-\(index)", text: text, outgoing: outgoing, time: Self.clock(minutes),
                alternate: Self.edits[index % Self.edits.count]
            ))
            minutes -= 1 + index % 4
        }
    }

    func index(of id: String) -> Int? { messages.firstIndex { $0.id == id } }

    func revision(of id: String) -> UInt64 { entries[id]?.revision ?? 0 }

    /// Adds `message` as the newest, shown the first time with `appearance`.
    func insert(_ message: ChatMessage, appearance: NodeRowAppearance?) {
        messages.insert(message, at: 0)
        if let appearance { appearances[message.id] = appearance }
    }

    func remove(_ id: String) {
        guard let index = index(of: id) else { return }
        messages.remove(at: index)
        appearances.removeValue(forKey: id)
    }

    func update(_ id: String, _ body: (inout ChatMessage) -> Void) {
        guard let index = index(of: id) else { return }
        body(&messages[index])
    }

    /// Swaps a message's text with its alternate, as an edit.
    func toggleEdit(_ id: String) {
        update(id) { message in
            guard let alternate = message.alternate else { return }
            message.alternate = message.text
            message.text = alternate
        }
    }

    var rows: [any ListRow] {
        var rows: [any ListRow] = []
        rows.reserveCapacity(messages.count)
        var live = Set<String>()
        for (index, message) in messages.enumerated() {
            let position = position(at: index)
            let look = BubbleLook(message: message, position: position)
            live.insert(message.id)
            var entry: Entry
            if let current = entries[message.id], current.look == look {
                entry = current
            } else {
                let revision = entries[message.id].map { $0.revision + 1 } ?? 0
                let appearance = revision == 0 ? appearances.removeValue(forKey: message.id) : nil
                entry = Entry(revision: revision, look: look, row: makeRow(message, position: position, revision: revision, appearance: appearance))
                entries[message.id] = entry
            }
            let swipes = swipeActions?(message.id) ?? (leading: [], trailing: [])
            rows.append(ChatBubbleRow(
                message: message, revision: entry.revision, node: entry.row,
                pinsToBottomEdge: message.id == pinnedID,
                attachments: attachments?(message, index) ?? [:],
                leadingSwipeActions: swipes.leading, trailingSwipeActions: swipes.trailing
            ))
        }
        for id in entries.keys where !live.contains(id) { entries.removeValue(forKey: id) }
        return rows
    }

    private func position(at index: Int) -> BubbleGroupPosition {
        let outgoing = messages[index].outgoing
        let older = index + 1 < messages.count && messages[index + 1].outgoing == outgoing
        let newer = index > 0 && messages[index - 1].outgoing == outgoing
        switch (older, newer) {
        case (false, false): return .single
        case (false, true): return .first
        case (true, true): return .middle
        case (true, false): return .last
        }
    }

    private func makeRow(_ message: ChatMessage, position: BubbleGroupPosition, revision: UInt64, appearance: NodeRowAppearance?) -> NodeRow {
        let tap: PressHandler = { [weak self] in self?.onTap?(message.id) }
        return NodeRow(identity: message.id, revision: revision, animatesContent: true, appearance: appearance) {
            ChatBubbleTree.make(message, position: position, onPress: tap)
        }
    }

    static func clock(_ minutes: Int) -> String {
        let value = (minutes % (24 * 60) + 24 * 60) % (24 * 60)
        return String(format: "%d:%02d", value / 60, value % 60)
    }

    static func now() -> String {
        let parts = Calendar.current.dateComponents([.hour, .minute], from: Date())
        return clock((parts.hour ?? 0) * 60 + (parts.minute ?? 0))
    }

    private static let samples = [
        "Morning!",
        "Did the build go green overnight?",
        "Yes, every engine passed. The streaming reply no longer jumps when it wraps.",
        "🎉",
        "Can you send the recording?",
        "Uploading it now. It's a bit long because it covers send, stream, edit and rewrap in all three engines.",
        "ok",
        "Nice. How does the time label know where to go?",
        "The text measures its last line off the main thread. If the time fits after it, it sits on that line; otherwise it gets a line of its own and the bubble grows.",
        "Makes sense",
        "Lunch?",
        "In ten minutes",
        "Let's try the new place on the corner, the one with the long queue every day at noon.",
        "👍",
        "What about dark mode?",
        "Colors resolve off the main thread too, so a trait change only redraws.",
    ]

    private static let edits = [
        "Edited: good morning, everyone!",
        "Edited: short",
        "Edited: this message grew a lot longer after an edit, so the bubble has to rewrap its lines and move the time down.",
    ]
}

/// The node tree of one bubble: a row with the bubble at its sender's side,
/// the text inside, and the time pinned to the bubble's bottom-right corner,
/// where the text leaves room for it.
enum ChatBubbleTree {
    static let maxWidth = 75.0
    static let horizontalPadding: CGFloat = 12
    static let verticalPadding: CGFloat = 7
    static let timeInset = CGSize(width: 12, height: 6)
    static let largeRadius: CGFloat = 18
    static let groupRadius: CGFloat = 6
    static let tailRadius: CGFloat = 4

    static let outgoingColor = Color.dynamic(light: Color(hex: 0x3478F6), dark: Color(hex: 0x2B62D9))
    static let incomingColor = Color(UIColor.secondarySystemGroupedBackground)
    static let incomingText = Color(UIColor.label)
    static let incomingTime = Color(UIColor.secondaryLabel)
    static let outgoingText = Color.white
    static let outgoingTime = Color(white: 1, alpha: 0.7)

    /// The space around the bubble inside its row.
    static func rowPadding(_ position: BubbleGroupPosition) -> (top: CGFloat, bottom: CGFloat) {
        (position.startsGroup ? 6 : 1, position.endsGroup ? 6 : 1)
    }

    static func make(_ message: ChatMessage, position: BubbleGroupPosition, onPress: PressHandler? = nil) -> UltraNode {
        let outgoing = message.outgoing
        var timeSpans = [TextSpan(message.time)]
        if outgoing { timeSpans.append(TextSpan(" ✓✓")) }
        let time = UltraTextNode(spans: timeSpans, style: styled {
            $0.position = .absolute
            $0.right = .points(timeInset.width)
            $0.bottom = .points(timeInset.height)
        }, textStyle: TextStyle(color: outgoing ? outgoingTime : incomingTime, fontSize: 11), numberOfLines: 1)
        time.transitionKey = "time"
        let text = UltraTextNode(message.text, textStyle: TextStyle(color: outgoing ? outgoingText : incomingText, fontSize: 17))
        text.transitionKey = "text"
        // Its bitmap sits at its top: a new line, drawn at once, shows only
        // as the text grows to it, rising from the bubble's bottom padding.
        text.style.overflow = .hidden
        text.trailingAccessory = time
        text.trailingAccessorySpacing = 8
        // The sender's side has the small corners inside a group and the
        // tail corner at its newest message.
        let top = position.startsGroup ? largeRadius : groupRadius
        let bottom = position.endsGroup ? tailRadius : groupRadius
        let bubble = UltraNode(style: styled {
            $0.maxWidth = .percent(maxWidth)
            $0.paddingHorizontal = .points(horizontalPadding)
            $0.paddingVertical = .points(verticalPadding)
            $0.backgroundColor = outgoing ? outgoingColor : incomingColor
            $0.borderTopLeftRadius = outgoing ? largeRadius : top
            $0.borderBottomLeftRadius = outgoing ? largeRadius : bottom
            $0.borderTopRightRadius = outgoing ? top : largeRadius
            $0.borderBottomRightRadius = outgoing ? bottom : largeRadius
        }, children: [text, time])
        bubble.transitionKey = "bubble"
        bubble.onPress = onPress
        bubble.pressedOpacity = 0.7
        bubble.accessibility = Accessibility(label: "\(outgoing ? "You" : "Assistant"): \(message.text), \(message.time)", isElement: true)
        let padding = rowPadding(position)
        return UltraNode(style: styled {
            $0.paddingHorizontal = 10
            $0.paddingTop = .points(padding.top)
            $0.paddingBottom = .points(padding.bottom)
            $0.alignItems = outgoing ? .flexEnd : .flexStart
        }, children: [bubble])
    }
}

/// One message as a list row: an animated node row, flipped upright in the
/// chat's inverted list.
@MainActor
struct ChatBubbleRow: ListRow {
    let message: ChatMessage
    let revision: UInt64
    let node: NodeRow
    var pinsToBottomEdge: Bool
    var attachments: [String: any ListAttachment]
    var leadingSwipeActions: [ListSwipeAction] = []
    var trailingSwipeActions: [ListSwipeAction] = []
    var identity: String { message.id }
    var measuresAsynchronously: Bool { true }

    func makeView() -> ListRowView { node.makeView() }
    func apply(to view: ListRowView, transition: ListTransition) {
        node.apply(to: view, transition: transition)
        view.transform = .init(scaleX: 1, y: -1)
        view.accessibilityIdentifier = "row-\(identity)"
        view.accessibilityLabel = message.outgoing ? "You" : "Assistant"
        // A row with swipe actions is one element, so VoiceOver offers its actions.
        let swipes = !leadingSwipeActions.isEmpty || !trailingSwipeActions.isEmpty
        view.isAccessibilityElement = swipes; view.accessibilityValue = swipes ? "\(message.text), \(message.time)" : nil
    }
    func measure(width: Double, environment: RenderEnvironment) async -> Double? { await node.measure(width: width, environment: environment) }
    func prepare(width: Double, environment: RenderEnvironment) async -> ListPreparation? { await node.prepare(width: width, environment: environment) }
    func prepareInPlace(width: Double, environment: RenderEnvironment) -> ListInPlacePreparation? { node.prepareInPlace(width: width, environment: environment) }
}

/// A streamed reply, word by word.
enum ChatStreamScript {
    static let tokenCount = 40
    static let opening = "Sure"

    /// Token `index` (1-based) of the reply, with its leading space.
    static func token(_ index: Int) -> String {
        let words = reply.split(separator: " ").map(String.init)
        // Spread the words over the tokens, one or two at a time.
        let start = (index - 1) * words.count / tokenCount
        let end = index * words.count / tokenCount
        return words[start..<max(end, start + 1)].map { " " + $0 }.joined()
    }

    private static let reply = "— here's what happens while this reply streams. Each word is laid out off the main thread, the bubble widens until its line is full, and the time slides along the last line. When the text wraps, the time drops onto a line of its own and the bubble grows taller, all on the list's own animation. Nothing on the main thread measures or draws; it only applies finished frames."
}
#endif
