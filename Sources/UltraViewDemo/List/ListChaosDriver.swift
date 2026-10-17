#if canImport(UIKit)
import UIKit
import UltraView

/// A list screen whose collection the chaos driver may replace.
@MainActor
protocol ListChaosRowHost: AnyObject, Sendable {
    var list: UltraListView { get }
    var chaosRows: [DemoListRow] { get set }
}

/// Opt-in randomized exercise of the Lists demo, for long soak runs:
///
///     -screen lists -listChaos <seed> [-listChaosMinutes 5] [-listChaosChecks YES]
///
/// Steps are 0-200 ms apart, with occasional same-turn bursts. Structural
/// checks run after every step; settled checks run after the screen rests,
/// at least every 20 s. With checks on, the first violation flushes the log
/// and traps with the seed and state. Advisory findings are only counted.
/// The Lists tab must be the launch screen, since the driver starts in its
/// `viewDidLoad`. Documents/list-chaos-<seed>.jsonl records every step;
/// list-chaos-<seed>-summary.json is rewritten every 10 s and at the end.
/// Add `-listHostProbe YES` to cover Chat headers and the pinned stream row.
/// Swipe actions (reveals, full swipes, VoiceOver actions, closing) are part
/// of the mix; `-listChaosSwipes NO` leaves them out and replays seeds as
/// they ran before swipes existed.
@MainActor
final class ListChaosDriver {
    private static var current: ListChaosDriver?

    static func startIfRequested(lists: ListsScreenController) {
        guard current == nil, let text = UserDefaults.standard.string(forKey: "listChaos"), let seed = UInt64(text) else { return }
        let defaults = UserDefaults.standard
        let minutes = defaults.object(forKey: "listChaosMinutes") == nil ? 5 : defaults.double(forKey: "listChaosMinutes")
        let driver = ListChaosDriver(seed: seed, minutes: max(0.05, minutes), checks: defaults.bool(forKey: "listChaosChecks"), lists: lists)
        current = driver
        Task { await driver.run() }
    }

    private enum Screen: String { case chat, feed, compare, other, empty }
    private enum Action: String, CaseIterable {
        case insert, delete, move, resize, reinsert, rebuild, replace, insets, demoButton
        case jump, fling, drag, halt
        case stream, send, keyboard, multiline
        case screen, engine, blocker, appearance, typeSize, rotation, appTab
        case burst, quiet
        // Appended, so that with swipes off the weighted draw matches earlier runs.
        case swipe, swipeAction, swipeClose
    }

    private let seed: UInt64, minutes: Double, checks: Bool
    private let swipes = UserDefaults.standard.object(forKey: "listChaosSwipes") == nil || UserDefaults.standard.bool(forKey: "listChaosSwipes")
    private weak var lists: ListsScreenController?
    private var random: ListChaosRandom
    private let log: ListChaosLogFile
    private let inspector = ListChaosInspector()
    private var started = CACurrentMediaTime(), lastSummary = 0.0, lastSettle = 0.0
    private var step = 0, serial = 0, detail = ""
    private var checkCount = 0, settledChecks = 0, pinChecks = 0, violationCount = 0, advisoryCount = 0
    private var violationKinds: [String: Int] = [:], actionCounts: [String: Int] = [:]
    private var activeGestures = 0, awayFromLists = false
    private var swipeGestures = 0, swipeHandlers = 0, swipeOutcomes: [String: Int] = [:], restingReveals = 0
    private var pinDisturbed = true
    private var rotationRequests = 0, rotationErrors = 0
    private var peakFootprint: UInt64 = 0, lastFootprint: UInt64 = 0, ledgerPeak: Int64 = 0, minimumAvailable = UInt64.max
    private var census = ListChaosCensus(), maxCensus: [String: Int] = [:]
    private var maxSettleSeconds = 0.0, maxReadySeconds = 0.0, settleTimeouts = 0

    private init(seed: UInt64, minutes: Double, checks: Bool, lists: ListsScreenController) {
        self.seed = seed; self.minutes = minutes; self.checks = checks; self.lists = lists
        random = ListChaosRandom(seed: seed)
        log = ListChaosLogFile(seed: seed)
    }

    // MARK: Run

    private func run() async {
        log.append(["type": "start", "seed": String(seed), "minutes": minutes, "checksEnabled": checks, "swipes": swipes,
                    "hostProbe": UserDefaults.standard.bool(forKey: "listHostProbe"),
                    "runID": UserDefaults.standard.string(forKey: "listProbeRunID") ?? "",
                    "system": UIDevice.current.systemVersion, "model": UIDevice.current.model], durable: true)
        print("LIST-CHAOS start seed=\(seed) minutes=\(minutes) checks=\(checks) log=\(log.logURL.path)")
        try? await Task.sleep(for: .seconds(1.5))
        started = CACurrentMediaTime()
        while elapsed < minutes * 60 {
            step += 1
            let action = choose()
            actionCounts[action.rawValue, default: 0] += 1
            log.append(["type": "act", "step": step, "action": action.rawValue], durable: true)
            detail = ""
            if action == .quiet { await settle(reason: "scheduled") } else { perform(action) }
            inspect(action.rawValue)
            // Continuous input would otherwise starve the settled checks.
            if elapsed - lastSettle >= 20 { await settle(reason: "periodic"); inspect("periodic") }
            let pause = random.int(0...200)
            if pause > 0 { try? await Task.sleep(for: .milliseconds(pause)) }
            if elapsed - lastSummary >= 10 { lastSummary = elapsed; writeSummary(completed: false) }
        }
        await finish()
    }

    private func finish() async {
        if let blocker = control("listMainBlocker") { select(blocker, 0) }
        lists?.view.window?.windowScene?.requestGeometryUpdate(.iOS(interfaceOrientations: .portrait))
        while awayFromLists { try? await Task.sleep(for: .milliseconds(100)) }
        while activeGestures > 0 { try? await Task.sleep(for: .milliseconds(50)) }
        await settle(reason: "final")
        inspect("final")
        let summary = summaryRecord(completed: true)
        log.append(summary, durable: true)
        log.writeSummary(summary, synchronous: true)
        if let data = ListChaosLogFile.encode(summary), let text = String(data: data, encoding: .utf8) {
            print("LIST-CHAOS-DONE \(text)", terminator: "")
        }
    }

    private var elapsed: Double { CACurrentMediaTime() - started }

    // MARK: Screen access

    private var child: UIViewController? { lists?.children.first }
    private var screen: Screen {
        switch child {
        case nil: .empty
        case is ListChatController: .chat
        case is LargeListController: .feed
        case is ListComparisonController: .compare
        default: .other
        }
    }
    private var rowHost: (any ListChaosRowHost)? { child as? any ListChaosRowHost }
    private var currentLists: [UltraListView] {
        if let rowHost { return [rowHost.list] }
        guard let view = child?.view else { return [] }
        return Self.views(in: view, of: UltraListView.self)
    }
    private static func views<T: UIView>(in root: UIView, of type: T.Type, where matches: (T) -> Bool = { _ in true }) -> [T] {
        var found: [T] = [], stack = [root]
        while let view = stack.popLast() {
            if let match = view as? T, matches(match) { found.append(match); continue }
            if view is UltraListView { continue }
            stack.append(contentsOf: view.subviews)
        }
        return found
    }
    private func control(_ identifier: String) -> UISegmentedControl? {
        lists.flatMap { Self.views(in: $0.view, of: UISegmentedControl.self) { $0.accessibilityIdentifier == identifier }.first }
    }
    private func button(_ title: String) -> UIButton? {
        child.flatMap { Self.views(in: $0.view, of: UIButton.self) { $0.currentTitle == title }.first }
    }
    private var composer: UITextView? {
        child.flatMap { Self.views(in: $0.view, of: UITextView.self) { $0.accessibilityIdentifier == "composer" }.first }
    }
    private func select(_ control: UISegmentedControl, _ index: Int) {
        guard control.selectedSegmentIndex != index, index < control.numberOfSegments else { return }
        control.selectedSegmentIndex = index
        control.sendActions(for: .valueChanged)
    }

    // MARK: Choice

    private func weight(_ action: Action, on screen: Screen) -> Double {
        if [.swipe, .swipeAction, .swipeClose].contains(action), !swipes { return 0 }
        let feed: [Action: Double] = [.insert: 8, .delete: 6, .move: 5, .resize: 7, .reinsert: 3, .rebuild: 1.5, .replace: 0.8, .insets: 2.5, .demoButton: 3,
                                      .jump: 6, .fling: 8, .drag: 6, .halt: 1.5, .swipe: 7, .swipeAction: 2, .swipeClose: 1]
        let chat: [Action: Double] = [.insert: 3, .delete: 3, .move: 1.5, .resize: 3, .reinsert: 1.5, .rebuild: 1, .replace: 0.5,
                                      .jump: 4, .fling: 6, .drag: 5, .halt: 1, .stream: 5, .send: 5, .keyboard: 4, .multiline: 4,
                                      .swipe: 5, .swipeAction: 1.5, .swipeClose: 0.7]
        let compare: [Action: Double] = [.jump: 4, .fling: 8, .drag: 8, .halt: 2]
        let global: [Action: Double] = [.screen: 1.5, .engine: 1.5, .blocker: 1.2, .appearance: 0.6, .typeSize: 0.6, .rotation: 0.5,
                                        .appTab: 0.4, .burst: 4, .quiet: 2.5]
        if let value = global[action] { return value }
        switch screen {
        case .feed: return feed[action] ?? 0
        case .chat: return chat[action] ?? 0
        case .compare: return compare[action] ?? 0
        case .other, .empty: return 0
        }
    }

    private func choose(excluding excluded: Set<Action> = []) -> Action {
        let screen = screen
        let weights = Action.allCases.map { excluded.contains($0) ? 0 : weight($0, on: screen) }
        var pick = random.double(0...weights.reduce(0, +))
        for (action, weight) in zip(Action.allCases, weights) where weight > 0 {
            if pick < weight { return action }
            pick -= weight
        }
        return .halt
    }

    private func transition(scroll: Bool = false) -> ListTransition {
        switch random.int(0...9) {
        case 0, 1: return .none
        case 2: return .default
        case 3: return .easeInOut(random.double(0.05...0.8))
        case 4: return .spring(0.5)
        case 5: return .spring(random.double(0.2...0.9), damping: random.double(8...40))
        case 6: return scroll ? .uiKitScroll() : .init(duration: random.double(0.05...0.6), curve: .linear)
        case 7: return .smoothDeceleration()
        case 8: return .keyboard(random.double(0.2...0.5))
        default: return .init(duration: random.double(0.1...0.5), curve: .bezier(0.2, 0.8, 0.2, 1))
        }
    }

    // MARK: Actions

    private func perform(_ action: Action) {
        switch action {
        case .insert, .delete, .move, .resize, .reinsert, .rebuild, .replace:
            if let host = rowHost { mutate(action, host) }
        case .insets: if let host = rowHost, screen == .feed { insets(host.list) }
        case .demoButton:
            let title = random.pick(["Insert", "Delete", "Move", "Resize", "5,000", "Top"])
            button(title)?.sendActions(for: .touchUpInside); detail = title
        case .jump: if let list = randomList() { jump(list) }
        case .fling:
            guard let list = randomList() else { return }
            let velocity = (random.bool() ? 1.0 : -1.0) * random.double(300...12_000)
            if list.holdsPinnedRow { pinDisturbed = true }
            list.beginMomentum(velocity: velocity); detail = String(Int(velocity))
        // One finger: a list drag never overlaps a row swipe, and the other way round.
        case .drag: if swipeGestures == 0, let list = randomList() { drag(list) }
        case .halt: randomList()?.haltScrolling()
        case .stream: button("Stream")?.sendActions(for: .touchUpInside); pinDisturbed = false
        case .send:
            if random.bool(0.6), let composer { composer.text = lines(); composer.delegate?.textViewDidChange?(composer) }
            button("Send")?.sendActions(for: .touchUpInside)
        case .keyboard:
            guard let composer else { return }
            if composer.isFirstResponder { composer.resignFirstResponder(); detail = "hide" } else { composer.becomeFirstResponder(); detail = "show" }
        case .multiline:
            guard let composer else { return }
            if random.bool(0.4) { composer.becomeFirstResponder() }
            composer.text = random.bool(0.2) ? "" : lines()
            composer.delegate?.textViewDidChange?(composer); detail = "\(composer.text.count) chars"
        case .screen:
            guard let tabs = control("listScreens") else { return }
            let next = random.pick([0, 1, 2].filter { $0 != tabs.selectedSegmentIndex })
            select(tabs, next); detail = String(next)
        case .engine:
            guard let engines = control("listEngines") else { return }
            let next = random.int(0...2); select(engines, next); detail = String(next)
        case .blocker:
            guard let blocker = control("listMainBlocker") else { return }
            let next = random.bool(0.5) ? 0 : random.int(1...3); select(blocker, next); detail = String(next)
        case .appearance:
            let style = random.pick([UIUserInterfaceStyle.unspecified, .light, .dark])
            lists?.overrideUserInterfaceStyle = style; detail = String(style.rawValue)
        case .typeSize: typeSize()
        case .rotation: rotate()
        case .appTab: leaveAndReturn()
        case .burst:
            let count = random.int(2...6)
            var names: [String] = []
            for _ in 0..<count {
                let inner = choose(excluding: [.burst, .quiet, .appTab])
                actionCounts[inner.rawValue, default: 0] += 1
                log.append(["type": "act", "step": step, "action": inner.rawValue, "burst": true], durable: true)
                perform(inner); names.append(inner.rawValue + (detail.isEmpty ? "" : "(\(detail))"))
            }
            detail = names.joined(separator: ",")
        case .quiet: break
        case .swipe: if let host = rowHost { swipe(host.list) }
        case .swipeAction: if let host = rowHost { accessibilityAction(host.list) }
        case .swipeClose:
            guard let list = rowHost?.list else { return }
            let animated = random.bool(0.8)
            detail = "\(list.swipeActions.revealedIdentity ?? "none")\(animated ? "" : " immediate")"
            list.swipeActions.close(animated: animated)
        }
    }

    private func randomList() -> UltraListView? {
        let lists = currentLists
        return lists.isEmpty ? nil : random.pick(lists)
    }

    private func lines() -> String {
        (0..<random.int(1...9)).map { "Chaos line \($0 + 1) for step \(step)" }.joined(separator: "\n")
    }

    private func makeRow(inverted: Bool, section: String?) -> DemoListRow {
        serial += 1
        var row = DemoListRow(identity: "chaos-\(seed)-\(serial)", title: "Chaos \(serial)", body: String(repeating: "Randomized row. ", count: random.int(1...8)),
                              height: Double(random.int(24...420)), tint: random.pick([.systemGreen, .systemOrange, .systemPink]), inverted: inverted, section: section)
        if swipes, random.bool(0.7) { addSwipeActions(to: &row) }
        return row
    }

    private static func freshCopy(_ row: DemoListRow) -> DemoListRow {
        var copy = DemoListRow(identity: row.identity, revision: row.revision, title: row.title, body: row.body, height: row.height, tint: row.tint,
                               inverted: row.inverted, pinsToBottomEdge: row.pinsToBottomEdge, section: row.section)
        copy.extraAttachments = row.extraAttachments
        copy.leadingSwipeActions = row.leadingSwipeActions; copy.trailingSwipeActions = row.trailingSwipeActions
        return copy
    }

    // MARK: Swipes

    /// Delete removes the row, Archive moves it while it closes, Grow resizes it
    /// in place. Everything random is drawn here, so handlers that run later
    /// from a gesture don't shift the seed's sequence.
    private func addSwipeActions(to row: inout DemoListRow) {
        let identity = row.identity
        let deleteTransition = transition(), moveTransition = transition(), growTransition = transition()
        let moveBy = random.int(2...10), grownHeight = Double(random.int(40...360))
        let widths = (0..<3).map { _ in random.bool(0.7) ? 76.0 : random.double(56...120) }
        row.trailingSwipeActions = [
            ListSwipeAction(title: "Delete", isDestructive: true, width: widths[0]) { [weak self] in
                self?.handleSwipe(identity, "delete") { rows, index in rows.remove(at: index); return deleteTransition }
            },
            ListSwipeAction(title: "Archive", color: .systemIndigo, width: widths[1]) { [weak self] in
                self?.handleSwipe(identity, "archive") { rows, index in
                    let row = rows.remove(at: index); rows.insert(row, at: min(rows.count, index + moveBy)); return moveTransition
                }
            },
        ]
        if random.bool(0.6) {
            row.leadingSwipeActions = [ListSwipeAction(title: "Grow", color: .systemOrange, width: widths[2]) { [weak self] in
                self?.handleSwipe(identity, "grow") { rows, index in rows[index].height = grownHeight; rows[index].revision += 1; return growTransition }
            }]
        }
    }
    private func handleSwipe(_ identity: String, _ name: String, _ change: (inout [DemoListRow], Int) -> ListTransition) {
        guard let host = rowHost else { return }
        var rows = host.chaosRows
        guard let index = rows.firstIndex(where: { $0.identity == identity }) else { return }
        let transition = change(&rows, index)
        host.chaosRows = rows
        host.list.applyChanges(items: rows, transition: transition)
        swipeHandlers += 1
        log.append(["type": "swipeHandler", "step": step, "action": name, "identity": identity])
    }

    /// A horizontal drag on a loaded row with actions, fed like a touch: short,
    /// to the open width, or past the full-swipe threshold, with any release.
    private func swipe(_ list: UltraListView) {
        guard activeGestures == 0 else { detail = "gesture active"; return }
        let candidates = list.loadedIndexRange.filter { !list.items[$0].leadingSwipeActions.isEmpty || !list.items[$0].trailingSwipeActions.isEmpty }
        guard !candidates.isEmpty else { detail = "no row"; return }
        let open = list.swipeActions.revealedIdentity
        let identity = open != nil && random.bool(0.4) ? open! : list.items[random.pick(candidates)].identity
        let width = Double(list.bounds.width), sign = random.bool() ? 1.0 : -1.0
        let distance: Double
        switch random.int(0...9) {
        case 0, 1, 2: distance = sign * random.double(8...60)
        case 3, 4, 5, 6: distance = sign * random.double(70...220)
        default: distance = sign * random.double((0.6 * width)...(1.1 * width))
        }
        let samples = random.int(3...10), cancels = random.bool(0.1)
        let release = random.bool(0.3) ? 0 : random.double(-3000...3000)
        swipeGestures += 1; activeGestures += 1
        detail = "\(identity) \(Int(distance)) v\(Int(release))\(cancels ? " cancel" : "")"
        Task { @MainActor [weak self, weak list] in
            defer { self?.swipeGestures -= 1; self?.activeGestures -= 1 }
            @MainActor func send(_ phase: GestureRecording.Event.Phase, _ dx: Double, _ velocity: Double = 0) {
                list?.swipeActions.receiveInput(.init(time: CACurrentMediaTime(), phase: phase, translation: .init(x: dx), velocity: .init(x: velocity)), row: identity)
            }
            send(.touchDown, 0)
            send(.began, distance / Double(samples))
            // Like a touch, a swipe on a moving list or a row without actions never begins.
            let began = list?.swipeActions.revealedIdentity == identity
            self?.swipeOutcomes[began ? "began" : "refused", default: 0] += 1
            let speed = distance / (Double(samples) * 0.016)
            for sample in 2...max(2, samples) {
                try? await Task.sleep(for: .milliseconds(16))
                send(.changed, distance * Double(sample) / Double(samples), speed)
            }
            send(cancels ? .cancelled : .ended, distance, release)
        }
    }

    /// Runs one of a loaded row's VoiceOver custom actions, as VoiceOver would.
    private func accessibilityAction(_ list: UltraListView) {
        let rows = list.loadedIndexRange.compactMap { index -> UIAccessibilityCustomAction? in
            guard let actions = list.loadedItemView(at: index)?.accessibilityCustomActions, !actions.isEmpty else { return nil }
            return random.pick(actions)
        }
        guard !rows.isEmpty else { detail = "no row"; return }
        let action = random.pick(rows)
        detail = action.name
        _ = action.actionHandler?(action)
    }

    /// Mostly near the loaded window, sometimes anywhere.
    private func index(in host: any ListChaosRowHost, count: Int) -> Int {
        guard count > 0 else { return 0 }
        let range = host.list.loadedIndexRange
        if random.bool(0.7), !range.isEmpty { return min(count - 1, max(0, random.int((range.lowerBound - 3)...(range.upperBound + 3)))) }
        return random.int(0...(count - 1))
    }

    private func mutate(_ action: Action, _ host: any ListChaosRowHost) {
        let inverted = screen == .chat
        var rows = host.chaosRows
        let transition = transition()
        let anchor: ListAnchorMode = random.bool(0.7) ? .automatic : .preserveVisibleContent
        let fades = random.bool(0.8)
        let wrapped = random.bool(0.15) ? random.double(0.1...0.6) : nil
        func apply(_ next: [DemoListRow], transition: ListTransition) {
            host.chaosRows = next
            let list = host.list
            // Hosts sometimes update inside a UIKit animation block.
            if let wrapped {
                UIView.animate(withDuration: wrapped) { list.applyChanges(items: next, anchorMode: anchor, animatesInsertions: fades, transition: transition) }
            } else { list.applyChanges(items: next, anchorMode: anchor, animatesInsertions: fades, transition: transition) }
        }
        switch action {
        case .insert:
            let at = min(index(in: host, count: rows.count), rows.count)
            let section = rows.indices.contains(at) ? rows[at].section : rows.last?.section
            let inserted = (0..<random.int(1...5)).map { _ in makeRow(inverted: inverted, section: section) }
            rows.insert(contentsOf: inserted, at: at)
            apply(rows, transition: transition)
            if inverted, random.bool(0.3) { host.list.animateInsertedBlock(identities: Set(inserted.map(\.identity)), from: .top, transition: self.transition()) }
            detail = "\(inserted.count)@\(at)"
        case .delete:
            guard rows.count > 3 else { return mutate(.insert, host) }
            let at = index(in: host, count: rows.count), count = min(random.int(1...5), rows.count - at)
            rows.removeSubrange(at..<(at + count))
            apply(rows, transition: transition); detail = "\(count)@\(at)"
        case .move:
            guard rows.count > 2 else { return }
            let from = index(in: host, count: rows.count), row = rows.remove(at: from)
            let to = min(rows.count, max(0, from + random.int(-12...12)))
            rows.insert(row, at: to)
            apply(rows, transition: transition); detail = "\(from)->\(to)"
        case .resize:
            guard !rows.isEmpty else { return }
            var changed: [Int] = []
            for _ in 0..<random.int(1...4) {
                let at = index(in: host, count: rows.count)
                rows[at].height = Double(random.int(24...480)); rows[at].revision += 1
                if random.bool(0.3) { rows[at].body += " Resized." }
                changed.append(at)
            }
            apply(rows, transition: transition); detail = changed.map(String.init).joined(separator: ",")
        case .reinsert:
            // The same row values return while their departure may still be animating.
            guard rows.count > 3 else { return }
            let at = index(in: host, count: rows.count), count = min(random.int(1...4), rows.count - at)
            let removed = Array(rows[at..<(at + count)])
            rows.removeSubrange(at..<(at + count))
            apply(rows, transition: transition.isImmediate ? .easeInOut(0.4) : transition)
            let back = self.transition(), delay = random.bool(0.5) ? 0 : random.int(1...250)
            let restore: @MainActor () -> Void = { [weak host] in
                guard let host else { return }
                var current = host.chaosRows
                let present = Set(current.map(\.identity))
                current.insert(contentsOf: removed.filter { !present.contains($0.identity) }, at: min(at, current.count))
                host.chaosRows = current
                host.list.applyChanges(items: current, transition: back)
            }
            if delay == 0 { restore() } else { Task { @MainActor in try? await Task.sleep(for: .milliseconds(delay)); restore() } }
            detail = "\(count)@\(at) after \(delay) ms"
        case .rebuild:
            // Fresh row values with unchanged identities and revisions.
            apply(rows.map(Self.freshCopy), transition: transition); detail = "\(rows.count)"
        case .replace:
            let count = inverted ? random.pick([0, 1, 8, 60]) : random.pick([0, 1, 5, 60, 600, 3000])
            let next = (0..<count).map { offset in makeRow(inverted: inverted, section: inverted ? nil : "CHAOS \(serial / 20 + offset / 20)") }
            apply(next, transition: transition); detail = "\(count)"
        default: break
        }
    }

    private func insets(_ list: UltraListView) {
        let side = random.bool(0.1) ? Double(random.int(0...40)) : 0
        let insets = ListInsets(top: Double(random.int(0...200)), left: side, bottom: Double(random.int(0...200)), right: side)
        let compensates = random.bool(0.7), transition = transition()
        if let duration = random.bool(0.2) ? random.double(0.1...0.5) : nil {
            UIView.animate(withDuration: duration) { list.applyChanges(newInsets: insets, compensatesInsetChange: compensates, transition: transition) }
        } else { list.applyChanges(newInsets: insets, compensatesInsetChange: compensates, transition: transition) }
        detail = "\(insets.top)/\(insets.bottom)/\(side)"
    }

    private func jump(_ list: UltraListView) {
        let count = list.items.count
        guard count > 0 else { return }
        let range = list.loadedIndexRange
        let index: Int
        switch random.int(0...9) {
        case 0, 1, 2: index = 0
        case 3: index = count - 1
        case 4, 5, 6: index = min(count - 1, max(0, random.int((range.lowerBound - 10)...(range.upperBound + 10))))
        default: index = random.int(0...(count - 1))
        }
        let offset = random.bool(0.35) ? random.double(-200...200) : 0
        pinDisturbed = true
        list.scrollTo(.init(index: index, pointOffset: offset), transition: transition(scroll: true))
        detail = "\(index)+\(Int(offset))"
    }

    private func drag(_ list: UltraListView) {
        let distance = random.double(-700...700), samples = random.int(4...14)
        let release = random.bool(0.3) ? 0 : random.double(-7000...7000), cancels = random.bool(0.1)
        activeGestures += 1; pinDisturbed = true
        detail = "\(Int(distance)) v\(Int(release))\(cancels ? " cancel" : "")"
        Task { @MainActor [weak self, weak list] in
            defer { self?.activeGestures -= 1 }
            let start = CACurrentMediaTime()
            list?.receiveScrollInput(.init(time: start, phase: .touchDown))
            list?.receiveScrollInput(.init(time: start, phase: .began))
            let speed = distance / (Double(samples) * 0.016)
            for sample in 1...samples {
                try? await Task.sleep(for: .milliseconds(16))
                list?.receiveScrollInput(.init(time: CACurrentMediaTime(), phase: .changed, translation: .init(x: 0, y: distance * Double(sample) / Double(samples)), velocity: .init(x: 0, y: speed)))
            }
            list?.receiveScrollInput(.init(time: CACurrentMediaTime(), phase: cancels ? .cancelled : .ended, translation: .init(x: 0, y: distance), velocity: .init(x: 0, y: release)))
        }
    }

    private func typeSize() {
        guard let lists else { return }
        if random.bool(0.25) {
            lists.traitOverrides.remove(UITraitPreferredContentSizeCategory.self); detail = "system"
        } else {
            let category = random.pick([UIContentSizeCategory.extraSmall, .large, .extraExtraExtraLarge, .accessibilityLarge])
            lists.traitOverrides.preferredContentSizeCategory = category; detail = category.rawValue
        }
    }

    private func rotate() {
        guard let scene = lists?.view.window?.windowScene else { return }
        let mask = random.pick([UIInterfaceOrientationMask.portrait, .landscapeRight, .landscapeLeft])
        rotationRequests += 1; detail = String(mask.rawValue)
        scene.requestGeometryUpdate(.iOS(interfaceOrientations: mask)) { @Sendable error in
            let message = error.localizedDescription
            Task { @MainActor in ListChaosDriver.current?.noteRotationError(message) }
        }
    }
    private func noteRotationError(_ message: String) {
        rotationErrors += 1
        if rotationErrors <= 5 { log.append(["type": "rotationError", "step": step, "message": message]) }
    }

    private func leaveAndReturn() {
        guard !awayFromLists, let lists, let tabs = lists.tabBarController, let controllers = tabs.viewControllers,
              controllers.count > 1, let home = controllers.firstIndex(of: lists) else { return }
        let other = random.pick(controllers.indices.filter { $0 != home }), delay = random.int(300...1500)
        awayFromLists = true; tabs.selectedIndex = other; detail = "\(other) for \(delay) ms"
        Task { @MainActor [weak self, weak tabs] in
            try? await Task.sleep(for: .milliseconds(delay))
            tabs?.selectedIndex = home
            self?.awayFromLists = false
        }
    }

    // MARK: Checks

    private func inspect(_ action: String) {
        let window = lists?.view.window
        var findings: [ListChaosFinding] = []
        if window != nil {
            for list in currentLists where list.window != nil { findings += inspector.structural(list); checkCount += 1 }
            census = inspector.census(window: window)
            for (key, value) in census.dictionary { maxCensus[key] = max(maxCensus[key] ?? 0, value) }
            if census.duplicateRoots > 0 { findings.append(.init(kind: "duplicateRootHost", detail: "\(census.duplicateRoots) roots hosted twice")) }
        }
        if let memory = ListChaosMemory.sample() {
            lastFootprint = memory.footprint; peakFootprint = max(peakFootprint, memory.footprint)
            ledgerPeak = max(ledgerPeak, memory.ledgerPeak)
            if memory.available > 0 { minimumAvailable = min(minimumAvailable, memory.available) }
        }
        var record = state()
        record["type"] = "step"; record["step"] = step; record["action"] = action; record["detail"] = detail
        record["checks"] = checkCount; record["violations"] = violationCount + findings.filter { !$0.isAdvisory }.count
        record["footprint"] = lastFootprint; record["hosts"] = census.dictionary
        log.append(record)
        for finding in findings { violation(finding) }
    }

    private func state() -> [String: Any] {
        var record: [String: Any] = ["t": Self.json(elapsed), "screen": screen.rawValue, "away": awayFromLists,
                                     "blocker": control("listMainBlocker")?.selectedSegmentIndex ?? -1,
                                     "revealed": currentLists.compactMap(\.swipeActions.revealedIdentity)]
        record["lists"] = currentLists.map { list -> [String: Any] in
            let insets = list.viewportInsets
            return ["engine": list.engineMode.rawValue, "items": list.items.count, "loaded": "\(list.loadedIndexRange)",
                    "offset": Self.json(list.currentScrollOffset), "flight": list.isScrollFlightActive, "dragging": list.isDragging,
                    "pinHeld": list.holdsPinnedRow, "passes": list.appliedPassCount, "inWindow": list.window != nil,
                    "bounds": "\(list.bounds.size)", "insets": "\(insets.top)/\(insets.left)/\(insets.bottom)/\(insets.right)"]
        }
        return record
    }

    /// Waits until every list on the screen rests with the newest collection,
    /// then runs the settled checks and waits for visible content.
    private func settle(reason: String) async {
        let begin = CACurrentMediaTime()
        defer { lastSettle = elapsed }
        var stable = 0, previous: [String]?, cause = "pending"
        while CACurrentMediaTime() - begin < 12 {
            try? await Task.sleep(for: .milliseconds(100))
            guard let signature = restingSignature(&cause) else { stable = 0; previous = nil; continue }
            stable = signature == previous ? stable + 1 : 0
            previous = signature
            // 1.3 s unchanged outlasts the longest list transition the driver requests.
            if stable >= 13 { break }
        }
        let settleSeconds = CACurrentMediaTime() - begin
        guard stable >= 13 else {
            settleTimeouts += 1
            log.append(["type": "settleTimeout", "step": step, "reason": reason, "cause": cause, "state": state()])
            switch cause {
            case "modelMismatch":
                let mismatch = rowHost.flatMap { ListChaosInspector.firstMismatch($0.chaosRows, $0.list.items) } ?? "unknown"
                violation(.init(kind: "noProgress", detail: "newest collection not shown after 12 s: \(mismatch)"))
            case "away", "listOffWindow", "noLists": break
            default: violation(.init(kind: "neverSettles", detail: "still \(cause) after 12 s without input"))
            }
            return
        }
        maxSettleSeconds = max(maxSettleSeconds, settleSeconds)
        let checksPin = screen == .chat && !pinDisturbed
        var findings: [ListChaosFinding] = []
        for list in currentLists {
            findings += inspector.settled(list, model: rowHost?.list === list ? rowHost?.chaosRows : nil, checksPin: checksPin)
            settledChecks += 1; checkCount += 1
            if list.swipeActions.revealedIdentity != nil { restingReveals += 1 }
            if checksPin && list.holdsPinnedRow { pinChecks += 1 }
        }
        let readyBegin = CACurrentMediaTime()
        var unready = currentLists.flatMap { inspector.unreadyVisibleRows($0) }
        while !unready.isEmpty, CACurrentMediaTime() - readyBegin < 5 {
            try? await Task.sleep(for: .milliseconds(100))
            unready = currentLists.flatMap { inspector.unreadyVisibleRows($0) }
        }
        maxReadySeconds = max(maxReadySeconds, CACurrentMediaTime() - readyBegin)
        if !unready.isEmpty { findings.append(.init(kind: "blankVisibleRow", detail: "not display-ready after 5 s: \(unready.prefix(8))")) }
        census = inspector.census(window: lists?.view.window)
        var record = state()
        record["type"] = "settled"; record["step"] = step; record["reason"] = reason; record["settleSeconds"] = settleSeconds
        record["hosts"] = census.dictionary; record["footprint"] = lastFootprint; record["findings"] = findings.count
        log.append(record)
        for finding in findings { violation(finding) }
    }

    private func restingSignature(_ cause: inout String) -> [String]? {
        guard let lists, lists.view.window != nil, !awayFromLists else { cause = "away"; return nil }
        guard activeGestures == 0 else { cause = "gesture"; return nil }
        let targets = currentLists
        guard !targets.isEmpty else { cause = "noLists"; return nil }
        var signature = [screen.rawValue]
        for list in targets {
            guard list.window != nil else { cause = "listOffWindow"; return nil }
            if list.isDragging || list.isTracking { cause = "dragging"; return nil }
            if list.isScrollFlightActive { cause = "flight"; return nil }
            if let scroll = list.contentView as? UIScrollView, scroll.isDecelerating || scroll.isTracking { cause = "nativeMotion"; return nil }
            let insets = list.viewportInsets
            signature.append("\((list.currentScrollOffset * 100).rounded())|\(list.appliedPassCount)|\(list.loadedIndexRange)|\(list.bounds.size)|\(insets.top)|\(insets.bottom)")
        }
        if let host = rowHost, ListChaosInspector.firstMismatch(host.chaosRows, host.list.items) != nil { cause = "modelMismatch"; return nil }
        cause = "resting"
        return signature
    }

    private func violation(_ finding: ListChaosFinding) {
        if finding.isAdvisory { advisoryCount += 1 } else { violationCount += 1 }
        let seen = (violationKinds[finding.kind] ?? 0) + 1
        violationKinds[finding.kind] = seen
        var record = state()
        record["type"] = finding.isAdvisory ? "advisory" : "violation"; record["step"] = step; record["kind"] = finding.kind; record["detail"] = finding.detail
        if seen <= 50 || (checks && !finding.isAdvisory) { log.append(record, durable: true) }
        if seen <= 5 { print("LIST-CHAOS-\(finding.isAdvisory ? "ADVISORY" : "VIOLATION") seed=\(seed) step=\(step) \(finding.kind): \(finding.detail)") }
        guard checks, !finding.isAdvisory else { return }
        var summary = summaryRecord(completed: false)
        summary["failure"] = record
        log.writeSummary(summary, synchronous: true)
        preconditionFailure("LIST-CHAOS violation seed=\(seed) step=\(step) \(finding.kind): \(finding.detail) state=\(state())")
    }

    /// JSON has no infinities or NaN; record them as text instead of dropping the line.
    private static func json(_ value: Double) -> Any { value.isFinite ? value : String(value) }

    private func summaryRecord(completed: Bool) -> [String: Any] {
        var record: [String: Any] = [
            "type": "summary", "seed": String(seed), "minutes": minutes, "checksEnabled": checks, "completed": completed,
            "elapsedSeconds": elapsed, "steps": step, "checks": checkCount, "settledChecks": settledChecks, "pinChecks": pinChecks,
            "settleTimeouts": settleTimeouts, "maxSettleSeconds": maxSettleSeconds, "maxReadySeconds": maxReadySeconds,
            "violations": violationCount, "advisories": advisoryCount, "violationKinds": violationKinds, "actions": actionCounts,
            "peakFootprintBytes": peakFootprint, "ledgerPeakFootprintBytes": ledgerPeak, "lastFootprintBytes": lastFootprint,
            "liveNodeHostCounts": census.dictionary, "maxNodeHostCounts": maxCensus,
            "rotationRequests": rotationRequests, "rotationErrors": rotationErrors, "swipes": swipes, "swipeHandlers": swipeHandlers, "swipeGestures": swipeOutcomes, "settledWithReveal": restingReveals,
            "runID": UserDefaults.standard.string(forKey: "listProbeRunID") ?? "", "log": log.logURL.lastPathComponent,
        ]
        if minimumAvailable != .max { record["minimumAvailableBytes"] = minimumAvailable }
        return record
    }

    private func writeSummary(completed: Bool) {
        let summary = summaryRecord(completed: completed)
        log.append(summary)
        log.writeSummary(summary, synchronous: false)
    }
}
#endif
