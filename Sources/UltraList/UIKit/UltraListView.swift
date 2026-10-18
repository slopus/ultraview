#if canImport(UIKit)
import UIKit
import QuartzCore
import UltraCore

/// A contiguous measured window, with final row geometry and independent render-server motion.
@MainActor
public final class UltraListView: UltraScrollView {
    public private(set) var items: [any ListRow] = []
    private var identities: [String] = []
    private var identityIndices: [String: Int] = [:]
    public private(set) var settledWindow = ListWindow()
    public var loadedIndexRange: Range<Int> { settledWindow.range }
    public var loadedItemViews: [ListRowView] { settledWindow.rows.compactMap { views[items[$0.index].identity] } }
    public var loadedAttachmentViews: [ListAttachmentView] { runs.compactMap { attachmentViews[$0.serial] } }
    public var preloadMargin: Double = 160
    public var loadedEdgeMargin: Double = 0 { didSet { reportVisibility() } }
    public var onVisibleWindowChanged: (() -> Void)?
    public var onLoadedEdgeReached: ((BoundaryEdge) -> Void)?
    public var onUserScrollDelta: ((Double, Double) -> Void)?
    public private(set) var reachedTop = false
    public private(set) var reachedBottom = false
    public private(set) var holdsPinnedRow = false
    public private(set) var appliedPassCount: UInt64 = 0
    public var viewportInsets: ListInsets { viewport.insets }
    /// Used by mutations and asynchronous row resizes unless a pass overrides it.
    public var defaultTransition: ListTransition = .easeInOut(0.3)
    public var animationDurationScale: Double {
        get { animations.durationScale }
        set { animations.durationScale = max(0.001, newValue) }
    }
    public var currentBottomEdgePinSlack: Double { settledWindow.pinSlack(index: pinnedIndex, viewport: viewport) }
    public var settledContentHeight: Double { settledWindow.height }
    public var overscrollDistance: Double { engine.offset - declaredEdges.clamped(engine.offset) }
    public var scrollGestureHostView: UIView { contentView }
    public var isStrictlyPinnedToBottomEdge: Bool {
        guard holdsPinnedRow, let index = pinnedIndex, let frame = presentedFrame(at: index) else { return false }
        let ext = max(0, frame.height - viewport.visibleHeight / 2)
        return abs(frame.maxY - (viewport.height - viewport.insets.bottom + ext)) <= 0.5
    }

    private let container = UIView()
    private let exits = PassthroughView()
    private let crossings = PassthroughView()
    private let attachmentsHost = PassthroughView()
    private let carousel = PassthroughView()
    private let animations = AnimationController()
    private var views: [String: ListRowView] = [:]
    private var carried: [String: (view: ListRowView, index: Int)] = [:]
    private var carryGenerations: [String: UInt64] = [:]
    private var nextCarryGeneration: UInt64 = 0
    private var viewport = ListViewport(width: 0, height: 0)
    private var settledValueGeometry: (width: Double, environment: UInt64)?
    private var measurementEnvironment = RenderEnvironment()
    private var measurementEnvironmentKey: UInt64 = 0
    private var origin: Double = 0
    private var declaredEdges = ScrollEdges(minimum: 0, maximum: 0)
    private var previousOffset: Double = 0
    private var passing = false
    private var scheduler = PassScheduler()
    private var deferred: [() -> Void] = []
    private let measurements = MeasurementCache()
    private var preparations: [MeasurementKey: ListPreparation] = [:]
    var retainedPreparationCount: Int { preparations.count }
    private var preparationKeys: Set<MeasurementKey> = []
    private var lastPreparationSweepAnchor: Int?
    private var preparationSweepScheduled = false
    private var measurementTasks: [MeasurementKey: Task<Void, Never>] = [:]
    private var measurementTickets: [MeasurementKey: UInt64] = [:]
    private var preparationDraws: [MeasurementKey: (ticket: UInt64, task: Task<Void, Never>)] = [:]
    private var nextPreparationDraw: UInt64 = 0
    private var speculativeKeys: Set<MeasurementKey> = []
    private var speculativeRequests: [(item: any ListRow, key: MeasurementKey, width: Double, showsSoon: Bool)] = []
    /// Preparations started without `ListPreparationHint.showsSoon` whose
    /// rows the list has since come to show soon: drawn before they're stored.
    private var soonKeys: Set<MeasurementKey> = []
    /// Prepared rows ahead of a scroll, drawn ahead on later turns: a scroll
    /// turn only queues them, so it makes no hosts.
    private var drawAheadQueue: [MeasurementKey] = []
    private var inputGeneration: UInt64 = 0
    private weak var latestScrollGate: ScrollIntentGate?
    private var pendingIntent: ScrollIntent?
    private var pendingTarget: ListScrollTarget? { eligibleIntent(pendingIntent)?.target }
    private var pendingScroll: (@MainActor () -> Void)?
    private var pendingDisplayViews: [MeasurementKey: ListRowView] = [:]
    private var pendingDisplayRequired: Set<MeasurementKey> = []
    private var pendingDisplayMeasurements: Set<MeasurementKey> = []
    private var pendingDisplayGeneration: UInt64 = 0
    private var pendingDisplayGate: ScrollIntentGate?
    private var pendingDisplayHeights: [MeasurementKey: (item: any ListRow, height: Double)] = [:]
    private var pendingItems: [any ListRow]?
    private var pendingIdentityIndices: [String: Int] = [:]
    private var unavailableMeasurements: Set<MeasurementKey> = []
    private var measurementFailures: [MeasurementKey: Int] = [:]
    private struct InsertedBlock {
        var identities: Set<String>
        var edge: BoundaryEdge
        var transition: ListTransition
    }
    /// Shared by every copy of one explicit target. A drag that began after
    /// the call, or a newer explicit target, cancels it for good, including
    /// once it has moved to a newer collection or waits for display readiness.
    @MainActor
    private final class ScrollIntentGate {
        let inputGeneration: UInt64
        private(set) var isCancelled = false
        init(inputGeneration: UInt64) { self.inputGeneration = inputGeneration }
        func cancel() { isCancelled = true }
        func accepts(_ current: UInt64) -> Bool {
            if current != inputGeneration { isCancelled = true }
            return !isCancelled
        }
    }
    private struct ScrollIntent {
        var target: ListScrollTarget
        var identity: String?
        var distance: Double
        var relativeDistance: Double = 0
        var gate: ScrollIntentGate
    }
    private struct TargetResolution {
        var generation: UInt64
        var gate: ScrollIntentGate
        var key: MeasurementKey
        var height: Double
        var viewport: ListViewport
        var offset: Double
    }
    private struct PreparationProjection {
        var required: [MeasurementKey]
        var missing: [(item: any ListRow, key: MeasurementKey, width: Double)]
        var retained: Set<MeasurementKey> = []
        var target: TargetResolution? = nil
    }
    private struct PreparedMutation {
        var items: [any ListRow]
        var size: CGSize?
        var insets: ListInsets?
        var viewportRequest: UInt64
        var intent: ScrollIntent?
        var additionalDistance: Double
        var anchorMode: ListAnchorMode
        var compensates: Bool
        var absorbsOverscroll: Bool
        var animatesInsertions: Bool
        var transition: ListTransition
        var blocks: [InsertedBlock] = []
    }
    private var preparationQueue = PreparationQueue<PreparedMutation, MeasurementKey>()
    private var viewportRequest: UInt64 = 0
    private var applyingPreparedMutation = false
    private var applyingPreparedTarget: (generation: UInt64, resolution: TargetResolution?)?
    private var activePreparationItems: [MeasurementKey: (generation: UInt64, item: any ListRow)] = [:]
    private var drainingPreparations = false
    private var deferredAttachmentRender = false
    private var pendingBlockAnimations: [InsertedBlock] = []
    private var serial: UInt64 = 0
    private var runs: [AttachmentRun] = []
    private var attachmentViews: [UInt64: ListAttachmentView] = [:]
    private var attachmentMaps: [UInt64: AttachmentMap] = [:]
    private var attachmentFlightSignatures: [UInt64: ScrollFlight] = [:]
    private struct AttachmentSnapshot {
        var screenY: Double
        var x: Double
        var width: Double
        var height: Double
    }
    private var ghostLedger = DepartureLedger()
    private var ghostWrappers: [UInt64: UIView] = [:]
    private var ghostMembers: [String: UInt64] = [:]
    private var ghostExitOwners: [UInt64: [AnimationOwner]] = [:]
    private var newGhostRanges: [UInt64: Range<Int>] = [:]
    private var passOldIdentities: [String] = []
    private var passDiff = ItemDiff(old: [String](), new: [])
    private struct MountContinuation {
        var oldIDs: [String]
        var oldIndices: [String: Int]
        var newIDs: [String]
        var newIndices: [String: Int]
        var oldBands: [String: ContinuationField.Band]
        var newBands: [String: ContinuationField.Band]
        var moved: Set<String>
        var participants: Set<String>
        var placements: [String: Double]
        var presentedHeights: [String: Double]
        var clock: AnimationTrack
        var origin: Double?
        var deadline: Double
        var witness: ListAnimationModel.Key?
        var witnessGeneration: UInt64?

        func band(_ identity: String, before: Bool) -> ContinuationField.Band? {
            guard var band = before ? oldBands[identity] ?? newBands[identity]
                : newBands[identity] ?? oldBands[identity] else { return nil }
            // Own motion excludes the live height followers. Compare both
            // orders with the height presented when this pass began.
            if let height = presentedHeights[identity] { band.height = height }
            return band
        }
    }
    private var mountContinuation: MountContinuation?
    private var mountSizeGeometry: SizePositionGeometry?
    private var pinnedIndex: Int?
    private var scrollToTopGeneration: UInt64 = 0
    /// The viewport correction that carries an explicit target's travel,
    /// which finishing it would land at once. It names the track's
    /// generation, so it lapses when that track ends or is replaced.
    private var targetCorrectionGeneration: UInt64?
    /// A row view built on an idle turn for the next row past the window, in
    /// the direction of the latest scroll. It isn't in `views`: it is hidden,
    /// so it is never shown, touched or read by accessibility, until a scroll
    /// places it or an idle turn releases it.
    struct PremountedRow {
        var identity: String
        var index: Int
        var direction: Int
        var key: MeasurementKey
        var height: Double
        var view: ListRowView
        /// `appliedPassCount` when it was built; a later pass can't use it.
        var pass: UInt64
    }
    private(set) var premounted: PremountedRow?
    /// Row views that left the window or weren't used, oldest first: hidden
    /// at once and taken out of the hierarchy on idle turns.
    private(set) var retired: [(identity: String, view: ListRowView)] = []
    private var unveiling: Set<ObjectIdentifier> = []
    private var scrollDirection = 0
    private var idleTurnScheduled = false
    let accessibilityCoordinator = ListAccessibility()
    public let swipeActions = ListSwipeController()

    public override init(engineMode: ScrollEngineMode = .keyframe) {
        super.init(engineMode: engineMode)
        accessibilityCoordinator.list = self
        swipeActions.attach(to: self)
        insertSubview(carousel, belowSubview: contentView)
        for view in [container, crossings, exits, attachmentsHost] { contentView.addSubview(view) }
        animations.referenceLayer = container.layer
        animations.bind(.viewport, layer: contentView.layer)
        animations.mirrorViewport(on: carousel.layer)
        engine.onFlightChanged = { [weak self] flight in
            guard let self else { return }
            // Engine calls can synchronously report a flight while the pass
            // still holds rows and attachment runs from the old collection.
            guard !passing else { deferredAttachmentRender = true; return }
            renderAttachments()
            if flight != nil { handleScroll(engine.offset) }
        }
        engine.didTouchDown = { [weak self] in self?.holdsPinnedRow = false; self?.scrollToTopGeneration &+= 1 }
        registerForTraitChanges([UITraitPreferredContentSizeCategory.self, UITraitUserInterfaceStyle.self, UITraitDisplayScale.self, UITraitLayoutDirection.self]) { (view: UltraListView, _: UITraitCollection) in view.setNeedsLayout() }
    }
    public override func layoutSubviews() {
        super.layoutSubviews()
        carousel.frame = bounds
        let size = bounds.size
        let traits = traitCollection
        let environment = RenderEnvironment(scale: traits.displayScale > 0 ? traits.displayScale : 3, fontScale: UIFontMetrics.default.scaledValue(for: 100, compatibleWith: traits) / 100, isDark: traits.userInterfaceStyle == .dark, isRightToLeft: effectiveUserInterfaceLayoutDirection == .rightToLeft)
        let changedEnvironment = environment != measurementEnvironment
        measurementEnvironment = environment; measurementEnvironmentKey = environmentKey(environment)
        if !changedEnvironment, abs(viewport.width - size.width) <= 0.5,
           abs(viewport.height - size.height) > 0.5, !settledWindow.rows.isEmpty {
            // A height-only viewport change needs no collection diff or
            // second row/viewport animation.
            engine.sync()
            let oldHeight = viewport.visibleHeight
            viewport.height = size.height
            if holdsPinnedRow, let pinnedIndex, let row = settledWindow.rows.first(where: { $0.index == pinnedIndex }) {
                let oldBoundary = oldHeight + max(0, row.height - oldHeight / 2)
                let newHeight = viewport.visibleHeight
                let newBoundary = newHeight + max(0, row.height - newHeight / 2)
                engine.shift(by: oldBoundary - newBoundary)
                previousOffset = engine.offset
            }
            declaredEdges = settledWindow.edges(origin: origin, count: items.count, viewport: viewport, pinnedIndex: pinnedIndex)
            engine.setEdges(declaredEdges)
            handleScroll(engine.offset)
        } else if changedEnvironment || abs(viewport.width - size.width) > 0.5 || abs(viewport.height - size.height) > 0.5 {
            applyChanges(newSize: size, transition: .immediate)
        }
    }
    public override func updateEdges() {}
    var horizontalAccessibilityScroll: ((UIAccessibilityScrollDirection) -> UIAccessibilityScrollDirection?)?
    public override func accessibilityScroll(_ direction: UIAccessibilityScrollDirection) -> Bool {
        guard let direction = horizontalAccessibilityScroll.map({ $0(direction) }) ?? direction else { return false }
        let advance: Double
        switch direction {
        case .down, .next: advance = 1
        case .up, .previous: advance = -1
        default: return false
        }
        let page = viewport.visibleHeight
        guard page > 0, !settledWindow.rows.isEmpty else { return false }
        let sign = contentView.transform.d < 0 ? -1.0 : 1.0
        let offset = declaredEdges.clamped(engine.offset + advance * sign * page)
        guard abs(offset - engine.offset) > 0.5 else { return false }
        engine.halt(); engine.setOffset(offset); handleScroll(offset)
        accessibilityCoordinator.notify(.pageScrolled, nil)
        return true
    }
    func index(forRowIdentity identity: String) -> Int? { identityIndices[identity] }
    /// The edge a departing row's block rides its witness by, once it has one.
    func departureEdge(forRowIdentity identity: String) -> BoundaryEdge? {
        guard let block = ghostMembers[identity].flatMap({ ghostLedger.blocks[$0] }), block.witness != .unresolved else { return nil }
        return block.edge
    }
    public override func handleDragBegin() {
        inputGeneration &+= 1
        holdsPinnedRow = false; scrollToTopGeneration &+= 1
        if let pending = pendingIntent, eligibleIntent(pending) == nil {
            let hadRetry = pendingScroll != nil
            let relativeRetry = pending.relativeDistance != 0 ? pendingScroll : nil
            pendingIntent = nil; pendingScroll = nil; clearPendingDisplayViews()
            if let relativeRetry { DispatchQueue.main.async { relativeRetry() } }
            else if hadRetry {
                DispatchQueue.main.async { [weak self] in self?.applyChanges(anchorMode: .preserveVisibleContent, transition: .immediate) }
            }
        }
        // A cancelled target no longer makes its remote measurements a barrier
        // to applying the collection around the user's current visible row.
        DispatchQueue.main.async { [weak self] in self?.drainPreparedMutations() }
        super.handleDragBegin()
    }
    public func loadedItemView(at index: Int) -> ListRowView? {
        guard items.indices.contains(index) else { return nil }; return views[items[index].identity]
    }
    public func settledFrame(at index: Int) -> CGRect? {
        guard let row = settledWindow.rows.first(where: { $0.index == index }) else { return nil }
        return CGRect(x: viewport.insets.left, y: origin - settledWindow.minY + row.y - engine.offset, width: viewport.contentWidth, height: row.height)
    }
    public func presentedFrame(at index: Int) -> CGRect? {
        guard var frame = settledFrame(at: index), items.indices.contains(index) else { return nil }
        let owner = AnimationOwner.row(items[index].identity), time = animations.now
        frame.origin.x += animations.value(owner, .positionX, at: time)
        frame.origin.y += animations.value(owner, .positionY, at: time) - animations.value(.viewport, .viewportOffset, at: time)
        let finalSize = frame.size
        frame.size.width = animations.value(owner, .width, at: time)
        frame.size.height = animations.value(owner, .height, at: time)
        if let view = views[items[index].identity] {
            let finalOffset = view.placementOffset(size: finalSize), liveOffset = view.placementOffset(size: frame.size)
            frame.origin.x += finalOffset.x - liveOffset.x; frame.origin.y += finalOffset.y - liveOffset.y
        }
        return frame
    }
    public func scrollTo(_ target: ListScrollTarget, transition: ListTransition = .uiKitScroll()) {
        applyChanges(scrollTo: target, transition: transition)
    }
    /// Runs immediately outside a list pass, or queues the whole update after it.
    /// Use this when an accessory must share the viewport animation's transaction.
    public func performAfterCurrentPass(_ update: @escaping @MainActor () -> Void) {
        if passing {
            deferred.append { [weak self] in self?.performAfterCurrentPass(update) }
        } else { update() }
    }
    /// Scrolls to the edge shown at the top: the first row, or the last one
    /// when the content is turned upside down (a chat's oldest loaded row).
    /// Momentum stops where it is shown and the list moves on from there.
    public override func scrollToTop(animated: Bool = true) {
        guard !items.isEmpty else { return }
        let inverted = contentView.transform.d < 0
        // The row's band meets the viewport's edge, so the list lands on its
        // edge without overscrolling past it. The target resolves when it
        // applies, which may wait for the row's measurement, so it reads the
        // edge row, the insets and the reserved space then.
        var target = ListScrollTarget(index: inverted ? items.count - 1 : 0) { [weak self] height, _ in
            guard let self, !items.isEmpty else { return 0 }
            let reserve = reservedHeights(at: inverted ? items.count - 1 : 0)
            return inverted ? viewport.visibleHeight - height - reserve.1 : reserve.0
        }
        target.edge = inverted ? .last : .first
        holdsPinnedRow = false
        scrollToTopGeneration &+= 1
        let transition: ListTransition = animated ? .uiKitScroll() : .immediate
        scrollTo(target, transition: transition)
        reportScrollToTop(scrollToTopGeneration, inverted: inverted, after: transition.duration * animations.durationScale, until: CACurrentMediaTime() + 10)
    }
    /// Calls `didScrollToTop` once the list rests on the edge shown at the
    /// top: the target applied, the viewport's transition ended and nothing
    /// moves. A touch, a drag or a newer scroll to the top cancels the call,
    /// and so does not getting there by `deadline`.
    private func reportScrollToTop(_ generation: UInt64, inverted: Bool, after delay: Double, until deadline: Double) {
        DispatchQueue.main.asyncAfter(deadline: .now() + max(0, delay)) { [weak self] in
            guard let self, scrollToTopGeneration == generation, CACurrentMediaTime() < deadline else { return }
            let edge = inverted ? declaredEdges.maximum.map { _ in declaredEdges.clamped(.greatestFiniteMagnitude) } : declaredEdges.minimum
            let resting = pendingTarget == nil && pendingScroll == nil && engine.activeFlight == nil && !engine.decelerating && !engine.dragging
                && abs(animations.value(.viewport, .viewportOffset, at: animations.now)) < 0.5
            guard resting, let edge, abs(engine.offset - edge) < 0.5 else {
                reportScrollToTop(generation, inverted: inverted, after: 1.0 / 60, until: deadline); return
            }
            didScrollToTop?()
        }
    }
    private var correctionCarriesTarget: Bool {
        targetCorrectionGeneration != nil && animations.model.tracks[.init(.viewport, .viewportOffset)]?.generation == targetCorrectionGeneration
    }
    /// Lands only the viewport correction at its model value, keeping any engine
    /// flight running. Does nothing when no viewport correction is animating,
    /// or when it still carries a scroll to a target (`scrollTo`,
    /// `scrollToTop`), whose travel would otherwise land at once.
    public func finishViewportTransition() {
        guard animations.model.tracks[.init(.viewport, .viewportOffset)] != nil, !correctionCarriesTarget else { return }
        animations.replace(.viewport, .viewportOffset, from: 0, to: 0, at: animations.now, transition: .none)
        renderAttachments(); reportVisibility()
    }

    /// All options are captured intact if a callback re-enters the pass.
    public func applyChanges(items newItems: [any ListRow]? = nil, newSize: CGSize? = nil, newInsets: ListInsets? = nil, scrollTo: ListScrollTarget? = nil, additionalScrollDistance: Double = 0, anchorMode: ListAnchorMode = .automatic, compensatesInsetChange: Bool = true, absorbsEdgeChangeIntoOverscroll: Bool = false, animatesInsertions: Bool = true, transition requestedTransition: ListTransition = .default) {
        // A newer explicit target supersedes a waiting one; a drag that
        // begins after this call cancels this one.
        let intent = scrollTo.map { target in
            if let previous = latestScrollGate {
                previous.cancel()
                DispatchQueue.main.async { [weak self] in self?.drainPreparedMutations() }
            }
            let gate = ScrollIntentGate(inputGeneration: inputGeneration)
            latestScrollGate = gate
            let identity = target.edge == nil ? target.identity ?? newItems.flatMap { collection in
                collection.indices.contains(target.index) ? collection[target.index].identity : nil
            } : nil
            return ScrollIntent(target: target, identity: identity,
                distance: additionalScrollDistance, gate: gate)
        }
        applyChanges(items: newItems, newSize: newSize, newInsets: newInsets, intent: intent,
            additionalScrollDistance: intent == nil ? additionalScrollDistance : 0, anchorMode: anchorMode,
            compensatesInsetChange: compensatesInsetChange, absorbsEdgeChangeIntoOverscroll: absorbsEdgeChangeIntoOverscroll,
            animatesInsertions: animatesInsertions, transition: requestedTransition)
    }

    private func applyChanges(items newItems: [any ListRow]? = nil, newSize: CGSize? = nil, newInsets: ListInsets? = nil, intent requestedIntent: ScrollIntent?, additionalScrollDistance distance: Double = 0, anchorMode requestedAnchorMode: ListAnchorMode = .automatic, compensatesInsetChange: Bool = true, absorbsEdgeChangeIntoOverscroll: Bool = false, animatesInsertions: Bool = true, transition requestedTransition: ListTransition = .default) {
        var intent = requestedIntent
        var scrollTo = intent?.target
        var additionalScrollDistance = distance
        var anchorMode = requestedAnchorMode
        let preparedMutation = applyingPreparedMutation
        let preparedTarget = applyingPreparedTarget
        applyingPreparedMutation = false
        applyingPreparedTarget = nil
        var resolvedTransition = requestedTransition.inheritsDefault ? (newItems == nil ? .immediate : defaultTransition) : requestedTransition
        let onlyInsets = newItems == nil && newSize == nil && newInsets != nil && scrollTo == nil && additionalScrollDistance == 0
            && newInsets?.left == viewport.insets.left && newInsets?.right == viewport.insets.right
            && !absorbsEdgeChangeIntoOverscroll && !settledWindow.rows.isEmpty
        if !onlyInsets { resolvedTransition.viewportCurve = nil }
        let transition = resolvedTransition
        if passing {
            deferred.append { [weak self] in self?.applyChanges(items: newItems, newSize: newSize, newInsets: newInsets, intent: requestedIntent, additionalScrollDistance: distance, anchorMode: requestedAnchorMode, compensatesInsetChange: compensatesInsetChange, absorbsEdgeChangeIntoOverscroll: absorbsEdgeChangeIntoOverscroll, animatesInsertions: animatesInsertions, transition: transition) }
            return
        }
        if !preparedMutation, newSize != nil || newInsets != nil { viewportRequest &+= 1 }
        if onlyInsets, let newInsets {
            updateViewportInsets(newInsets, compensates: compensatesInsetChange, transition: transition)
            return
        }
        if let newItems, !preparedMutation {
            if newItems.isEmpty {
                preparationQueue.removeAll(); pendingBlockAnimations.removeAll()
                pendingScroll = nil; pendingIntent = nil
            }
            let mutation = PreparedMutation(items: newItems, size: newSize, insets: newInsets, viewportRequest: viewportRequest,
                intent: intent,
                additionalDistance: additionalScrollDistance, anchorMode: anchorMode, compensates: compensatesInsetChange,
                absorbsOverscroll: absorbsEdgeChangeIntoOverscroll, animatesInsertions: animatesInsertions, transition: transition)
            preparationQueue.submit(mutation, waiting: [], merge: Self.mergePreparedMutations)
            promotePendingIdentityIntent()
            drainPreparedMutations()
            return
        }
        passing = true; appliedPassCount &+= 1
        // A pass builds its window itself; a spare row from before it can't be used.
        releaseSpareRows()
        resolveMountContinuation(at: animations.now)
        CATransaction.begin(); CATransaction.setDisableActions(true)
        animations.capturePositions()
        defer {
            CATransaction.commit()
            animations.clearPositions(); passing = false
            if deferredAttachmentRender {
                deferredAttachmentRender = false
                renderAttachments()
            }
            if engine.coveredOffsets(horizon: 0.3) != nil { handleScroll(engine.offset) }
            reportVisibility()
            if pendingItems == nil, !pendingBlockAnimations.isEmpty {
                let blocks = pendingBlockAnimations; pendingBlockAnimations.removeAll()
                for block in blocks { animateInsertedBlockNow(block) }
            }
            if !deferred.isEmpty {
                let queued = deferred; deferred.removeAll()
                DispatchQueue.main.async { for operation in queued { operation() } }
            }
        }
        let candidateIntent = intent ?? pendingIntent
        let intendedItems = newItems ?? pendingItems ?? items
        var relativeDistance = distance + (candidateIntent?.relativeDistance ?? 0)
        intent = eligibleIntent(candidateIntent)
        if let accepted = intent {
            intent = rebasedIntent(accepted, in: intendedItems)
            if intent == nil { accepted.gate.cancel() }
        }
        if intent == nil, let candidateIntent, let held = pendingIntent,
           held.gate !== candidateIntent.gate, let newer = eligibleIntent(held) {
            // A cancelled older mutation must not erase a newer waiting target.
            intent = rebasedIntent(newer, in: intendedItems)
            relativeDistance += newer.relativeDistance
            if intent == nil { newer.gate.cancel() }
        }
        if candidateIntent != nil, intent == nil {
            pendingIntent = nil; pendingScroll = nil; clearPendingDisplayViews()
            anchorMode = .preserveVisibleContent
        }
        scrollTo = intent?.target
        additionalScrollDistance = relativeDistance + (intent?.distance ?? 0)
        if scrollTo != nil || (additionalScrollDistance != 0 && anchorMode == .automatic) { engine.halt() }
        engine.sync()
        let time = animations.now, oldItems = items, oldWindow = settledWindow, oldOrigin = origin, oldViewport = viewport
        let oldIDs = identities, oldLookup = identityIndices, oldPinnedIndex = pinnedIndex
        let oldOffset = engine.offset, oldSettled = declaredEdges.clamped(oldOffset), oldOverscroll = oldOffset - oldSettled
        let oldBase = oldOrigin - oldWindow.minY
        let oldSlack = currentBottomEdgePinSlack
        let oldCorrection = animations.value(.viewport, .viewportOffset, at: time)
        let oldAttachmentState = attachmentSnapshot(offset: oldOffset, correction: oldCorrection)
        let oldViews = views
        let dirty = scheduler.consume()
        if let newSize { viewport.width = newSize.width; viewport.height = newSize.height }
        if let newInsets { viewport.insets = newInsets }
        let sizeChanged = oldViewport.width != viewport.width || oldViewport.height != viewport.height
        let insetChanged = oldViewport.insets != viewport.insets
        let displaces = sizeChanged || insetChanged || additionalScrollDistance != 0
        let changesCollection = newItems != nil || pendingItems != nil
        if let incoming = newItems ?? pendingItems {
            let nextIDs = incoming.map(\.identity)
            precondition(Set(nextIDs).count == incoming.count)
            items = incoming; identities = nextIDs
            identityIndices = Dictionary(uniqueKeysWithValues: nextIDs.enumerated().map { ($0.element, $0.offset) })
            pinnedIndex = incoming.firstIndex(where: \.pinsToBottomEdge); pendingItems = nil; pendingIdentityIndices.removeAll()
            let preparingIDs = preparationQueue.entries.flatMap { $0.value.items.map(\.identity) }
            measurements.retain(identities: Set(nextIDs).union(preparingIDs).union(preparations.keys.map(\.identity)))
            unavailableMeasurements = unavailableMeasurements.filter { key in identityIndices[key.identity].map { items[$0].revision == key.revision } == true }
            measurementFailures = measurementFailures.filter { unavailableMeasurements.contains($0.key) }
        }
        let newIDs = identities
        let diff = changesCollection ? ItemDiff(old: oldIDs, new: newIDs) : ItemDiff(old: [String](), new: [String]())
        let mutatesRows = !diff.inserts.isEmpty || !diff.deletes.isEmpty
        passOldIdentities = oldIDs; passDiff = diff
        let newLookup = identityIndices
        let fullReplace = changesCollection && !oldItems.isEmpty && !items.isEmpty && Set(oldIDs).isDisjoint(with: newIDs)
        if pinnedIndex == nil || fullReplace { holdsPinnedRow = false }
        if let scrollTo = scrollTo.map(atEdge), scrollTo.index == pinnedIndex { holdsPinnedRow = true }
        let target = scrollTo.map(atEdge)
        if let target { intent?.target = target }
        var reconciled = dirty
        for (identity, view) in oldViews {
            guard let newIndex = newLookup[identity], let oldIndex = oldLookup[identity] else { continue }
            if !items[newIndex].isEqual(to: oldItems[oldIndex]) {
                items[newIndex].apply(to: view, transition: transition); reconciled.insert(identity)
            }
        }
        guard !items.isEmpty, viewport.contentWidth > 0, viewport.height > 0 else {
            recordPendingIntent(items.isEmpty ? nil : intent, distance: distance)
            // A newer target replaces the retry too, or a flush would revive the old one.
            if items.isEmpty { pendingScroll = nil }
            else if let intent {
                pendingScroll = { [weak self] in
                    self?.applyChanges(intent: intent, additionalScrollDistance: distance, anchorMode: anchorMode, compensatesInsetChange: compensatesInsetChange, absorbsEdgeChangeIntoOverscroll: absorbsEdgeChangeIntoOverscroll, animatesInsertions: animatesInsertions, transition: transition)
                }
            }
            promotePendingIdentityIntent()
            clearPendingDisplayViews(force: true)
            engine.halt()
            for (identity, view) in views { view.visibleRectUpdated(nil); view.removeFromSuperview(); animations.unbind(.row(identity), removeModel: true) }
            views.removeAll(); settledWindow = .init(); origin = 0
            settledValueGeometry = nil
            mountContinuation = nil; mountSizeGeometry = nil
            for (id, view) in attachmentViews { view.removeFromSuperview(); animations.unbind(.attachment(id), removeModel: true) }
            attachmentViews.removeAll(); attachmentMaps.removeAll(); attachmentFlightSignatures.removeAll()
            for (id, carry) in carried { carry.view.removeFromSuperview(); animations.unbind(.row(id), removeModel: true) }
            carried.removeAll(); carryGenerations.removeAll()
            for id in ghostWrappers.keys { animations.unbind(.block(id), removeModel: true) }
            for owners in ghostExitOwners.values { for owner in owners { animations.unbind(owner, removeModel: true) } }
            for view in ghostWrappers.values { view.removeFromSuperview() }
            ghostWrappers.removeAll(); ghostExitOwners.removeAll(); ghostMembers.removeAll(); ghostLedger = .init(); newGhostRanges.removeAll()
            for view in carousel.subviews { animations.unbind(.carry(UInt64(max(0, view.tag))), removeModel: true); view.removeFromSuperview() }
            // A geometry pass can precede the first prepared collection.
            // Its queued rows still need their measurements to complete.
            if preparationQueue.isEmpty {
                preparations.removeAll(); measurements.invalidate(); preparationKeys.removeAll()
                speculativeRequests.removeAll(); speculativeKeys.removeAll(); soonKeys.removeAll(); drawAheadQueue.removeAll()
                for task in measurementTasks.values { task.cancel() }
                measurementTasks.removeAll(); measurementTickets.removeAll()
                for drawing in preparationDraws.values { drawing.task.cancel() }
                preparationDraws.removeAll()
                activePreparationItems.removeAll()
            }
            engine.setEdges(.init(minimum: 0, maximum: 0)); engine.setOffset(0)
            runs.removeAll(); renderAttachments(); return
        }
        let survivor = PreservedWindowAnchor.survivor(in: oldWindow, base: oldBase, settled: oldSettled,
            topInset: oldViewport.insets.top, automatic: anchorMode == .automatic) {
                oldItems.indices.contains($0) && newLookup[oldItems[$0].identity] != nil
            }
        let atTop = oldWindow.range.lowerBound == 0 && abs(oldSettled - (declaredEdges.minimum ?? .infinity)) < 1e-6
        let preserved = PreservedWindowAnchor(oldWindow: oldWindow, oldBase: oldBase, oldSettled: oldSettled,
            oldViewport: oldViewport, newViewport: viewport, oldSlack: oldSlack, pinnedIndex: pinnedIndex,
            holdsPinnedRow: holdsPinnedRow, survivor: survivor,
            survivorNewIndex: survivor.flatMap { newLookup[oldItems[$0.index].identity] }, atTop: atTop,
            automatic: anchorMode == .automatic, additionalDistance: additionalScrollDistance, compensates: compensatesInsetChange)
        let anchor = target.map { min(max(0, $0.index), items.count - 1) } ?? preserved.index
        requestAhead(anchor: anchor, direction: (engine.activeFlight?.settledOffset ?? engine.offset) >= engine.offset ? 1 : -1)
        var measuredViews: [String: ListRowView] = [:]
        func measure(_ index: Int) -> (height: Double, top: Double, bottom: Double)? {
            let item = items[index], identity = item.identity
            let key = MeasurementKey(identity: identity, revision: item.revision, width: viewport.contentWidth, environment: measurementEnvironmentKey &+ item.measurementEnvironment &* 0x9e3779b97f4a7c15)
            if item.measuresAsynchronously, measurements.height(for: key) == nil { requestMeasurement(index); return nil }
            let view = oldViews[identity] ?? carried[identity]?.view ?? measuredViews[identity] ?? pendingDisplayViews[key] ?? item.makeView()
            if oldViews[identity] == nil && measuredViews[identity] == nil { item.apply(to: view, transition: .immediate) }
            measuredViews[identity] = view
            let height = item.measuresAsynchronously ? measurements.height(for: key)! : view.update(width: viewport.contentWidth, transition: (reconciled.contains(identity) || sizeChanged) ? transition : .immediate)
            if item.measuresAsynchronously {
                if view.superview == nil { container.addSubview(view) }
                view.applyPreparation(preparations[key] ?? .init(height: height), width: viewport.contentWidth, environment: measurementEnvironment)
            }
            precondition(height.isFinite && height >= 0)
            let reserve = reservedHeights(at: index)
            return (height, reserve.0, reserve.1)
        }
        let newWindow: ListWindow
        if let target {
            newWindow = ListWindow.build(count: items.count, anchor: anchor, viewport: viewport, margin: preloadMargin,
                pinnedIndex: pinnedIndex, measure: measure) { height in
                    let resolved: Double
                    if let preparedTarget, let resolution = preparedTarget.resolution,
                       resolution.generation == preparedTarget.generation, resolution.gate === intent?.gate,
                       resolution.key == measurementKey(items[anchor], width: viewport.contentWidth),
                       resolution.height == height, resolution.viewport == viewport {
                        resolved = resolution.offset
                    } else {
                        resolved = target.resolve(height, target.identity == nil ? measuredViews[items[anchor].identity] : nil)
                    }
                    return viewport.insets.top + additionalScrollDistance + resolved
                }
        } else {
            newWindow = preserved.window(count: items.count, margin: preloadMargin, measure: measure)
        }
        guard !newWindow.rows.isEmpty else {
            recordPendingIntent(intent, distance: distance)
            if let intent {
                pendingScroll = { [weak self] in
                    self?.applyChanges(intent: intent, additionalScrollDistance: distance, anchorMode: anchorMode, compensatesInsetChange: compensatesInsetChange, absorbsEdgeChangeIntoOverscroll: absorbsEdgeChangeIntoOverscroll, animatesInsertions: animatesInsertions, transition: transition)
                }
            }
            if !oldWindow.rows.isEmpty {
                if changesCollection || displaces || target == nil {
                    pendingItems = items; pendingIdentityIndices = identityIndices
                }
                items = oldItems; identities = oldIDs; identityIndices = oldLookup; pinnedIndex = oldPinnedIndex
            }
            else { declaredEdges = .init(); engine.setEdges(declaredEdges) }
            promotePendingIdentityIntent()
            return
        }
        pendingIntent = nil; pendingScroll = nil
        let nextIDs = Set(newWindow.rows.map { items[$0.index].identity })
        let shared = oldWindow.rows.filter { nextIDs.contains(oldItems[$0.index].identity) }
        let isCarousel = target != nil && shared.isEmpty && !oldWindow.rows.isEmpty
        let destinationNew = nextIDs.isDisjoint(with: oldIDs)
        let placement = WindowPlacement(newWindow: newWindow, count: items.count, viewport: viewport, pinnedIndex: pinnedIndex,
            oldWindowIsEmpty: oldWindow.rows.isEmpty, platformCoordinates: engineMode == .uiKit, hasTarget: target != nil,
            oldOrigin: oldOrigin, oldOffset: oldOffset, oldSettled: oldSettled, oldOverscroll: oldOverscroll,
            displaces: displaces, moves: !diff.moves.isEmpty, absorbsOverscroll: absorbsEdgeChangeIntoOverscroll,
            containerOrigin: engine.containerOrigin(height: newWindow.height, top: newWindow.range.lowerBound == 0, bottom: newWindow.range.upperBound == items.count))
        let newOrigin = placement.origin, newBase = placement.base, newEdges = placement.edges, destination = placement.destination
        let shift = destination - oldOffset
        let reference = shared.first(where: { oldItems[$0.index].identity == survivor.map { oldItems[$0.index].identity } }) ?? shared.first
        let coordinateMap: Double
        if let reference, let newIndex = newLookup[oldItems[reference.index].identity], let next = newWindow.rows.first(where: { $0.index == newIndex }) {
            coordinateMap = newBase + next.y - oldBase - reference.y
        } else { coordinateMap = shift }
        let displacing = !isCarousel && (target != nil || displaces)
        let detachedShift = displacing ? coordinateMap : shift
        if target != nil, !changesCollection, !sizeChanged, !insetChanged {
            let required = placement.physicalRows, missing = placement.uncoveredIndices
            if !missing.isEmpty || required.contains(where: { measuredViews[items[$0.index].identity]?.isDisplayReady == false }) {
                recordPendingIntent(intent, distance: distance)
                pendingScroll = { [weak self] in
                    self?.applyChanges(intent: intent, additionalScrollDistance: distance, anchorMode: anchorMode, compensatesInsetChange: compensatesInsetChange, absorbsEdgeChangeIntoOverscroll: absorbsEdgeChangeIntoOverscroll, animatesInsertions: animatesInsertions, transition: transition)
                }
                var staged: [MeasurementKey: ListRowView] = [:]
                for row in newWindow.rows {
                    let item = items[row.index]
                    if let view = measuredViews[item.identity] { staged[measurementKey(item, width: viewport.contentWidth)] = view }
                }
                clearPendingDisplayViews(keeping: Set(staged.values.map(ObjectIdentifier.init)), force: true)
                pendingDisplayViews = staged
                pendingDisplayGate = intent?.gate
                pendingDisplayHeights = Dictionary(uniqueKeysWithValues: newWindow.rows.map { row in
                    let item = items[row.index]
                    return (measurementKey(item, width: viewport.contentWidth), (item, row.height))
                })
                pendingDisplayRequired = Set(required.map { measurementKey(items[$0.index], width: viewport.contentWidth) })
                pendingDisplayMeasurements = Set(missing.map { measurementKey(items[$0], width: viewport.contentWidth) })
                for index in missing { requestMeasurement(index) }
                let generation = pendingDisplayGeneration
                for key in pendingDisplayRequired {
                    guard let view = pendingDisplayViews[key] else { continue }
                    view.displayWaitObserver = { [weak self] in
                        guard let self, pendingDisplayGeneration == generation,
                              pendingDisplayMeasurements.allSatisfy({ measurements.height(for: $0) != nil }),
                              pendingDisplayRequired.allSatisfy({ pendingDisplayViews[$0]?.isDisplayReady == true }) else { return }
                        if let gate = pendingDisplayGate, preparationOwns(gate) { drainPreparedMutations() }
                        else { let resume = pendingScroll; pendingScroll = nil; resume?() }
                    }
                }
                promotePendingIdentityIntent()
                return
            }
        }
        clearPendingDisplayViews(keeping: Set(measuredViews.values.map(ObjectIdentifier.init)), force: target != nil)
        var oldSnapshot = Dictionary(uniqueKeysWithValues: oldWindow.rows.map { (oldItems[$0.index].identity, $0) })
        for (id, carry) in carried where oldSnapshot[id] == nil {
            guard let index = oldLookup[id] else { continue }
            oldSnapshot[id] = .init(index: index, y: carry.view.frame.minY - oldBase, height: carry.view.bounds.height)
        }
        let outgoing = oldWindow.rows.filter { !nextIDs.contains(oldItems[$0.index].identity) }
        if transition.isImmediate, target != nil || fullReplace {
            for view in carousel.subviews {
                if view.tag > 0 { animations.unbind(.carry(UInt64(view.tag)), removeModel: true) }
                view.removeFromSuperview()
            }
        }
        shiftDetached(by: detachedShift)
        if isCarousel && !transition.isImmediate {
            promoteCarousel(oldWindow: oldWindow, oldItems: oldItems, oldViews: oldViews, oldBase: oldBase, oldOffset: oldOffset, oldCorrection: oldCorrection, newWindow: newWindow, newOrigin: newOrigin, newOffset: destination, target: target!, witness: survivor.flatMap { newLookup[oldItems[$0.index].identity] }, time: time, transition: transition)
        } else {
            let departures = outgoing.filter { newLookup[oldItems[$0.index].identity] == nil }
            makeDepartures(departures, oldItems: oldItems, oldViews: oldViews, oldBase: oldBase, coordinateShift: detachedShift, time: time, transition: transition)
            for row in outgoing where newLookup[oldItems[row.index].identity] != nil {
                let id = oldItems[row.index].identity
                guard let view = oldViews[id] else { continue }
                if !transition.isImmediate && (target != nil || mutatesRows || displacing) {
                    view.onContentDidChange = nil; crossings.addSubview(view)
                    view.place(in: .init(x: oldViewport.insets.left, y: oldBase + row.y + detachedShift, width: oldViewport.contentWidth, height: row.height))
                    carried[id] = (view, newLookup[id]!)
                } else { animations.unbind(.row(id)); view.removeFromSuperview() }
            }
        }
        settledWindow = newWindow; origin = newOrigin
        settledValueGeometry = (viewport.contentWidth, measurementEnvironmentKey)
        views = measuredViews.filter { nextIDs.contains($0.key) }
        var mountedCarryPositions: [String: Double] = [:]
        CATransaction.begin(); CATransaction.setDisableActions(true)
        container.frame = .init(x: 0, y: origin, width: viewport.width, height: max(1, settledWindow.height))
        for row in settledWindow.rows {
            let id = items[row.index].identity
            guard let view = views[id] else { continue }
            if carried[id] != nil {
                mountedCarryPositions[id] = view.layer.position.y + animations.presentedDisplacement(.row(id), at: time)
            }
            carried.removeValue(forKey: id)
            carryGenerations.removeValue(forKey: id)
            if view.superview !== container { container.addSubview(view) }
            view.place(in: .init(x: viewport.insets.left, y: row.y - settledWindow.minY, width: viewport.contentWidth, height: row.height))
            view.layer.opacity = 1
            view.onContentDidChange = { [weak self] animated in self?.markDirty(id, animated: animated) }
            view.readinessObserver = { [weak self] in self?.accessibilityCoordinator.reconcile() }
            animations.bind(.row(id), layer: view.layer)
            if oldSnapshot[id] == nil { animations.seed(.row(id), width: viewport.contentWidth, height: row.height) }
        }
        for (id, view) in oldViews where !nextIDs.contains(id) { view.visibleRectUpdated(nil) }
        engine.setEdges(newEdges); declaredEdges = newEdges
        engine.shift(by: destination - engine.offset); previousOffset = engine.offset
        if absorbsEdgeChangeIntoOverscroll { engine.reanchorDrag() }
        if displacing {
            let carries = target != nil || correctionCarriesTarget && abs(oldCorrection) > 0.5
            let generation = animations.replace(.viewport, .viewportOffset, from: oldOffset + coordinateMap + oldCorrection - engine.offset, to: 0, at: time, transition: transition)
            targetCorrectionGeneration = carries ? generation : nil
        }
        transitionDetachedHorizontalGeometry(at: time, transition: transition)
        resolveAttachments(transition: transition, oldItems: oldItems, oldState: oldAttachmentState, suppressFade: isCarousel && destinationNew)
        updateGhosts(anchorY: newWindow.rows.first(where: { $0.index == anchor }).map { newBase + $0.y }, time: time, transition: transition)
        let samples = shared.compactMap { row -> CrossingPlanner.Sample? in
            let id = oldItems[row.index].identity
            guard let newIndex = newLookup[id], let next = newWindow.rows.first(where: { $0.index == newIndex }), !diff.moves.contains(where: { $0.old == row.index }) else { return nil }
            return .init(oldIndex: row.index, newIndex: newIndex, oldY: oldBase + row.y + detachedShift, newY: newBase + next.y)
        }
        var crossingEndpoints: [CrossingPlanner.Endpoint] = []
        for (id, carry) in carried {
            guard let oldIndex = oldIDs.firstIndex(of: id), let newIndex = newLookup[id] else { continue }
            crossingEndpoints.append(.init(identity: id, oldIndex: oldIndex, newIndex: newIndex, y: carry.view.frame.minY, height: carry.view.bounds.height, outgoing: true, moved: diff.moves.contains { $0.old == oldIndex }))
        }
        let crossingAnchor = settledWindow.rows.first(where: { $0.index == anchor }).map { newBase + $0.y } ?? engine.offset + viewport.insets.top
        let plans = CrossingPlanner.infer(crossingEndpoints, samples: samples, safeRange: (engine.offset - preloadMargin)...(engine.offset + viewport.height + preloadMargin), anchorY: crossingAnchor)
        let incomingEndpoints = settledWindow.rows.compactMap { row -> CrossingPlanner.Endpoint? in
            let id = items[row.index].identity
            guard !isCarousel, oldSnapshot[id] == nil, let oldIndex = oldLookup[id] else { return nil }
            return .init(identity: id, oldIndex: oldIndex, newIndex: row.index, y: newBase + row.y, height: row.height, outgoing: false, moved: diff.moves.contains { $0.new == row.index })
        }
        let incomingPlans = CrossingPlanner.infer(incomingEndpoints, samples: samples, safeRange: (engine.offset - preloadMargin)...(engine.offset + viewport.height + preloadMargin), anchorY: crossingAnchor)
        let preservesMoveClock = !mutatesRows && diff.moves.isEmpty && !displacing && !isCarousel
        let referenceID = reference.map { oldItems[$0.index].identity }
        let oldReferenceLayers = referenceID.map { animations.positionLayerValue(.row($0), at: time) } ?? 0
        func rowPositions(_ row: WindowRow, old: WindowRow, view: ListRowView?) -> (old: Double, new: Double) {
            let oldY = (target != nil || displaces) ? oldBase + old.y + coordinateMap : oldBase + old.y - oldOffset
            let newY = (target != nil || displaces) ? newBase + row.y : newBase + row.y - engine.offset
            let oldPlacement = view?.placementOffset(size: .init(width: oldViewport.contentWidth, height: old.height)) ?? .zero
            let newPlacement = view?.placementOffset(size: .init(width: viewport.contentWidth, height: row.height)) ?? .zero
            return (oldY + oldPlacement.y, newY + newPlacement.y)
        }
        // Establish every size clock before deriving the rows that follow it.
        for row in settledWindow.rows {
            let id = items[row.index].identity, owner = AnimationOwner.row(id)
            guard let old = oldSnapshot[id] else { continue }
            let oldPlacement = views[id]?.placementOffset(size: .init(width: oldViewport.contentWidth, height: old.height)) ?? .zero
            let newPlacement = views[id]?.placementOffset(size: .init(width: viewport.contentWidth, height: row.height)) ?? .zero
            animations.transition(owner, .positionX, old: oldViewport.insets.left + oldPlacement.x, new: viewport.insets.left + newPlacement.x, at: time, transition: transition)
            animations.transition(owner, .width, old: oldViewport.contentWidth, new: viewport.contentWidth, at: time, transition: transition)
            animations.transition(owner, .height, old: old.height, new: row.height, at: time, transition: transition)
        }
        let heightMotions = animations.heightMotions(at: time)
        let sizeGeometry = SizePositionGeometry(anchor: anchor,
            anchorsTop: newWindow.range.lowerBound == 0 && newWindow.range.upperBound == items.count
                && newWindow.height <= viewport.visibleHeight && pinnedIndex == nil,
            pinsAnchorBottom: holdsPinnedRow && target == nil && anchor == pinnedIndex,
            visibleHeight: viewport.visibleHeight)
        mountSizeGeometry = sizeGeometry
        func positionLayers(index: Int, view: ListRowView) -> [AnimationController.PositionLayer] {
            let own = view.placementOffset(size: .init(width: viewport.contentWidth, height: 1)).y
                - view.placementOffset(size: .init(width: viewport.contentWidth, height: 0)).y
            return heightMotions.compactMap { motion in
                guard let sourceIndex = newLookup[motion.identity] else { return nil }
                let coefficient = sizeGeometry.coefficient(source: sourceIndex, row: index,
                    from: motion.track.from, to: motion.track.to, ownPlacement: own)
                guard abs(coefficient) > 1e-6 else { return nil }
                return .init(source: .height(motion.identity), track: motion.track.residual(multipliedBy: coefficient), origin: motion.origin)
            }
        }
        var followers: [String: [AnimationController.PositionLayer]] = [:]
        for row in settledWindow.rows {
            let id = items[row.index].identity
            if let view = views[id] { followers[id] = positionLayers(index: row.index, view: view) }
        }
        for (id, carry) in carried {
            if let index = newLookup[id] { followers[id] = positionLayers(index: index, view: carry.view) }
        }
        var layout = animations.layoutPosition(at: time)
        if preservesMoveClock, !transition.isImmediate, let id = referenceID,
           let old = oldSnapshot[id], let row = settledWindow.rows.first(where: { items[$0.index].identity == id }) {
            let positions = rowPositions(row, old: old, view: views[id])
            let heightOffset = followers[id, default: []].reduce(0) { $0 + animations.positionLayerValue($1, at: time) }
            layout = animations.layoutPosition(from: positions.old - positions.new + oldReferenceLayers - heightOffset,
                                               at: time, transition: transition)
        }
        for (id, layers) in followers {
            let continuation = preservesMoveClock || (transition.isImmediate && !isCarousel && !fullReplace)
                ? animations.positionLayer(.row(id), source: .continuation) : nil
            animations.setPositionLayers(.row(id), layers + (layout.map { [$0] } ?? []) + (continuation.map { [$0] } ?? []))
        }
        for (id, next) in plans {
            guard let carry = carried[id] else { continue }
            let oldY = carry.view.frame.minY
            // Translate without asking UIKit to infer bounds from a transformed frame.
            carry.view.layer.position.y += next - oldY
            if preservesMoveClock { continue }
            animations.transition(.row(id), .positionY, old: oldY, new: next, at: time, transition: transition,
                                  restarts: displacing || animations.positionLayersChanged(.row(id)))
            retainCarry(id, view: carry.view, transition: transition)
        }
        for row in settledWindow.rows {
            let id = items[row.index].identity, owner = AnimationOwner.row(id)
            if let old = oldSnapshot[id] {
                if !preservesMoveClock {
                    let positions = rowPositions(row, old: old, view: views[id])
                    animations.transition(owner, .positionY, old: positions.old, new: positions.new, at: time, transition: transition,
                                          restarts: animations.positionLayersChanged(owner))
                }
            } else if oldLookup[id] == nil, animatesInsertions, !(isCarousel && destinationNew) {
                animations.replace(owner, .opacity, from: 0, to: 1, at: time, transition: transition)
            } else if !isCarousel, oldLookup[id] != nil, !transition.isImmediate, mutatesRows {
                let newY = newBase + row.y
                let inferred = incomingPlans[id] ?? (row.index < anchor ? engine.offset - preloadMargin - row.height : engine.offset + viewport.height + preloadMargin)
                animations.replace(owner, .positionY, from: inferred - newY - animations.positionLayerValue(owner, at: time), to: 0, at: time, transition: transition)
            }
        }
        let startsMountContinuation = !transition.isImmediate && (mutatesRows || !diff.moves.isEmpty) && !isCarousel && !fullReplace
        if isCarousel || fullReplace {
            mountContinuation = nil
        } else if startsMountContinuation {
            func band(_ row: WindowRow) -> ContinuationField.Band {
                .init(height: row.height, top: row.reservedTop, bottom: row.reservedBottom)
            }
            let participants = Set(views.keys).union(carried.keys)
            let deadline = max(time + transition.duration * animations.durationScale,
                animations.retentionDeadline(owners: Set(participants.map(AnimationOwner.row))))
            let oldBands = Dictionary(uniqueKeysWithValues: oldWindow.rows.map { (oldItems[$0.index].identity, band($0)) })
            let newBands = Dictionary(uniqueKeysWithValues: settledWindow.rows.map { (items[$0.index].identity, band($0)) })
            mountContinuation = .init(oldIDs: oldIDs, oldIndices: oldLookup,
                newIDs: newIDs, newIndices: newLookup, oldBands: oldBands, newBands: newBands,
                moved: Set(diff.moves.map { items[$0.new].identity }),
                participants: participants,
                placements: views.merging(carried.mapValues(\.view), uniquingKeysWith: { view, _ in view }).mapValues { view in
                    view.placementOffset(size: .init(width: viewport.contentWidth, height: 1)).y
                        - view.placementOffset(size: .init(width: viewport.contentWidth, height: 0)).y
                }, presentedHeights: Dictionary(uniqueKeysWithValues: heightMotions.map { motion in
                    let residual = animations.positionLayerValue(.init(source: .height(motion.identity),
                        track: motion.track.residual(multipliedBy: 1), origin: motion.origin), at: time)
                    return (motion.identity, motion.track.to + residual)
                }),
                clock: .init(generation: 0, from: 0, to: 0, startTime: time, transition: transition.scaled(by: animations.durationScale)),
                origin: nil,
                deadline: deadline,
                witness: nil, witnessGeneration: nil)
        }
        if preservesMoveClock {
            mountMotion(previous: oldWindow, carriedPositions: mountedCarryPositions, at: time)
        } else if mountContinuation != nil, !isCarousel, !fullReplace {
            let previous = ListWindow(rows: settledWindow.rows.filter { oldSnapshot[items[$0.index].identity] != nil })
            let moved = Set(diff.moves.map(\.new))
            let incoming = settledWindow.rows.filter { row in
                let id = items[row.index].identity
                return oldSnapshot[id] == nil && oldLookup[id] != nil && !moved.contains(row.index)
            }
            if !incoming.isEmpty {
                mountMotion(previous: previous, carriedPositions: [:], at: time, mounting: incoming)
            }
        }
        if startsMountContinuation, var record = mountContinuation {
            func isInstalledRowClock(_ entry: (key: ListAnimationModel.Key, value: AnimationTrack)) -> Bool {
                guard entry.value.startTime == time, case .row(let id) = entry.key.owner,
                      let view = views[id], let animation = view.layer.animation(forKey: entry.key.animationKey) else { return false }
                return (animation.value(forKey: "ultraviewGeneration") as? NSNumber)?.uint64Value == entry.value.generation
            }
            // Incoming rows can replace their own tracks with a continuation.
            // Choose the witness after those installations have finished.
            let witness = animations.model.tracks.first { $0.key.positionSource == .continuation && isInstalledRowClock($0) }
                ?? animations.model.tracks.first { $0.key.property == .positionY && $0.key.positionSource == nil && isInstalledRowClock($0) }
                ?? animations.model.tracks.first { $0.value.startTime == time }
            record.witness = witness?.key; record.witnessGeneration = witness?.value.generation
            if witness == nil { record.origin = time }
            mountContinuation = record
        }
        CATransaction.commit()
        sweepPreparations(force: newItems != nil || sizeChanged)
        renderAttachments()
        clearPendingDisplayViews(keeping: Set(views.values.map(ObjectIdentifier.init)))
    }

    private func retainCarry(_ identity: String, view: ListRowView, transition: ListTransition) {
        nextCarryGeneration &+= 1
        let generation = nextCarryGeneration
        carryGenerations[identity] = generation
        if transition.isImmediate {
            finishCarry(identity, view: view, generation: generation, deadline: animations.now)
            return
        }
        // Read the running clocks after the transaction receives its begin
        // time. Carry lifetime does not require replacing a position track.
        DispatchQueue.main.async { [weak self, weak view] in
            guard let self, let view, carryGenerations[identity] == generation else { return }
            let deadline = max(animations.now + transition.duration * animations.durationScale,
                               animations.retentionDeadline(.row(identity)))
            finishCarry(identity, view: view, generation: generation, deadline: deadline)
        }
    }

    private func finishCarry(_ identity: String, view: ListRowView, generation: UInt64, deadline: Double) {
        guard carryGenerations[identity] == generation else { return }
        guard carried[identity]?.view === view, views[identity] == nil else {
            carryGenerations.removeValue(forKey: identity); return
        }
        let remaining = deadline - animations.now
        if remaining > 1e-6 {
            DispatchQueue.main.asyncAfter(deadline: .now() + remaining) { [weak self, weak view] in
                guard let self, let view else { return }
                finishCarry(identity, view: view, generation: generation, deadline: deadline)
            }
        } else {
            carryGenerations.removeValue(forKey: identity); carried.removeValue(forKey: identity)
            view.removeFromSuperview(); animations.unbind(.row(identity))
        }
    }

    /// An edge target at the edge row of the items this pass shows.
    private func atEdge(_ target: ListScrollTarget) -> ListScrollTarget {
        guard let edge = target.edge, !items.isEmpty else { return target }
        var target = target
        target.index = edge == .last ? items.count - 1 : 0
        return target
    }
    private func eligibleIntent(_ intent: ScrollIntent?) -> ScrollIntent? {
        guard let intent, intent.gate.accepts(inputGeneration) else { return nil }
        return intent
    }

    /// Implicit passes read the combined distance; the explicit retry carries
    /// the original intent and its separate relative distance exactly once.
    private func recordPendingIntent(_ intent: ScrollIntent?, distance: Double) {
        var stored = intent
        stored?.relativeDistance += distance
        pendingIntent = stored
    }

    private func preparationOwns(_ gate: ScrollIntentGate) -> Bool {
        preparationQueue.entries.contains { entry in
            guard let intent = eligibleIntent(entry.value.intent) else { return false }
            return intent.gate === gate && intent.target.identity != nil
        }
    }

    /// Transfer a waiting opt-in target, rather than letting its old retry
    /// race the collection that is preparing its updated row.
    private func promotePendingIdentityIntent() {
        guard pendingItems == nil, !preparationQueue.isEmpty,
              let intent = eligibleIntent(pendingIntent), intent.target.identity != nil,
              intent.relativeDistance == 0 else { return }
        var promoted = false
        preparationQueue.updateNewest { mutation in
            if let existing = eligibleIntent(mutation.intent), existing.gate !== intent.gate { return }
            mutation.intent = intent
            promoted = true
        }
        if promoted { pendingIntent = nil; pendingScroll = nil }
    }

    private func clearPendingDisplayViews(keeping retained: Set<ObjectIdentifier> = [], force: Bool = false) {
        if !force, let gate = pendingDisplayGate, preparationOwns(gate) { return }
        pendingDisplayGeneration &+= 1
        for (key, view) in pendingDisplayViews {
            view.displayWaitObserver = nil
            if !retained.contains(ObjectIdentifier(view)), views[key.identity] !== view, carried[key.identity]?.view !== view { view.removeFromSuperview() }
        }
        pendingDisplayViews.removeAll(); pendingDisplayRequired.removeAll(); pendingDisplayMeasurements.removeAll()
        pendingDisplayHeights.removeAll(); pendingDisplayGate = nil
    }

    private func updateViewportInsets(_ insets: ListInsets, compensates: Bool, transition: ListTransition) {
        guard insets != viewport.insets else { return }
        let started = CACurrentMediaTime()
        defer { MainThreadMonitor.shared.note("list inset compensates=\(compensates) \((CACurrentMediaTime() - started) * 1000) ms") }
        passing = true
        var keepsTravel = false
        defer {
            passing = false
            if !transition.isImmediate || keepsTravel { handleScroll(engine.offset) }
            else { renderAttachments(); reportVisibility() }
            if !deferred.isEmpty {
                let queued = deferred; deferred.removeAll()
                DispatchQueue.main.async { for operation in queued { operation() } }
            }
        }
        CATransaction.begin(); CATransaction.setDisableActions(true)
        engine.sync()
        let time = animations.now, oldOffset = engine.offset, oldViewport = viewport
        let oldSettled = declaredEdges.clamped(oldOffset), oldOverscroll = oldOffset - oldSettled
        let oldSlack = settledWindow.pinSlack(index: pinnedIndex, viewport: oldViewport)
        let correction = animations.value(.viewport, .viewportOffset, at: time)
        viewport.insets = insets
        let newSlack = settledWindow.pinSlack(index: pinnedIndex, viewport: viewport)
        declaredEdges = settledWindow.edges(origin: origin, count: items.count, viewport: viewport, pinnedIndex: pinnedIndex)
        var shift = 0.0
        if holdsPinnedRow, let pinnedIndex, let row = settledWindow.rows.first(where: { $0.index == pinnedIndex }) {
            let oldBoundary = oldViewport.height - oldViewport.insets.bottom + max(0, row.height - oldViewport.visibleHeight / 2)
            let newBoundary = viewport.height - insets.bottom + max(0, row.height - viewport.visibleHeight / 2)
            shift = oldBoundary - newBoundary
        } else if compensates {
            let screenMove = insets.top - oldViewport.insets.top + newSlack - oldSlack
            shift = declaredEdges.clamped(oldSettled - screenMove) + oldOverscroll - oldOffset
        }
        engine.shift(by: shift); previousOffset = engine.offset
        engine.setEdges(declaredEdges)
        // A target's remaining travel rides on the new correction. An
        // immediate change moves the content by its own shift at once and
        // leaves that travel running on its own clock.
        let carries = correctionCarriesTarget && abs(correction) > 0.5
        keepsTravel = carries && transition.isImmediate
        if !keepsTravel {
            let generation = animations.replace(.viewport, .viewportOffset, from: transition.isImmediate ? 0 : oldOffset + correction - engine.offset, to: 0, at: time, transition: transition)
            targetCorrectionGeneration = carries ? generation : nil
        }
        CATransaction.commit()
    }

    public override func handleScroll(_ offset: Double) {
        guard !passing, !settledWindow.rows.isEmpty else { return }
        let started = CACurrentMediaTime(), oldRange = settledWindow.range
        passing = true
        CATransaction.begin(); CATransaction.setDisableActions(true)
        defer {
            CATransaction.commit()
            passing = false
            MainThreadMonitor.shared.note("list scroll \(oldRange)->\(settledWindow.range) \((CACurrentMediaTime() - started) * 1000) ms")
            if !deferred.isEmpty {
                let queued = deferred; deferred.removeAll()
                DispatchQueue.main.async { for operation in queued { operation() } }
            }
        }
        let delta = offset - previousOffset
        let time = animations.now
        previousOffset = engine.offset; onUserScrollDelta?(delta, animations.now)
        let base = origin - settledWindow.minY, previous = settledWindow
        let flightOffsets = engine.coveredOffsets(horizon: 0.3)
        var offsets = flightOffsets
        if let track = animations.model.tracks[.init(.viewport, .viewportOffset)] {
            offsets = track.adding(to: flightOffsets ?? offset...offset)
        }
        let coverage = offsets.map { ($0.lowerBound - base)...($0.upperBound - base) }
        settledWindow.rebalance(count: items.count, offsetInFrameSpace: engine.offset - base, viewportHeight: viewport.height, margin: preloadMargin, coveredOffsets: coverage, maximumAdditionalRows: flightOffsets == nil ? nil : 64) { [self] index in
            let item = items[index], key = MeasurementKey(identity: item.identity, revision: item.revision, width: viewport.contentWidth, environment: measurementEnvironmentKey &+ item.measurementEnvironment &* 0x9e3779b97f4a7c15)
            if item.measuresAsynchronously, measurements.height(for: key) == nil { requestMeasurement(index); return nil }
            if views[item.identity] == nil, carried[item.identity] == nil {
                releaseRetired(item.identity)
                if let spare = takePremounted(item.identity, key: key) {
                    views[item.identity] = spare.view; unveiling.insert(ObjectIdentifier(spare.view))
                    let reserve = reservedHeights(at: index)
                    return (item.measuresAsynchronously ? measurements.height(for: key)! : spare.height, reserve.0, reserve.1)
                }
            }
            let view = views[item.identity] ?? carried[item.identity]?.view ?? item.makeView()
            if views[item.identity] == nil { item.apply(to: view, transition: .immediate) }
            views[item.identity] = view
            let height = item.measuresAsynchronously ? measurements.height(for: key)! : view.update(width: viewport.contentWidth, transition: .immediate)
            if item.measuresAsynchronously {
                if view.superview == nil { container.addSubview(view) }
                view.applyPreparation(preparations[key] ?? .init(height: height), width: viewport.contentWidth, environment: measurementEnvironment)
            }
            let reserve = reservedHeights(at: index)
            return (height, reserve.0, reserve.1)
        }
        if previous != settledWindow {
            let current = Set(settledWindow.rows.map { items[$0.index].identity })
            for (id, view) in views where !current.contains(id) {
                view.visibleRectUpdated(nil); animations.unbind(.row(id)); views.removeValue(forKey: id)
                retire(view, identity: id)
            }
            let nextOrigin = engineMode == .uiKit
                ? base + settledWindow.minY
                : engine.containerOrigin(height: settledWindow.height, top: settledWindow.range.lowerBound == 0, bottom: settledWindow.range.upperBound == items.count)
            let shift = nextOrigin - settledWindow.minY - base
            let carryPositions = Dictionary(uniqueKeysWithValues: carried.map { identity, carry in
                (identity, carry.view.layer.position.y + animations.presentedDisplacement(.row(identity), at: time))
            })
            origin = nextOrigin; shiftDetached(by: shift)
            engine.shift(by: shift); previousOffset = engine.offset
            CATransaction.begin(); CATransaction.setDisableActions(true)
            container.frame = .init(x: 0, y: origin, width: viewport.width, height: max(1, settledWindow.height))
            var mountedCarries: [String: Double] = [:]
            for row in settledWindow.rows {
                let id = items[row.index].identity
                guard let view = views[id] else { continue }
                if let shown = carryPositions[id] { mountedCarries[id] = shown + shift }
                carried.removeValue(forKey: id)
                carryGenerations.removeValue(forKey: id)
                if view.superview !== container { container.addSubview(view) }
                view.place(in: .init(x: viewport.insets.left, y: row.y - settledWindow.minY, width: viewport.contentWidth, height: row.height))
                if unveiling.remove(ObjectIdentifier(view)) != nil { view.isHidden = false }
                view.onContentDidChange = { [weak self] animated in self?.markDirty(id, animated: animated) }
                animations.bind(.row(id), layer: view.layer)
                view.readinessObserver = { [weak self] in self?.accessibilityCoordinator.reconcile() }
                if !previous.range.contains(row.index) { animations.seed(.row(id), width: viewport.contentWidth, height: row.height) }
            }
            mountMotion(previous: previous, carriedPositions: mountedCarries, at: time)
            declaredEdges = settledWindow.edges(origin: origin, count: items.count, viewport: viewport, pinnedIndex: pinnedIndex)
            engine.setEdges(declaredEdges); resolveAttachments(transition: .immediate)
            CATransaction.commit()
        }
        if let index = settledWindow.rows.first(where: { base + $0.maxY > offset })?.index {
            let direction = engine.coveredOffsets(horizon: 0.3).map { $0.lowerBound + $0.upperBound < 2 * engine.offset ? -1 : 1 } ?? (delta < 0 ? -1 : 1)
            requestAhead(anchor: index, direction: direction)
        }
        if let covered = engine.coveredOffsets(horizon: 0.3), covered.lowerBound + covered.upperBound != 2 * engine.offset {
            scrollDirection = covered.lowerBound + covered.upperBound < 2 * engine.offset ? -1 : 1
        } else if abs(delta) > 1e-6 { scrollDirection = delta < 0 ? -1 : 1 }
        if let premounted, premounted.direction != scrollDirection { self.premounted = nil; retire(premounted.view, identity: premounted.identity) }
        if !retired.isEmpty || premountIndex() != nil { scheduleIdleTurn() }
        sweepPreparations()
        renderAttachments(); reportVisibility(); super.handleScroll(engine.offset)
    }

    // MARK: Premount and deferred unmount

    /// The row an idle turn would build: the next one past the window in the
    /// direction of the latest scroll, unless it is built already.
    private func premountIndex() -> Int? {
        // A held target (a readiness hold stages its own views) comes with a pass soon.
        guard scrollDirection != 0, !settledWindow.rows.isEmpty, viewport.contentWidth > 0,
              pendingDisplayViews.isEmpty, pendingScroll == nil else { return nil }
        let index = scrollDirection > 0 ? settledWindow.range.upperBound : settledWindow.range.lowerBound - 1
        guard items.indices.contains(index) else { return nil }
        let item = items[index]
        if let premounted, premounted.index == index, premounted.identity == item.identity,
           premounted.key == measurementKey(item, width: viewport.contentWidth), premounted.pass == appliedPassCount { return nil }
        guard views[item.identity] == nil, carried[item.identity] == nil else { return nil }
        if item.measuresAsynchronously, measurements.height(for: measurementKey(item, width: viewport.contentWidth)) == nil { return nil }
        // A row that animates in the first time it is shown plays that where it is seen.
        if let node = ((item as? HorizontalRow)?.base ?? item) as? NodeRow, node.animatesContent, node.appearance != nil, !node.appearanceShown { return nil }
        return index
    }
    private func takePremounted(_ identity: String, key: MeasurementKey) -> PremountedRow? {
        guard let premounted, premounted.identity == identity else { return nil }
        self.premounted = nil
        guard premounted.key == key, premounted.pass == appliedPassCount else { retire(premounted.view, identity: identity); return nil }
        return premounted
    }
    /// Hides a row view at once; an idle turn takes it out of the hierarchy.
    private func retire(_ view: ListRowView, identity: String) {
        unveiling.remove(ObjectIdentifier(view))
        view.isHidden = true; view.onContentDidChange = nil; view.readinessObserver = nil
        retired.append((identity, view))
        // Hidden views still cost memory; past a few, release the oldest now.
        while retired.count > 16 { retired.removeFirst().view.removeFromSuperview() }
        scheduleIdleTurn()
    }
    /// A row coming back while its old view waits gets a new view; the old
    /// one goes first, so the two don't pass a host between them.
    private func releaseRetired(_ identity: String) {
        guard let index = retired.firstIndex(where: { $0.identity == identity }) else { return }
        retired.remove(at: index).view.removeFromSuperview()
    }
    private func releaseSpareRows() {
        if let premounted { self.premounted = nil; unveiling.remove(ObjectIdentifier(premounted.view)); premounted.view.removeFromSuperview() }
        for entry in retired { entry.view.removeFromSuperview() }
        retired.removeAll()
    }
    /// A turn of its own, after this one's commit: a timer, because blocks
    /// queued on the main queue from this turn run before it ends.
    private func scheduleIdleTurn() {
        guard !idleTurnScheduled else { return }
        idleTurnScheduled = true
        let timer = Timer(timeInterval: 0.001, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.idleTurn() }
        }
        RunLoop.main.add(timer, forMode: .common)
    }
    /// One piece of work per turn: the next row's premount, else a release.
    private func idleTurn() {
        idleTurnScheduled = false
        guard window != nil else { releaseSpareRows(); return }
        guard !passing else { scheduleIdleTurn(); return }
        CATransaction.begin(); CATransaction.setDisableActions(true)
        // One row past the window, or none: the window moved on, or a scroll turned.
        if let premounted, premounted.index != (premounted.direction > 0 ? settledWindow.range.upperBound : settledWindow.range.lowerBound - 1) {
            self.premounted = nil; retire(premounted.view, identity: premounted.identity)
        }
        if let index = premountIndex() { premount(index) }
        else if !retired.isEmpty { retired.removeFirst().view.removeFromSuperview() }
        CATransaction.commit()
        if !retired.isEmpty || premountIndex() != nil { scheduleIdleTurn() }
    }
    /// Builds the row as a scroll would mount it, hidden in the container.
    private func premount(_ index: Int) {
        let started = CACurrentMediaTime()
        if let premounted { self.premounted = nil; retire(premounted.view, identity: premounted.identity) }
        let item = items[index], key = measurementKey(item, width: viewport.contentWidth)
        releaseRetired(item.identity)
        let view = item.makeView()
        item.apply(to: view, transition: .immediate)
        view.isHidden = true
        let height: Double
        if item.measuresAsynchronously {
            height = measurements.height(for: key)!
            container.addSubview(view)
            view.applyPreparation(preparations[key] ?? .init(height: height), width: viewport.contentWidth, environment: measurementEnvironment)
        } else {
            height = view.update(width: viewport.contentWidth, transition: .immediate)
            container.addSubview(view)
        }
        precondition(height.isFinite && height >= 0)
        view.place(in: .init(x: viewport.insets.left, y: 0, width: viewport.contentWidth, height: height))
        // Its own layout, a nested list's included, happens now rather than in
        // the turn that shows it.
        view.layoutIfNeeded()
        // Content that changes before the row is shown needs measuring again.
        let identity = item.identity
        view.onContentDidChange = { [weak self, weak view] _ in
            guard let self, let premounted, premounted.view === view else { return }
            self.premounted = nil; retire(premounted.view, identity: identity)
        }
        premounted = .init(identity: item.identity, index: index, direction: scrollDirection, key: key, height: height, view: view, pass: appliedPassCount)
        MainThreadMonitor.shared.note("list premount \(index) \((CACurrentMediaTime() - started) * 1000) ms")
    }

    private func resolveMountContinuation(at time: Double) {
        guard var record = mountContinuation else { return }
        if record.origin == nil, let witness = record.witness, let generation = record.witnessGeneration {
            record.origin = animations.clockOrigin(witness, generation: generation, fallback: record.clock.startTime)
        }
        let deadline = max(record.deadline, (record.origin ?? record.clock.startTime) + record.clock.transition.duration)
        mountContinuation = time < deadline ? record : nil
    }

    private func mountMotion(previous: ListWindow, carriedPositions: [String: Double], at time: Double,
                             mounting: [WindowRow]? = nil) {
        resolveMountContinuation(at: time)
        let heightMotions = animations.heightMotions(at: time), layout = animations.layoutPosition(at: time)
        guard mountContinuation != nil || !heightMotions.isEmpty || layout != nil || !carriedPositions.isEmpty else { return }
        let geometry = mountSizeGeometry
        func placement(_ view: ListRowView?) -> Double {
            guard let view else { return 0 }
            return view.placementOffset(size: .init(width: viewport.contentWidth, height: 1)).y
                - view.placementOffset(size: .init(width: viewport.contentWidth, height: 0)).y
        }
        func followers(_ row: WindowRow, view: ListRowView) -> [AnimationController.PositionLayer] {
            let own = placement(view)
            let heights = heightMotions.compactMap { motion -> AnimationController.PositionLayer? in
                guard let geometry, let source = identityIndices[motion.identity] else { return nil }
                let coefficient = geometry.coefficient(source: source, row: row.index,
                    from: motion.track.from, to: motion.track.to, ownPlacement: own)
                guard abs(coefficient) > 1e-6 else { return nil }
                return .init(source: .height(motion.identity), track: motion.track.residual(multipliedBy: coefficient), origin: motion.origin)
            }
            return heights + (layout.map { [$0] } ?? [])
        }
        var witnesses = previous.rows.map(\.index)
        // Work from the old window outward, so a new row can become the next
        // row's witness. A large scroll can still use the unbound edge's model.
        let rows = mounting ?? (settledWindow.rows.filter { $0.index >= previous.range.upperBound }
            + settledWindow.rows.filter { $0.index < previous.range.lowerBound }.reversed())
        for row in rows {
            let identity = items[row.index].identity, owner = AnimationOwner.row(identity)
            guard let view = views[identity] else { continue }
            var layers = followers(row, view: view)
            if let record = mountContinuation, record.participants.contains(identity), mounting == nil {
                if let continuation = animations.positionLayer(owner, source: .continuation) { layers.append(continuation) }
            } else if let record = mountContinuation,
                      let reference = witnesses.filter({
                          items.indices.contains($0) && record.oldIndices[items[$0].identity] != nil
                              && record.newIndices[items[$0].identity] != nil && !record.moved.contains(items[$0].identity)
                      }).min(by: { abs($0 - row.index) < abs($1 - row.index) }) {
                let referenceID = items[reference].identity, referenceOwner = AnimationOwner.row(referenceID)
                animations.inheritPosition(owner, from: referenceOwner)
                let own = placement(view), referenceOwn = record.placements[referenceID] ?? placement(views[referenceID] ?? carried[referenceID]?.view)
                var difference = 0.0
                if !record.moved.contains(identity), let oldRow = record.oldIndices[identity],
                   let oldReference = record.oldIndices[referenceID], let newRow = record.newIndices[identity],
                   let newReference = record.newIndices[referenceID] {
                    difference = ContinuationField.delta(old: record.oldIDs, new: record.newIDs,
                        oldReference: oldReference, oldRow: oldRow, newReference: newReference, newRow: newRow,
                        oldBand: { record.band($0, before: true) },
                        newBand: { record.band($0, before: false) },
                        referencePlacement: referenceOwn, rowPlacement: own) ?? 0
                }
                let inherited = animations.positionLayer(referenceOwner, source: .continuation)?.track.from ?? 0
                if abs(inherited + difference) > 1e-6 {
                    var track = record.clock; track.from = inherited + difference
                    layers.append(.init(source: .continuation, track: track, origin: record.origin))
                }
            }
            animations.setPositionLayers(owner, layers)
            if let shown = carriedPositions[identity] {
                animations.joinPosition(owner, shown: shown, target: origin + view.layer.position.y, at: time)
            }
            mountContinuation?.participants.insert(identity)
            mountContinuation?.placements[identity] = placement(view)
            witnesses.append(row.index)
        }
    }
    private static func mergePreparedMutations(_ old: PreparedMutation, _ new: PreparedMutation) -> PreparedMutation {
        var result = new
        if result.intent == nil, var intent = old.intent {
            if result.additionalDistance != 0 { intent.distance = 0 }
            result.intent = intent
            result.animatesInsertions = old.animatesInsertions
        }
        if result.viewportRequest == old.viewportRequest {
            result.size = result.size ?? old.size; result.insets = result.insets ?? old.insets
        }
        result.blocks = old.blocks + result.blocks
        return result
    }
    private func preparedIntent(_ mutation: PreparedMutation) -> ScrollIntent? {
        rebasedIntent(mutation.intent, in: mutation.items)
    }
    private func rebasedIntent(_ candidate: ScrollIntent?, in collection: [any ListRow]) -> ScrollIntent? {
        guard var intent = candidate else { return nil }
        if let identity = intent.identity {
            if let index = collection.firstIndex(where: { $0.identity == identity }) { intent.target.index = index }
            else { return nil }
        }
        return intent
    }
    private func requestedPreparations(_ mutation: PreparedMutation) -> [(item: any ListRow, key: MeasurementKey, width: Double)] {
        guard !mutation.items.isEmpty else { return [] }
        let currentViewport = mutation.viewportRequest == viewportRequest
        let insets = currentViewport ? mutation.insets ?? viewport.insets : viewport.insets
        let width = max(0, (currentViewport ? mutation.size.map { Double($0.width) } ?? viewport.width : viewport.width) - insets.left - insets.right)
        guard width > 0 else { return [] }
        let witness = settledWindow.rows.first(where: { (settledFrame(at: $0.index)?.maxY ?? 0) > viewport.insets.top })
        let identity = witness.flatMap { items.indices.contains($0.index) ? items[$0.index].identity : nil }
        let anchor = eligibleIntent(preparedIntent(mutation))?.target.index ?? identity.flatMap { id in mutation.items.firstIndex { $0.identity == id } } ?? 0
        return MeasurementCache.priority(count: mutation.items.count, anchor: anchor, direction: 1, limit: min(80, max(24, settledWindow.rows.count + 8))).compactMap { index in
            let item = mutation.items[index], key = measurementKey(item, width: width)
            guard item.measuresAsynchronously else { return nil }
            return (item, key, width)
        }
    }
    private func projectedPreparations(_ mutation: PreparedMutation, generation: UInt64) -> PreparationProjection? {
        if let intent = eligibleIntent(preparedIntent(mutation)), intent.target.identity != nil,
           intent.relativeDistance == 0,
           let projected = projectedIdentityPreparations(mutation, intent: intent, generation: generation) {
            return projected
        }
        return projectedPreservedPreparations(mutation)
    }

    /// Identity targets opt into a height-only resolver, so their destination
    /// can be prepared without creating or updating a live row.
    private func projectedIdentityPreparations(_ mutation: PreparedMutation, intent: ScrollIntent, generation: UInt64) -> PreparationProjection? {
        guard !settledWindow.rows.isEmpty, !mutation.items.isEmpty else { return nil }
        let currentViewport = mutation.viewportRequest == viewportRequest
        let size = currentViewport ? mutation.size : nil
        let insets = currentViewport ? mutation.insets ?? viewport.insets : viewport.insets
        guard size.map({ Double($0.width) == viewport.width && Double($0.height) == viewport.height }) ?? true,
              insets == viewport.insets, viewport.contentWidth > 0, viewport.height > 0 else { return nil }

        engine.sync()
        let width = viewport.contentWidth, oldWindow = settledWindow
        let oldOffset = engine.offset, oldSettled = declaredEdges.clamped(oldOffset)
        let anchor = min(max(0, intent.target.index), mutation.items.count - 1)
        let nextPinned = mutation.items.firstIndex(where: \.pinsToBottomEdge)
        var missing: [MeasurementKey: (item: any ListRow, key: MeasurementKey, width: Double)] = [:]
        var unsupported = false
        var resolution: TargetResolution?
        var retained: Set<MeasurementKey> = []
        func measure(_ index: Int) -> (height: Double, top: Double, bottom: Double)? {
            let item = mutation.items[index], key = measurementKey(item, width: width)
            retained.insert(key)
            let height: Double
            if item.measuresAsynchronously {
                guard let cached = measurements.height(for: key) else {
                    missing[key] = (item, key, width)
                    return nil
                }
                height = cached
            } else if settledValueGeometry?.width == width, settledValueGeometry?.environment == measurementEnvironmentKey,
                      !scheduler.dirty.contains(item.identity), let oldIndex = identityIndices[item.identity],
                      item.isEqual(to: items[oldIndex]), let row = oldWindow.rows.first(where: { $0.index == oldIndex }) {
                height = row.height
            } else if !scheduler.dirty.contains(item.identity), pendingDisplayGate === intent.gate,
                      let staged = pendingDisplayHeights[key], item.isEqual(to: staged.item) {
                height = staged.height
            } else {
                unsupported = true
                return nil
            }
            let reserve = reservedHeights(at: index, in: mutation.items)
            return (height, reserve.0, reserve.1)
        }
        let window = ListWindow.build(count: mutation.items.count, anchor: anchor, viewport: viewport,
            margin: preloadMargin, pinnedIndex: nextPinned, measure: measure) { height in
                let offset = intent.target.resolve(height, nil)
                resolution = TargetResolution(generation: generation, gate: intent.gate,
                    key: measurementKey(mutation.items[anchor], width: width), height: height,
                    viewport: viewport, offset: offset)
                return viewport.insets.top + mutation.additionalDistance + intent.distance + offset
            }
        // A synchronous row without a known value still takes the existing
        // path. Reuse a resolution already made before reaching that row.
        if unsupported { return .init(required: [], missing: Array(missing.values), retained: retained, target: resolution) }
        guard !window.rows.isEmpty else { return .init(required: [], missing: Array(missing.values), retained: retained) }
        let placement = WindowPlacement(newWindow: window, count: mutation.items.count, viewport: viewport, pinnedIndex: nextPinned,
            oldWindowIsEmpty: false, platformCoordinates: engineMode == .uiKit, hasTarget: true,
            oldOrigin: origin, oldOffset: oldOffset, oldSettled: oldSettled, oldOverscroll: oldOffset - oldSettled,
            displaces: mutation.additionalDistance + intent.distance != 0, moves: false,
            absorbsOverscroll: mutation.absorbsOverscroll,
            containerOrigin: engine.containerOrigin(height: window.height, top: window.range.lowerBound == 0, bottom: window.range.upperBound == mutation.items.count))
        for index in placement.uncoveredIndices { _ = measure(index) }
        return .init(required: placement.physicalRows.map { measurementKey(mutation.items[$0.index], width: width) },
            missing: Array(missing.values), retained: retained, target: resolution)
    }

    /// Height changes in the same collection can expose rows beyond the old
    /// window. Predict that window from values before touching any live view.
    private func projectedPreservedPreparations(_ mutation: PreparedMutation) -> PreparationProjection? {
        let candidate = mutation.intent ?? pendingIntent
        guard !settledWindow.rows.isEmpty, eligibleIntent(preparedIntent(mutation)) == nil,
              eligibleIntent(rebasedIntent(pendingIntent, in: mutation.items)) == nil, pendingItems == nil,
              (candidate?.relativeDistance ?? 0) == 0, (pendingIntent?.relativeDistance ?? 0) == 0,
              mutation.additionalDistance == 0, mutation.items.count == items.count,
              zip(mutation.items, items).allSatisfy({ $0.identity == $1.identity }),
              mutation.items.firstIndex(where: \.pinsToBottomEdge) == pinnedIndex else { return nil }
        let currentViewport = mutation.viewportRequest == viewportRequest
        let size = currentViewport ? mutation.size : nil
        let insets = currentViewport ? mutation.insets ?? viewport.insets : viewport.insets
        guard size.map({ Double($0.width) == viewport.width && Double($0.height) == viewport.height }) ?? true,
              insets == viewport.insets, viewport.contentWidth > 0, viewport.height > 0 else { return nil }

        engine.sync()
        let oldWindow = settledWindow, oldOffset = engine.offset, oldOrigin = origin
        let oldSettled = declaredEdges.clamped(oldOffset), oldOverscroll = oldOffset - oldSettled
        let oldBase = oldOrigin - oldWindow.minY
        let anchorMode: ListAnchorMode = candidate == nil ? mutation.anchorMode : .preserveVisibleContent
        let survivor = PreservedWindowAnchor.survivor(in: oldWindow, base: oldBase, settled: oldSettled,
            topInset: viewport.insets.top, automatic: anchorMode == .automatic) { _ in true }
        let atTop = oldWindow.range.lowerBound == 0 && abs(oldSettled - (declaredEdges.minimum ?? .infinity)) < 1e-6
        let preserved = PreservedWindowAnchor(oldWindow: oldWindow, oldBase: oldBase, oldSettled: oldSettled,
            oldViewport: viewport, newViewport: viewport, oldSlack: oldWindow.pinSlack(index: pinnedIndex, viewport: viewport),
            pinnedIndex: pinnedIndex, holdsPinnedRow: holdsPinnedRow, survivor: survivor, survivorNewIndex: survivor?.index,
            atTop: atTop, automatic: anchorMode == .automatic, additionalDistance: 0, compensates: mutation.compensates)
        var missing: [MeasurementKey: (item: any ListRow, key: MeasurementKey, width: Double)] = [:]
        var unsupported = false
        let width = viewport.contentWidth
        var retained: Set<MeasurementKey> = []
        let window = preserved.window(count: mutation.items.count, margin: preloadMargin) { index in
            let item = mutation.items[index], key = measurementKey(item, width: width)
            retained.insert(key)
            let height: Double
            if item.measuresAsynchronously {
                guard let measured = measurements.height(for: key) else {
                    if unavailableMeasurements.contains(key) { unsupported = true }
                    else { missing[key] = (item, key, width) }
                    return nil
                }
                height = measured
            } else {
                guard item.isEqual(to: items[index]), let old = oldWindow.rows.first(where: { $0.index == index }) else {
                    unsupported = true
                    return nil
                }
                height = old.height
            }
            let reserve = reservedHeights(at: index, in: mutation.items)
            return (height, reserve.0, reserve.1)
        }
        guard !unsupported else { return nil }
        guard !window.rows.isEmpty else { return .init(required: [], missing: Array(missing.values), retained: retained) }
        let placement = WindowPlacement(newWindow: window, count: mutation.items.count, viewport: viewport, pinnedIndex: pinnedIndex,
            oldWindowIsEmpty: false, platformCoordinates: engineMode == .uiKit, hasTarget: false,
            oldOrigin: oldOrigin, oldOffset: oldOffset, oldSettled: oldSettled, oldOverscroll: oldOverscroll,
            displaces: false, moves: false, absorbsOverscroll: mutation.absorbsOverscroll,
            containerOrigin: engine.containerOrigin(height: window.height, top: window.range.lowerBound == 0, bottom: window.range.upperBound == items.count))
        let required = placement.physicalRows.compactMap { row -> MeasurementKey? in
            let item = mutation.items[row.index]
            guard item.measuresAsynchronously else { return nil }
            if let frame = settledFrame(at: row.index), frame.maxY > 0, frame.minY < viewport.height,
               views[item.identity]?.isDisplayReady == true { return nil }
            return measurementKey(item, width: width)
        }
        return .init(required: required, missing: Array(missing.values), retained: retained)
    }
    private func drainPreparedMutations() {
        guard !passing, !drainingPreparations else { return }
        drainingPreparations = true
        defer { drainingPreparations = false }
        while !preparationQueue.isEmpty {
            promotePendingIdentityIntent()
            preparationKeys.removeAll(keepingCapacity: true)
            activePreparationItems.removeAll(keepingCapacity: true)
            var resolutions: [UInt64: TargetResolution] = [:]
            for entry in preparationQueue.entries {
                let effective = entry.generation == preparationQueue.latest?.generation
                    ? preparationQueue.inFlight.map { Self.mergePreparedMutations($0.value, entry.value) } ?? entry.value
                    : entry.value
                let requests = requestedPreparations(effective)
                let projectsIdentity = eligibleIntent(preparedIntent(effective)).map { $0.target.identity != nil && $0.relativeDistance == 0 } ?? false
                var physicalSoon: Set<MeasurementKey> = []
                preparationKeys.formUnion(requests.map(\.key))
                for request in requests { activePreparationItems[request.key] = (entry.generation, request.item) }
                let missing = requests.filter { measurements.height(for: $0.key) == nil && !unavailableMeasurements.contains($0.key) }
                var waiting = Set(missing.map(\.key))
                if missing.isEmpty, let projected = projectedPreparations(effective, generation: entry.generation) {
                    if let target = projected.target { resolutions[entry.generation] = target }
                    preparationKeys.formUnion(projected.retained)
                    preparationKeys.formUnion(projected.required)
                    physicalSoon.formUnion(projected.required)
                    preparationKeys.formUnion(projected.missing.map(\.key))
                    for key in projected.required where awaitProjectedDisplay(key, gate: projected.target?.gate) { waiting.insert(key) }
                    for request in projected.missing {
                        activePreparationItems[request.key] = (entry.generation, request.item)
                        waiting.insert(request.key)
                        requestMeasurement(request.item, key: request.key, width: request.width)
                    }
                }
                preparationQueue.replaceWaiting(generation: entry.generation, with: waiting)
                // Requests come nearest the anchor first: those the mutation will show.
                let soon = projectsIdentity ? physicalSoon : Set(requests.prefix(rowsShownSoon).map(\.key))
                for key in soon { showSoon(key) }
                for request in missing { requestMeasurement(request.item, key: request.key, width: request.width, showsSoon: soon.contains(request.key)) }
            }
            guard let ready = preparationQueue.takeReady(merge: Self.mergePreparedMutations) else { return }
            let mutation = ready.value, currentViewport = mutation.viewportRequest == viewportRequest
            if let intent = eligibleIntent(preparedIntent(mutation)), let identity = intent.identity {
                preparationQueue.updateNewest { successor in
                    if successor.intent == nil, successor.items.contains(where: { $0.identity == identity }) {
                        var carried = intent
                        if successor.additionalDistance != 0 { carried.distance = 0 }
                        carried.relativeDistance = 0
                        successor.intent = carried
                    }
                }
            }
            applyingPreparedMutation = true
            applyingPreparedTarget = (ready.generation, resolutions[ready.generation])
            applyChanges(items: mutation.items, newSize: currentViewport ? mutation.size : nil, newInsets: currentViewport ? mutation.insets : nil,
                intent: mutation.intent, additionalScrollDistance: mutation.additionalDistance, anchorMode: mutation.anchorMode,
                compensatesInsetChange: mutation.compensates, absorbsEdgeChangeIntoOverscroll: mutation.absorbsOverscroll,
                animatesInsertions: mutation.animatesInsertions, transition: mutation.transition)
            applyingPreparedMutation = false
            if pendingItems != nil { pendingBlockAnimations += mutation.blocks }
            else { for block in mutation.blocks { animateInsertedBlockNow(block) } }
        }
        preparationKeys.removeAll(keepingCapacity: true)
        activePreparationItems.removeAll(keepingCapacity: true)
    }
    private func awaitProjectedDisplay(_ key: MeasurementKey, gate: ScrollIntentGate?) -> Bool {
        let drawing = awaitPreparedDisplay(key)
        guard let gate, pendingDisplayGate === gate, let view = pendingDisplayViews[key], !view.isDisplayReady else { return drawing }
        view.displayWaitObserver = { [weak self, weak gate] in
            guard let self, let gate, preparationOwns(gate) else { return }
            drainPreparedMutations()
        }
        return true
    }
    /// Drawing waits belong to preparation, before a pass can touch live rows.
    private func awaitPreparedDisplay(_ key: MeasurementKey) -> Bool {
        guard let content = preparations[key]?.content as? any DisplayPreparedContent,
              !content.isDisplayPrepared else { return false }
        if preparationDraws[key] != nil { return true }
        guard let drawing = content.drawAhead() else { return false }
        nextPreparationDraw &+= 1
        let ticket = nextPreparationDraw
        let task = Task { [weak self] in
            await drawing.value
            guard let self, !Task.isCancelled, preparationDraws[key]?.ticket == ticket else { return }
            preparationDraws.removeValue(forKey: key)
            drainPreparedMutations()
        }
        preparationDraws[key] = (ticket, task)
        return true
    }
    private func markDirty(_ id: String, animated: Bool) {
        if scheduler.mark(id, animated: animated) {
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                scheduler.beginFlush()
                if !scheduler.dirty.isEmpty {
                    if let retry = pendingScroll { pendingScroll = nil; retry() }
                    else { applyChanges(transition: scheduler.animated ? defaultTransition : .immediate) }
                    if !preparationQueue.isEmpty { drainPreparedMutations() }
                }
            }
        }
    }
    private func requestMeasurement(_ index: Int) {
        guard items.indices.contains(index) else { return }
        let item = items[index]
        guard item.measuresAsynchronously else { return }
        let width = viewport.contentWidth
        // A pass or a scroll needs this row in its window.
        requestMeasurement(item, key: measurementKey(item, width: width), width: width, showsSoon: true)
    }
    /// About how many rows nearest an anchor the next passes place, taken
    /// alternately on either side of it as the requests are: on each side,
    /// the viewport and a preload margin beyond it each way, at the loaded
    /// rows' mean height.
    private var rowsShownSoon: Int {
        let mean = settledWindow.rows.isEmpty ? 60 : max(20, settledWindow.height / Double(settledWindow.rows.count))
        return 2 * Int(((viewport.visibleHeight + 2 * preloadMargin) / mean).rounded(.up)) + 1
    }
    /// A row the list will show soon, prepared or being prepared without the
    /// hint, is drawn ahead now, or before its preparation is stored.
    private func showSoon(_ key: MeasurementKey) {
        if let content = preparations[key]?.content { _ = content.drawAhead() }
        else if measurementTasks[key] != nil { soonKeys.insert(key) }
    }
    private func drawAheadLater(_ key: MeasurementKey) {
        guard !drawAheadQueue.contains(key) else { return }
        if drawAheadQueue.isEmpty { DispatchQueue.main.async { [weak self] in self?.drainDrawAhead() } }
        drawAheadQueue.append(key)
    }
    /// Draws queued rows ahead for about a millisecond a turn.
    private func drainDrawAhead() {
        let started = CACurrentMediaTime()
        while !drawAheadQueue.isEmpty, CACurrentMediaTime() - started < 0.001 { showSoon(drawAheadQueue.removeFirst()) }
        if !drawAheadQueue.isEmpty { DispatchQueue.main.async { [weak self] in self?.drainDrawAhead() } }
    }
    private func measurementKey(_ item: any ListRow, width: Double) -> MeasurementKey {
        .init(identity: item.identity, revision: item.revision, width: width, environment: measurementEnvironmentKey &+ item.measurementEnvironment &* 0x9e3779b97f4a7c15)
    }
    private func requestMeasurement(_ item: any ListRow, key: MeasurementKey, width: Double, showsSoon: Bool = false) {
        let environment = measurementEnvironment
        if showsSoon { showSoon(key) }
        guard width > 0, !unavailableMeasurements.contains(key), let ticket = measurements.request(key) else { return }
        measurementTickets[key] = ticket
        measurementTasks[key] = Task { [weak self] in
            let preparation = await ListPreparationHint.$showsSoon.withValue(showsSoon) {
                await item.prepare(width: width, environment: environment)
            }
            guard let self else { return }
            if measurementTickets[key] == ticket, soonKeys.remove(key) != nil, let drawing = preparation?.content?.drawAhead() {
                await drawing.value
            }
            // A reset or a newer request while it drew leaves this one stale.
            guard measurementTickets[key] == ticket else { return }
            measurementTickets.removeValue(forKey: key)
            measurementTasks.removeValue(forKey: key)
            // Shown soon again while it drew: what it stores is drawn.
            soonKeys.remove(key)
            speculativeKeys.remove(key)
            defer { pumpSpeculativePreparations() }
            let result = measurements.store(key, height: preparation?.height ?? .nan, ticket: ticket)
            if result == .stored, let preparation {
                preparations[key] = preparation
                measurementFailures.removeValue(forKey: key)
                let awaited = finishAwaitedMeasurement(key)
                if !retainsPreparation(key), preparation.content?.hasLiveHost != true {
                    preparations.removeValue(forKey: key); measurements.forget(key)
                }
                sweepPreparations()
                if !awaited, let index = identityIndices[item.identity], items[index].revision == item.revision,
                   settledWindow.range.contains(index) || index == settledWindow.range.lowerBound - 1 || index == settledWindow.range.upperBound || index == pendingTarget?.index || pendingDisplayMeasurements.contains(key) {
                    markDirty(item.identity, animated: false)
                } else if !awaited, let pendingItems, let index = pendingIdentityIndices[item.identity], pendingItems[index].revision == item.revision {
                    markDirty(item.identity, animated: false)
                }
            }
            else if result == .invalid {
                measurements.cancelRequest(key, ticket: ticket)
                unavailableMeasurements.insert(key)
                _ = finishAwaitedMeasurement(key)
                let failures = measurementFailures[key, default: 0]
                measurementFailures[key] = min(5, failures + 1)
                let delay = min(5, 0.2 * pow(2, Double(failures)))
                DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                    guard let self else { return }
                    unavailableMeasurements.remove(key)
                    let retryItem: any ListRow
                    if let index = identityIndices[item.identity], measurementKey(items[index], width: viewport.contentWidth) == key {
                        retryItem = items[index]
                    } else if let pendingItems, let index = pendingIdentityIndices[item.identity],
                              measurementKey(pendingItems[index], width: viewport.contentWidth) == key {
                        retryItem = pendingItems[index]
                    } else if let queued = activePreparationItems[key],
                              preparationQueue.entries.contains(where: { $0.generation == queued.generation }),
                              measurementKey(queued.item, width: viewport.contentWidth) == key {
                        retryItem = queued.item
                    } else {
                        measurementFailures.removeValue(forKey: key); return
                    }
                    requestMeasurement(retryItem, key: key, width: width)
                }
            }
        }
    }
    private func finishAwaitedMeasurement(_ key: MeasurementKey) -> Bool {
        let awaited = preparationQueue.entries.contains { $0.waiting.contains(key) }
        preparationQueue.complete(key)
        drainPreparedMutations()
        return awaited
    }
    private func requestAhead(anchor: Int, direction: Int) {
        let indices: [Int]
        if engine.coveredOffsets(horizon: 0.3) != nil {
            indices = (0..<64).map { anchor + $0 * (direction < 0 ? -1 : 1) }.filter { items.indices.contains($0) }
        } else { indices = MeasurementCache.priority(count: items.count, anchor: anchor, direction: direction, limit: 64) }
        // Indices come nearest the anchor first, in the direction of travel.
        let soon = Set(indices.prefix(rowsShownSoon))
        // Prepared rows ahead are drawn soon after; those just passed, whose
        // views went, are drawn again only once the scroll turns toward them.
        for index in soon where (index - anchor) * direction >= 0 && items[index].measuresAsynchronously {
            drawAheadLater(measurementKey(items[index], width: viewport.contentWidth))
        }
        speculativeRequests = indices.compactMap { index in
            let item = items[index], key = measurementKey(item, width: viewport.contentWidth)
            guard item.measuresAsynchronously, measurements.height(for: key) == nil, measurementTasks[key] == nil else { return nil }
            return (item, key, viewport.contentWidth, soon.contains(index))
        }
        pumpSpeculativePreparations()
    }
    private func pumpSpeculativePreparations() {
        while speculativeKeys.count < 6, !speculativeRequests.isEmpty {
            let request = speculativeRequests.removeFirst()
            guard measurementTasks[request.key] == nil, measurements.height(for: request.key) == nil,
                  !unavailableMeasurements.contains(request.key) else { continue }
            requestMeasurement(request.item, key: request.key, width: request.width, showsSoon: request.showsSoon)
            if measurementTasks[request.key] != nil { speculativeKeys.insert(request.key) }
        }
    }
    private func sweepPreparations(force: Bool = false) {
        let anchor = settledWindow.range.lowerBound
        guard force || lastPreparationSweepAnchor.map({ abs($0 - anchor) >= 16 }) ?? true else { return }
        lastPreparationSweepAnchor = anchor
        for (key, preparation) in preparations {
            guard !retainsPreparation(key) else { continue }
            if preparation.content?.hasLiveHost == true {
                schedulePreparationSweep(); continue
            }
            preparationDraws.removeValue(forKey: key)?.task.cancel()
            preparations.removeValue(forKey: key); measurements.forget(key)
        }
    }
    private func retainsPreparation(_ key: MeasurementKey) -> Bool {
        if preparationKeys.contains(key) || pendingDisplayViews[key] != nil || pendingDisplayMeasurements.contains(key) { return true }
        // Items waiting for a window they can build (pendingItems) keep the
        // rows it needs; the pending target names an index among them.
        if let pendingItems, let index = pendingIdentityIndices[key.identity],
           measurementKey(pendingItems[index], width: viewport.contentWidth) == key,
           pendingTarget.map({ abs(index - $0.index) <= 80 }) ?? true { return true }
        guard let index = identityIndices[key.identity],
              measurementKey(items[index], width: viewport.contentWidth) == key else { return false }
        let lower = max(0, settledWindow.range.lowerBound - 80)
        let upper = min(items.count, settledWindow.range.upperBound + 80)
        return index >= lower && index < upper || index == pinnedIndex || pendingTarget.map { abs(index - $0.index) <= 80 } == true
    }
    private func schedulePreparationSweep() {
        guard !preparationSweepScheduled else { return }
        preparationSweepScheduled = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in
            guard let self else { return }
            preparationSweepScheduled = false; sweepPreparations(force: true)
        }
    }
    private func reportVisibility() {
        let viewportRect = CGRect(x: viewport.insets.left, y: viewport.insets.top, width: viewport.contentWidth, height: viewport.visibleHeight)
        for row in settledWindow.rows {
            guard items.indices.contains(row.index), let view = views[items[row.index].identity], let rect = settledFrame(at: row.index) else { continue }
            view.readinessObserver = { [weak self] in self?.accessibilityCoordinator.reconcile() }
            let intersection = viewportRect.intersection(rect)
            view.visibleRectUpdated(intersection.isNull || intersection.isEmpty ? nil : intersection.offsetBy(dx: -rect.minX, dy: -rect.minY))
        }
        accessibilityCoordinator.reconcile()
        swipeActions.reconcile()
        let settled = declaredEdges.clamped(engine.offset), top = origin - settled, bottom = top + settledWindow.height
        let newTop = !settledWindow.rows.isEmpty && settledWindow.range.lowerBound == 0 && top >= loadedEdgeMargin - 1e-6
        let newBottom = !settledWindow.rows.isEmpty && settledWindow.range.upperBound == items.count && bottom <= viewport.height - loadedEdgeMargin + 1e-6
        let arriveTop = newTop && !reachedTop, arriveBottom = newBottom && !reachedBottom
        reachedTop = newTop; reachedBottom = newBottom
        if arriveTop { onLoadedEdgeReached?(.top) }; if arriveBottom { onLoadedEdgeReached?(.bottom) }
        onVisibleWindowChanged?()
    }

    public func animateInsertedBlock(identities: Set<String>, from edge: BoundaryEdge, transition: ListTransition = .easeInOut(0.3)) {
        let block = InsertedBlock(identities: identities, edge: edge, transition: transition)
        if !preparationQueue.isEmpty {
            preparationQueue.updateNewest { $0.blocks.append(block) }
            return
        }
        if passing { deferred.append { [weak self] in self?.animateInsertedBlock(identities: identities, from: edge, transition: transition) }; return }
        animateInsertedBlockNow(block)
    }
    private func animateInsertedBlockNow(_ block: InsertedBlock) {
        let rows = settledWindow.rows.filter { block.identities.contains(items[$0.index].identity) }
        guard let first = rows.first, let last = rows.last else { return }
        let distance = last.bandBottom - first.bandTop, time = animations.now
        for row in rows {
            let owner = AnimationOwner.row(items[row.index].identity)
            animations.replace(owner, .opacity, from: 1, to: 1, at: time, transition: .immediate)
            animations.replace(owner, .positionY, from: block.edge == .top ? -distance : distance, to: 0, at: time, transition: block.transition)
        }
    }

    private func shiftDetached(by delta: Double) {
        guard delta != 0 else { return }
        for parent in [exits, crossings] { for child in parent.subviews { child.layer.position.y += delta } }
        ghostLedger.shift(by: delta)
    }
    private func transitionDetachedHorizontalGeometry(at time: Double, transition: ListTransition) {
        func update(_ parent: UIView) {
            for child in parent.subviews {
                if let view = child as? ListRowView, let owner = animations.owner(boundTo: view.layer) {
                    let oldFrame = view.frame, oldSize = view.bounds.size
                    let newSize = CGSize(width: viewport.contentWidth, height: oldSize.height)
                    let oldPlacement = view.placementOffset(size: oldSize), newPlacement = view.placementOffset(size: newSize)
                    view.place(in: .init(x: viewport.insets.left, y: oldFrame.minY, width: newSize.width, height: newSize.height))
                    animations.transition(owner, .positionX, old: oldFrame.minX + oldPlacement.x, new: viewport.insets.left + newPlacement.x, at: time, transition: transition)
                    animations.transition(owner, .width, old: oldSize.width, new: newSize.width, at: time, transition: transition)
                } else { update(child) }
            }
        }
        update(exits); update(crossings); update(carousel)
    }

    private func makeDepartures(_ rows: [WindowRow], oldItems: [any ListRow], oldViews: [String: ListRowView], oldBase: Double, coordinateShift: Double, time: Double, transition: ListTransition) {
        var groups: [[WindowRow]] = []
        for row in rows.sorted(by: { $0.index < $1.index }) {
            if groups.last?.last?.index == row.index - 1 { groups[groups.count - 1].append(row) }
            else { groups.append([row]) }
        }
        for group in groups {
            let members = group.compactMap { row -> (WindowRow, String, ListRowView)? in
                let id = oldItems[row.index].identity
                return oldViews[id].map { (row, id, $0) }
            }
            guard let first = members.first else { continue }
            if transition.isImmediate {
                for (_, id, view) in members { view.removeFromSuperview(); animations.unbind(.row(id), removeModel: true) }
                continue
            }
            serial += 1; let blockID = serial
            func liveBounds(_ row: WindowRow, _ id: String, _ view: ListRowView) -> CGRect {
                let size = CGSize(width: animations.value(.row(id), .width, at: time), height: animations.value(.row(id), .height, at: time))
                let oldPlacement = view.placementOffset(size: view.bounds.size), livePlacement = view.placementOffset(size: size)
                return .init(x: view.frame.minX + oldPlacement.x - livePlacement.x, y: oldBase + row.y + coordinateShift + animations.value(.row(id), .positionY, at: time) + oldPlacement.y - livePlacement.y, width: size.width, height: size.height)
            }
            let root = liveBounds(first.0, first.1, first.2).minY
            let wrapper = UIView(); wrapper.layer.anchorPoint = .zero; wrapper.isUserInteractionEnabled = false
            let localBottom = members.map { liveBounds($0.0, $0.1, $0.2).maxY - root }.max() ?? 0
            wrapper.bounds = .init(x: 0, y: 0, width: viewport.width, height: max(1, localBottom))
            wrapper.layer.position = .init(x: 0, y: root)
            exits.addSubview(wrapper); ghostWrappers[blockID] = wrapper
            ghostLedger.insert(.init(id: blockID, root: root, localTop: 0, localBottom: localBottom, members: members.count))
            newGhostRanges[blockID] = first.0.index..<(members.last!.0.index + 1)
            animations.bind(.block(blockID), layer: wrapper.layer)
            for (row, id, view) in members {
                let owner = AnimationOwner.row(id)
                let frozen = liveBounds(row, id, view)
                let y = frozen.minY - root
                let height = animations.value(owner, .height, at: time), width = animations.value(owner, .width, at: time)
                let opacity = animations.value(owner, .opacity, at: time)
                animations.unbind(owner, removeModel: true)
                view.onContentDidChange = nil; wrapper.addSubview(view)
                view.place(in: .init(x: frozen.minX, y: y, width: width, height: height))
                view.layer.opacity = 0
                serial += 1; let exitID = serial
                ghostMembers[id] = blockID
                ghostExitOwners[blockID, default: []].append(.exit(exitID))
                animations.bind(.exit(exitID), layer: view.layer)
                animations.replace(.exit(exitID), .opacity, from: opacity, to: 0, at: time, transition: transition) { [weak self, weak view] in
                    guard let self else { return }
                    view?.removeFromSuperview(); animations.unbind(.exit(exitID), removeModel: true)
                    ghostLedger.finishMember(blockID); ghostMembers.removeValue(forKey: id)
                    for removed in ghostLedger.collect() {
                        ghostWrappers.removeValue(forKey: removed)?.removeFromSuperview()
                        ghostExitOwners.removeValue(forKey: removed)
                        animations.unbind(.block(removed), removeModel: true)
                    }
                }
            }
        }
    }

    private func updateGhosts(anchorY: Double?, time: Double, transition: ListTransition) {
        let base = origin - settledWindow.minY
        let live = Dictionary(uniqueKeysWithValues: settledWindow.rows.map { (items[$0.index].identity, (base + $0.y)...(base + $0.maxY)) })
        let lookup = identityIndices
        let moved = Set(passDiff.moves.map(\.new))
        let inserted = Set(passDiff.inserts).subtracting(moved)
        for (id, range) in newGhostRanges.sorted(by: { $0.key < $1.key }) {
            guard let block = ghostLedger.blocks[id] else { continue }
            let predecessor = (0..<range.lowerBound).reversed().first { passDiff.survivors[$0] != nil }
            let ordinal = predecessor.flatMap { passDiff.survivors[$0] }.map { $0 + 1 } ?? 0
            if items.indices.contains(ordinal), !moved.contains(ordinal), let boundary = live[items[ordinal].identity] {
                let topWeld = inserted.contains(ordinal) || abs(boundary.lowerBound - block.root) <= 1e-6
                ghostLedger.link(id, to: .row(items[ordinal].identity, .top), edge: topWeld ? .top : .bottom)
                if inserted.contains(ordinal) { ghostLedger.seal(id) }
            } else if ordinal == items.count, let last = settledWindow.rows.last, let boundary = live[items[last.index].identity] {
                _ = boundary
                ghostLedger.link(id, to: .row(items[last.index].identity, .bottom), edge: .top)
            }
        }
        newGhostRanges.removeAll()
        for block in ghostLedger.blocks.values.sorted(by: { $0.id < $1.id }) {
            if block.viewportAnchored { continue }
            if block.boundaryOpen, let occupant = settledWindow.rows.first(where: { inserted.contains($0.index) && abs(base + $0.y - block.root) <= 1e-6 }) {
                ghostLedger.link(block.id, to: .row(items[occupant.index].identity, .top), edge: .top)
                ghostLedger.seal(block.id); continue
            }
            var migrate = block.witness == .unresolved
            if case .row(let id, let edge) = block.witness {
                if let carrier = ghostMembers[id], let target = ghostLedger.blocks[carrier], carrier != block.id {
                    let carrierBoundary = target.root + (edge == .top ? target.localTop : target.localBottom)
                    let ownBoundary = block.root + (block.edge == .top ? block.localTop : block.localBottom)
                    if abs(carrierBoundary - ownBoundary) <= 1e-6, ghostLedger.link(block.id, to: .block(carrier, edge), edge: block.edge) { continue }
                }
                if live[id] == nil || lookup[id].map({ moved.contains($0) }) == true { migrate = true }
            }
            guard migrate else { continue }
            let above = (anchorY ?? block.root) < block.root
            let candidates = settledWindow.rows.filter { above ? base + $0.maxY <= block.root + 1e-6 : base + $0.y >= block.root - 1e-6 }
            if let nearest = candidates.min(by: { abs(base + (above ? $0.maxY : $0.y) - block.root) < abs(base + (above ? $1.maxY : $1.y) - block.root) }) {
                ghostLedger.link(block.id, to: .row(items[nearest.index].identity, above ? .bottom : .top), edge: above ? .top : .bottom)
            }
        }
        for (id, target) in ghostLedger.targets(rows: live) {
            guard let block = ghostLedger.blocks[id], let wrapper = ghostWrappers[id] else { continue }
            wrapper.layer.position.y = target
            animations.transition(.block(id), .positionY, old: block.root, new: target, at: time, transition: transition)
            ghostLedger.setRoot(id, target)
        }
    }

    private func promoteCarousel(oldWindow: ListWindow, oldItems: [any ListRow], oldViews: [String: ListRowView], oldBase: Double, oldOffset: Double, oldCorrection: Double, newWindow: ListWindow, newOrigin: Double, newOffset: Double, target: ListScrollTarget, witness: Int?, time: Double, transition: ListTransition) {
        var stripTop = oldOriginForStrip(oldBase: oldBase, window: oldWindow) - oldOffset - oldCorrection
        var stripBottom = stripTop + oldWindow.height
        for view in carousel.subviews {
            stripTop = min(stripTop, view.frame.minY - oldCorrection)
            stripBottom = max(stripBottom, view.frame.maxY - oldCorrection)
        }
        let coordinateShift = newOffset - oldOffset
        for block in ghostLedger.blocks.values where !block.viewportAnchored {
            let top = block.root - coordinateShift - oldOffset - oldCorrection + animations.value(.block(block.id), .positionY, at: time)
            stripTop = min(stripTop, top + block.localTop); stripBottom = max(stripBottom, top + block.localBottom)
        }
        let newTop = newOrigin - newOffset
        let correction = ViewportTravel.carouselCorrection(oldStrip: stripTop...stripBottom, newStrip: newTop...(newTop + newWindow.height), forward: ViewportTravel.forward(target: target.index, witness: witness, hint: target.forward))
        for view in carousel.subviews { view.layer.position.y += correction - oldCorrection }
        for block in ghostLedger.blocks.values where !block.viewportAnchored {
            guard let wrapper = ghostWrappers[block.id] else { continue }
            ghostLedger.promoteToViewport(block.id, offset: newOffset)
            let root = (ghostLedger.blocks[block.id]?.root ?? 0) + correction - oldCorrection
            ghostLedger.setRoot(block.id, root); wrapper.layer.position.y = root; carousel.addSubview(wrapper)
            for owner in ghostExitOwners[block.id] ?? [] {
                let opacity = animations.value(owner, .opacity, at: time)
                animations.replace(owner, .opacity, from: opacity, to: 0, at: time, transition: transition)
            }
        }
        let wrapper = UIView(); wrapper.layer.anchorPoint = .zero; wrapper.isUserInteractionEnabled = false
        let oldTop = oldBase + oldWindow.minY - oldOffset - oldCorrection
        wrapper.bounds = .init(x: 0, y: 0, width: viewport.width, height: oldWindow.height)
        wrapper.layer.position = .init(x: 0, y: oldTop + correction)
        carousel.addSubview(wrapper)
        for row in oldWindow.rows {
            let id = oldItems[row.index].identity
            guard let view = oldViews[id] else { continue }
            let offset = animations.value(.row(id), .positionY, at: time)
            let height = animations.value(.row(id), .height, at: time)
            let width = animations.value(.row(id), .width, at: time)
            let opacity = animations.value(.row(id), .opacity, at: time)
            let oldPlacement = view.placementOffset(size: view.bounds.size), livePlacement = view.placementOffset(size: .init(width: width, height: height))
            animations.unbind(.row(id))
            view.onContentDidChange = nil; wrapper.addSubview(view)
            view.place(in: .init(x: view.frame.minX + oldPlacement.x - livePlacement.x, y: row.y - oldWindow.minY + offset + oldPlacement.y - livePlacement.y, width: width, height: height))
            view.layer.opacity = Float(opacity)
        }
        serial += 1; let carryID = serial
        animations.bind(.carry(carryID), layer: wrapper.layer)
        // The deadline is renewed for all strips when another carousel begins.
        for view in carousel.subviews {
            let tag = AnimationOwner.carry(UInt64(view.tag))
            if view.tag != 0 {
                animations.replace(tag, .opacity, from: 1, to: 1, at: time, transition: transition) { [weak self, weak view] in view?.removeFromSuperview(); self?.animations.unbind(tag, removeModel: true) }
            }
        }
        wrapper.tag = Int(carryID)
        // Repeated distant jumps retain a bounded tail of departing strips.
        let strips = carousel.subviews.filter { $0.tag != 0 }
        for expired in strips.dropLast(3) {
            animations.unbind(.carry(UInt64(expired.tag)), removeModel: true)
            expired.removeFromSuperview()
        }
        animations.replace(.carry(carryID), .opacity, from: 1, to: 1, at: time, transition: transition) { [weak self, weak wrapper] in wrapper?.removeFromSuperview(); self?.animations.unbind(.carry(carryID), removeModel: true) }
        targetCorrectionGeneration = animations.replace(.viewport, .viewportOffset, from: correction, to: 0, at: time, transition: transition)
    }
    private func oldOriginForStrip(oldBase: Double, window: ListWindow) -> Double { oldBase + window.minY }

    private func reservedHeights(at index: Int, in proposedItems: [any ListRow]? = nil) -> (Double, Double) {
        let items = proposedItems ?? self.items
        var top = 0.0, bottom = 0.0
        for (key, attachment) in items[index].attachments where attachment.reservesSpace {
            let previous = index > 0 ? items[index - 1].attachments[key] : nil
            let next = index + 1 < items.count ? items[index + 1].attachments[key] : nil
            let starts = previous.map { !$0.combines(with: attachment) } ?? true
            let ends = next.map { !attachment.combines(with: $0) } ?? true
            if attachment.edge == .top && starts || attachment.edge == .bottom && ends {
                let probe = attachment.makeView(); attachment.apply(to: probe, transition: .immediate)
                let height = probe.update(width: viewport.contentWidth, transition: .immediate)
                if attachment.edge == .top { precondition(top == 0); top = height }
                else { precondition(bottom == 0); bottom = height }
            }
        }
        return (top, bottom)
    }

    private func attachmentSnapshot(offset: Double, correction: Double) -> [UInt64: AttachmentSnapshot] {
        attachmentMaps.mapValues { map in
            .init(screenY: origin + map.position(offset: offset) - settledWindow.minY - offset - correction, x: viewport.insets.left, width: viewport.contentWidth, height: map.height)
        }
    }
    private func resolveAttachments(transition: ListTransition, oldItems: [any ListRow] = [], oldState: [UInt64: AttachmentSnapshot] = [:], suppressFade: Bool = false) {
        let prior = runs
        let priorMaps = attachmentMaps
        runs = AttachmentRuns.resolve(identities: identities, loaded: settledWindow.range, keys: { items[$0].attachments.keys.sorted() }, edge: { items[$1].attachments[$0]!.edge }, combines: { key, a, b in
            guard let first = items[a].attachments[key], let second = items[b].attachments[key] else { return false }
            return first.combines(with: second)
        }, prior: prior, nextSerial: &serial)
        let groups = Set(runs.compactMap { descriptor($0)?.stackingGroup })
        runs.sort {
            let a = descriptor($0), b = descriptor($1)
            let rankA = a?.yieldsTo.map { groups.contains($0) ? 0 : 1 } ?? 1
            let rankB = b?.yieldsTo.map { groups.contains($0) ? 0 : 1 } ?? 1
            if rankA != rankB { return rankA < rankB }
            if $0.members.lowerBound != $1.members.lowerBound { return $0.members.lowerBound < $1.members.lowerBound }
            return $0.key < $1.key
        }
        let active = Set(runs.map(\.serial))
        for (id, view) in attachmentViews where !active.contains(id) {
            let oldRun = prior.first { $0.serial == id }
            let oldIDs = oldRun.map { run in run.members.compactMap { oldItems.indices.contains($0) ? oldItems[$0].identity : nil } } ?? []
            let silent = oldRun.map { run in oldIDs.contains { identity in identityIndices[identity].map { items[$0].attachments[run.key] != nil } ?? false } } ?? true
            if !silent, !transition.isImmediate, let snapshot = oldState[id] {
                departAttachment(view, serial: id, snapshot: snapshot, memberIDs: oldIDs, transition: transition, suppressFade: suppressFade)
            } else { view.removeFromSuperview(); animations.unbind(.attachment(id), removeModel: true) }
            attachmentViews.removeValue(forKey: id); attachmentMaps.removeValue(forKey: id); attachmentFlightSignatures.removeValue(forKey: id)
        }
        var rawMaps: [UInt64: AttachmentMap] = [:]
        for run in runs {
            guard let attachment = descriptor(run) else { continue }
            let view = attachmentViews[run.serial] ?? attachment.makeView()
            let fresh = attachmentViews[run.serial] == nil
            attachment.apply(to: view, transition: fresh ? .immediate : transition)
            let oldHeight = view.bounds.height
            let height = view.update(width: viewport.contentWidth, transition: fresh ? .immediate : transition)
            attachmentViews[run.serial] = view
            attachmentsHost.addSubview(view)
            animations.bind(.attachment(run.serial), layer: view.layer)
            if fresh { animations.seed(.attachment(run.serial), width: viewport.contentWidth, height: height) }
            else { animations.transition(.attachment(run.serial), .height, old: oldHeight, new: height, at: animations.now, transition: transition) }
            view.onContentDidChange = { [weak self] animated in self?.markDirty("attachment:\(run.serial)", animated: animated) }
            let members = settledWindow.rows.filter { run.members.contains($0.index) }
            guard let first = members.first else { continue }
            var low = first.y
            var bottom = members.map { $0.maxY - (attachment.spansMemberInsets ? 0 : (views[items[$0.index].identity]?.attachmentBandTrim ?? 0)) }.max() ?? first.maxY
            if attachment.reservesSpace {
                if run.edge == .top && run.startsRun { low -= first.reservedTop }
                if run.edge == .bottom && run.endsRun { bottom += members.last?.reservedBottom ?? 0 }
            }
            rawMaps[run.serial] = .init(low: low, high: bottom - height, height: height, edge: attachment.edge, floating: attachment.floating, screenAnchor: attachment.edge == .top ? viewport.insets.top : viewport.height - viewport.insets.bottom - height, contentBase: origin - settledWindow.minY)
        }
        attachmentMaps = rawMaps
        for run in runs {
            guard let item = descriptor(run), let group = item.yieldsTo, var map = rawMaps[run.serial] else { continue }
            map.partners = runs.filter { $0.serial != run.serial && descriptor($0)?.stackingGroup == group }.compactMap { rawMaps[$0.serial] }
            map.gap = item.yieldGap; attachmentMaps[run.serial] = map
        }
        for run in runs where priorMaps[run.serial] != attachmentMaps[run.serial] { attachmentFlightSignatures.removeValue(forKey: run.serial) }
        let time = animations.now
        let nextState = attachmentSnapshot(offset: engine.offset, correction: animations.value(.viewport, .viewportOffset, at: time))
        for run in runs {
            let owner = AnimationOwner.attachment(run.serial)
            guard let next = nextState[run.serial] else { continue }
            if let old = oldState[run.serial] {
                animations.transition(owner, .positionY, old: old.screenY, new: next.screenY, at: time, transition: transition)
                animations.transition(owner, .positionX, old: old.x, new: next.x, at: time, transition: transition)
                animations.transition(owner, .width, old: old.width, new: next.width, at: time, transition: transition)
            } else if !suppressFade, !transition.isImmediate,
                      run.members.contains(where: { passDiff.inserts.contains($0) || scheduler.dirty.contains(items[$0].identity) }) {
                animations.replace(owner, .opacity, from: 0, to: 1, at: time, transition: transition)
            }
        }
    }
    private func departAttachment(_ view: ListAttachmentView, serial attachmentID: UInt64, snapshot: AttachmentSnapshot, memberIDs: [String], transition: ListTransition, suppressFade: Bool) {
        let time = animations.now, oldOwner = AnimationOwner.attachment(attachmentID)
        let y = snapshot.screenY + engine.offset + animations.value(.viewport, .viewportOffset, at: time) + animations.value(oldOwner, .positionY, at: time)
        let opacity = animations.value(oldOwner, .opacity, at: time)
        animations.unbind(oldOwner, removeModel: true); view.layer.removeAnimation(forKey: "ultraview.attachment.flight")
        let groupIDs = Set(memberIDs.compactMap { ghostMembers[$0] })
        let blockID = groupIDs.count == 1 && memberIDs.allSatisfy({ ghostMembers[$0] != nil }) ? groupIDs.first : nil
        var localY = y
        if let blockID, let block = ghostLedger.blocks[blockID], let wrapper = ghostWrappers[blockID] {
            localY -= block.root; wrapper.addSubview(view)
            ghostLedger.addMember(blockID, localTop: localY, localBottom: localY + snapshot.height)
        } else { exits.addSubview(view) }
        view.place(in: .init(x: snapshot.x, y: localY, width: snapshot.width, height: snapshot.height))
        view.layer.opacity = 0; serial += 1; let owner = AnimationOwner.exit(serial)
        if let blockID { ghostExitOwners[blockID, default: []].append(owner) }
        animations.bind(owner, layer: view.layer)
        animations.replace(owner, .opacity, from: opacity, to: suppressFade ? opacity : 0, at: time, transition: transition) { [weak self, weak view] in
            guard let self else { return }; view?.removeFromSuperview(); animations.unbind(owner, removeModel: true)
            if let blockID {
                ghostLedger.finishMember(blockID)
                for id in ghostLedger.collect() {
                    ghostWrappers.removeValue(forKey: id)?.removeFromSuperview(); ghostExitOwners.removeValue(forKey: id)
                    animations.unbind(.block(id), removeModel: true)
                }
            }
        }
    }
    private func descriptor(_ run: AttachmentRun) -> (any ListAttachment)? {
        let index = run.edge == .top ? run.members.lowerBound : run.members.upperBound - 1
        guard items.indices.contains(index) else { return nil }; return items[index].attachments[run.key]
    }
    private func renderAttachments() {
        deferredAttachmentRender = false
        attachmentsHost.frame = container.frame
        let flight = engine.activeFlight, solveOffset = flight?.settledOffset ?? engine.offset
        var ownership: [String: [UIView]] = [:]
        CATransaction.begin(); CATransaction.setDisableActions(true)
        for run in runs {
            guard let map = attachmentMaps[run.serial], let view = attachmentViews[run.serial] else { continue }
            let y = map.position(offset: solveOffset)
            view.place(in: .init(x: viewport.insets.left, y: y - settledWindow.minY, width: viewport.contentWidth, height: map.height))
            attachmentsHost.bringSubviewToFront(view)
            view.stickDistanceUpdated(map.stickDistance(offset: engine.offset))
            let candidates = settledWindow.rows.filter { run.members.contains($0.index) }
            if let owner = candidates.max(by: { min($0.maxY, y + map.height) - max($0.y, y) < min($1.maxY, y + map.height) - max($1.y, y) }), items.indices.contains(owner.index), min(owner.maxY, y + map.height) > max(owner.y, y) {
                ownership[items[owner.index].identity, default: []].append(view)
            }
            if let flight, attachmentFlightSignatures[run.serial] != flight {
                let values = map.flightValues(flight)
                if values.contains(where: { abs($0) > 1e-9 }) {
                    let animation = CAKeyframeAnimation(keyPath: "position.y")
                    animation.isAdditive = true; animation.calculationMode = .linear
                    animation.values = values; animation.keyTimes = flight.trajectory.keyTimes.map { NSNumber(value: $0) }
                    animation.duration = flight.trajectory.duration; animation.beginTime = flight.beginTime
                    animation.fillMode = .backwards
                    view.layer.add(animation, forKey: "ultraview.attachment.flight")
                } else { view.layer.removeAnimation(forKey: "ultraview.attachment.flight") }
                attachmentFlightSignatures[run.serial] = flight
            } else if flight == nil { view.layer.removeAnimation(forKey: "ultraview.attachment.flight"); attachmentFlightSignatures.removeValue(forKey: run.serial) }
        }
        CATransaction.commit()
        for (id, view) in views { view.attachedViewsUpdated(ownership[id] ?? []) }
    }
}
#endif