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
    private var speculativeKeys: Set<MeasurementKey> = []
    private var speculativeRequests: [(item: any ListRow, key: MeasurementKey, width: Double)] = []
    private var pendingTarget: ListScrollTarget?
    private var pendingScroll: (@MainActor () -> Void)?
    private var pendingDisplayViews: [MeasurementKey: ListRowView] = [:]
    private var pendingDisplayRequired: Set<MeasurementKey> = []
    private var pendingDisplayMeasurements: Set<MeasurementKey> = []
    private var pendingDisplayGeneration: UInt64 = 0
    private var pendingItems: [any ListRow]?
    private var pendingIdentityIndices: [String: Int] = [:]
    private var unavailableMeasurements: Set<MeasurementKey> = []
    private var measurementFailures: [MeasurementKey: Int] = [:]
    private struct InsertedBlock {
        var identities: Set<String>
        var edge: BoundaryEdge
        var transition: ListTransition
    }
    private struct PreparedMutation {
        var items: [any ListRow]
        var size: CGSize?
        var insets: ListInsets?
        var viewportRequest: UInt64
        var target: ListScrollTarget?
        var targetIdentity: String?
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
    private var pinnedIndex: Int?
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
        engine.didTouchDown = { [weak self] in self?.holdsPinnedRow = false }
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
    public override func handleDragBegin() { holdsPinnedRow = false; super.handleDragBegin() }
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
    /// Lands only the viewport correction at its model value, keeping any engine
    /// flight running. Does nothing when no viewport correction is animating.
    public func finishViewportTransition() {
        guard animations.model.tracks[.init(.viewport, .viewportOffset)] != nil else { return }
        animations.replace(.viewport, .viewportOffset, from: 0, to: 0, at: animations.now, transition: .none)
        renderAttachments(); reportVisibility()
    }

    /// All options are captured intact if a callback re-enters the pass.
    public func applyChanges(items newItems: [any ListRow]? = nil, newSize: CGSize? = nil, newInsets: ListInsets? = nil, scrollTo: ListScrollTarget? = nil, additionalScrollDistance: Double = 0, anchorMode: ListAnchorMode = .automatic, compensatesInsetChange: Bool = true, absorbsEdgeChangeIntoOverscroll: Bool = false, animatesInsertions: Bool = true, transition requestedTransition: ListTransition = .default) {
        let preparedMutation = applyingPreparedMutation
        applyingPreparedMutation = false
        let transition = requestedTransition.inheritsDefault ? (newItems == nil ? .immediate : defaultTransition) : requestedTransition
        if passing {
            deferred.append { [weak self] in self?.applyChanges(items: newItems, newSize: newSize, newInsets: newInsets, scrollTo: scrollTo, additionalScrollDistance: additionalScrollDistance, anchorMode: anchorMode, compensatesInsetChange: compensatesInsetChange, absorbsEdgeChangeIntoOverscroll: absorbsEdgeChangeIntoOverscroll, animatesInsertions: animatesInsertions, transition: transition) }
            return
        }
        if !preparedMutation, newSize != nil || newInsets != nil { viewportRequest &+= 1 }
        if newItems == nil, newSize == nil, let newInsets, scrollTo == nil, additionalScrollDistance == 0,
           newInsets.left == viewport.insets.left, newInsets.right == viewport.insets.right,
           !absorbsEdgeChangeIntoOverscroll, !settledWindow.rows.isEmpty {
            updateViewportInsets(newInsets, compensates: compensatesInsetChange, transition: transition)
            return
        }
        if let newItems, !preparedMutation {
            if newItems.isEmpty {
                preparationQueue.removeAll(); pendingBlockAnimations.removeAll()
                pendingScroll = nil; pendingTarget = nil
            }
            let mutation = PreparedMutation(items: newItems, size: newSize, insets: newInsets, viewportRequest: viewportRequest,
                target: scrollTo, targetIdentity: scrollTo.flatMap { newItems.indices.contains($0.index) ? newItems[$0.index].identity : nil },
                additionalDistance: additionalScrollDistance, anchorMode: anchorMode, compensates: compensatesInsetChange,
                absorbsOverscroll: absorbsEdgeChangeIntoOverscroll, animatesInsertions: animatesInsertions, transition: transition)
            preparationQueue.submit(mutation, waiting: [], merge: Self.mergePreparedMutations)
            drainPreparedMutations()
            return
        }
        passing = true; appliedPassCount &+= 1
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
        if let scrollTo, scrollTo.index == pinnedIndex { holdsPinnedRow = true }
        let target = scrollTo ?? pendingTarget
        var reconciled = dirty
        for (identity, view) in oldViews {
            guard let newIndex = newLookup[identity], let oldIndex = oldLookup[identity] else { continue }
            if !items[newIndex].isEqual(to: oldItems[oldIndex]) {
                items[newIndex].apply(to: view, transition: transition); reconciled.insert(identity)
            }
        }
        guard !items.isEmpty, viewport.contentWidth > 0, viewport.height > 0 else {
            recordPendingTarget(items.isEmpty ? nil : target, distance: additionalScrollDistance)
            // A newer target replaces the retry too, or a flush would revive the old one.
            if items.isEmpty { pendingScroll = nil }
            else if let scrollTo {
                pendingScroll = { [weak self] in
                    self?.applyChanges(scrollTo: scrollTo, additionalScrollDistance: additionalScrollDistance, anchorMode: anchorMode, compensatesInsetChange: compensatesInsetChange, absorbsEdgeChangeIntoOverscroll: absorbsEdgeChangeIntoOverscroll, animatesInsertions: animatesInsertions, transition: transition)
                }
            }
            clearPendingDisplayViews()
            engine.halt()
            for (identity, view) in views { view.visibleRectUpdated(nil); view.removeFromSuperview(); animations.unbind(.row(identity), removeModel: true) }
            views.removeAll(); settledWindow = .init(); origin = 0
            for (id, view) in attachmentViews { view.removeFromSuperview(); animations.unbind(.attachment(id), removeModel: true) }
            attachmentViews.removeAll(); attachmentMaps.removeAll(); attachmentFlightSignatures.removeAll()
            for (id, carry) in carried { carry.view.removeFromSuperview(); animations.unbind(.row(id), removeModel: true) }
            carried.removeAll(); carryGenerations.removeAll()
            for id in ghostWrappers.keys { animations.unbind(.block(id), removeModel: true) }
            for owners in ghostExitOwners.values { for owner in owners { animations.unbind(owner, removeModel: true) } }
            for view in ghostWrappers.values { view.removeFromSuperview() }
            ghostWrappers.removeAll(); ghostExitOwners.removeAll(); ghostMembers.removeAll(); ghostLedger = .init(); newGhostRanges.removeAll()
            for view in carousel.subviews { animations.unbind(.carry(UInt64(max(0, view.tag))), removeModel: true); view.removeFromSuperview() }
            preparations.removeAll(); measurements.invalidate(); preparationKeys.removeAll()
            speculativeRequests.removeAll(); speculativeKeys.removeAll()
            for task in measurementTasks.values { task.cancel() }
            measurementTasks.removeAll(); measurementTickets.removeAll()
            engine.setEdges(.init(minimum: 0, maximum: 0)); engine.setOffset(0)
            runs.removeAll(); renderAttachments(); return
        }
        let visible = oldWindow.rows.firstIndex { oldBase + $0.maxY > oldSettled + (anchorMode == .preserveVisibleContent ? oldViewport.insets.top : 0) } ?? max(0, oldWindow.rows.count - 1)
        let witnessOrder = Array(oldWindow.rows.dropFirst(visible)) + Array(oldWindow.rows.prefix(visible).reversed())
        var survivor = witnessOrder.first { oldItems.indices.contains($0.index) && newLookup[oldItems[$0.index].identity] != nil }
        if anchorMode == .automatic, oldWindow.rows.indices.contains(visible), newLookup[oldItems[oldWindow.rows[visible].index].identity] == nil {
            survivor = oldWindow.rows.prefix(visible).reversed().first { newLookup[oldItems[$0.index].identity] != nil } ?? survivor
        }
        let atTop = oldWindow.range.lowerBound == 0 && abs(oldSettled - (declaredEdges.minimum ?? .infinity)) < 1e-6
        let pinsTop = target == nil && !holdsPinnedRow && anchorMode == .automatic && atTop && additionalScrollDistance == 0
        var anchor = 0
        if let target { anchor = min(max(0, target.index), items.count - 1) }
        else if holdsPinnedRow, let pinnedIndex { anchor = pinnedIndex }
        else if pinsTop { anchor = 0 }
        else if let survivor { anchor = newLookup[oldItems[survivor.index].identity]! }
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
        let updatedSlack = oldWindow.pinSlack(index: pinnedIndex, viewport: viewport)
        let newWindow = ListWindow.build(count: items.count, anchor: anchor, viewport: viewport, margin: preloadMargin, pinnedIndex: pinnedIndex, pinsLoadedTop: pinsTop || (oldWindow.rows.isEmpty && target == nil && !holdsPinnedRow), slackBaseline: (!holdsPinnedRow && target == nil && anchor < (pinnedIndex ?? -1)) ? updatedSlack : nil, measure: measure) { height in
            if let target { return viewport.insets.top + additionalScrollDistance + target.resolve(height, measuredViews[items[anchor].identity]) }
            if holdsPinnedRow, anchor == pinnedIndex {
                return viewport.insets.top + viewport.visibleHeight + max(0, height - viewport.visibleHeight / 2) - height + additionalScrollDistance
            }
            let fixed = survivor.map { oldBase + $0.y - oldSettled } ?? viewport.insets.top
            return fixed + (compensatesInsetChange ? viewport.insets.top - oldViewport.insets.top + updatedSlack - oldSlack : 0) + additionalScrollDistance
        }
        guard !newWindow.rows.isEmpty else {
            recordPendingTarget(target, distance: additionalScrollDistance)
            if let scrollTo {
                pendingScroll = { [weak self] in
                    self?.applyChanges(scrollTo: scrollTo, additionalScrollDistance: additionalScrollDistance, anchorMode: anchorMode, compensatesInsetChange: compensatesInsetChange, absorbsEdgeChangeIntoOverscroll: absorbsEdgeChangeIntoOverscroll, animatesInsertions: animatesInsertions, transition: transition)
                }
            }
            if !oldWindow.rows.isEmpty {
                if changesCollection || displaces || target == nil {
                    pendingItems = items; pendingIdentityIndices = identityIndices
                }
                items = oldItems; identities = oldIDs; identityIndices = oldLookup; pinnedIndex = oldPinnedIndex
            }
            else { declaredEdges = .init(); engine.setEdges(declaredEdges) }
            return
        }
        pendingTarget = nil; pendingScroll = nil
        let nextIDs = Set(newWindow.rows.map { items[$0.index].identity })
        let shared = oldWindow.rows.filter { nextIDs.contains(oldItems[$0.index].identity) }
        let isCarousel = target != nil && shared.isEmpty && !oldWindow.rows.isEmpty
        let destinationNew = nextIDs.isDisjoint(with: oldIDs)
        let newOrigin = engineMode == .uiKit && target == nil && !oldWindow.rows.isEmpty
            ? oldSettled + newWindow.minY
            : engine.containerOrigin(height: newWindow.height, top: newWindow.range.lowerBound == 0, bottom: newWindow.range.upperBound == items.count)
        let newBase = newOrigin - newWindow.minY
        let newEdges = newWindow.edges(origin: newOrigin, count: items.count, viewport: viewport, pinnedIndex: pinnedIndex)
        var destination = newBase
        if target == nil && (diff.moves.isEmpty || displaces) && (oldOverscroll == 0 || displaces) { destination = newEdges.clamped(destination) }
        if target == nil { destination = absorbsEdgeChangeIntoOverscroll ? oldOffset + newOrigin - oldOrigin : destination + oldOverscroll }
        let shift = destination - oldOffset
        let reference = shared.first(where: { oldItems[$0.index].identity == survivor.map { oldItems[$0.index].identity } }) ?? shared.first
        let coordinateMap: Double
        if let reference, let newIndex = newLookup[oldItems[reference.index].identity], let next = newWindow.rows.first(where: { $0.index == newIndex }) {
            coordinateMap = newBase + next.y - oldBase - reference.y
        } else { coordinateMap = shift }
        let displacing = !isCarousel && (target != nil || displaces)
        let detachedShift = displacing ? coordinateMap : shift
        if isCarousel, transition.isImmediate, !changesCollection, !displaces, let target {
            let required = newWindow.rows.filter { newBase + $0.maxY - destination > viewport.insets.top && newBase + $0.y - destination < viewport.height - viewport.insets.bottom }
            var missing: [Int] = []
            if newWindow.range.lowerBound > 0, newBase + newWindow.minY - destination > viewport.insets.top + 0.5 { missing.append(newWindow.range.lowerBound - 1) }
            if newWindow.range.upperBound < items.count, newBase + newWindow.maxY - destination < viewport.height - viewport.insets.bottom - 0.5 { missing.append(newWindow.range.upperBound) }
            if !missing.isEmpty || required.contains(where: { measuredViews[items[$0.index].identity]?.isDisplayReady == false }) {
                recordPendingTarget(target, distance: additionalScrollDistance)
                pendingScroll = { [weak self] in
                    self?.applyChanges(scrollTo: target, additionalScrollDistance: additionalScrollDistance, anchorMode: anchorMode, compensatesInsetChange: compensatesInsetChange, absorbsEdgeChangeIntoOverscroll: absorbsEdgeChangeIntoOverscroll, animatesInsertions: animatesInsertions, transition: transition)
                }
                var staged: [MeasurementKey: ListRowView] = [:]
                for row in newWindow.rows {
                    let item = items[row.index]
                    if let view = measuredViews[item.identity] { staged[measurementKey(item, width: viewport.contentWidth)] = view }
                }
                clearPendingDisplayViews(keeping: Set(staged.values.map(ObjectIdentifier.init)))
                pendingDisplayViews = staged
                pendingDisplayRequired = Set(required.map { measurementKey(items[$0.index], width: viewport.contentWidth) })
                pendingDisplayMeasurements = Set(missing.map { measurementKey(items[$0], width: viewport.contentWidth) })
                for index in missing { requestMeasurement(index) }
                let generation = pendingDisplayGeneration
                for key in pendingDisplayRequired {
                    pendingDisplayViews[key]?.readinessObserver = { [weak self] in
                        guard let self, pendingDisplayGeneration == generation,
                              pendingDisplayMeasurements.allSatisfy({ measurements.height(for: $0) != nil }),
                              pendingDisplayRequired.allSatisfy({ pendingDisplayViews[$0]?.isDisplayReady == true }) else { return }
                        let resume = pendingScroll; pendingScroll = nil; resume?()
                    }
                }
                return
            }
        }
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
        views = measuredViews.filter { nextIDs.contains($0.key) }
        CATransaction.begin(); CATransaction.setDisableActions(true)
        container.frame = .init(x: 0, y: origin, width: viewport.width, height: max(1, settledWindow.height))
        for row in settledWindow.rows {
            let id = items[row.index].identity
            guard let view = views[id] else { continue }
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
            animations.replace(.viewport, .viewportOffset, from: oldOffset + coordinateMap + oldCorrection - engine.offset, to: 0, at: time, transition: transition)
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
            animations.setPositionLayers(.row(id), layers + (layout.map { [$0] } ?? []))
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

    /// A pass that resumes the target without its call (a layout, say) still
    /// places it where the call asked.
    private func recordPendingTarget(_ target: ListScrollTarget?, distance: Double) {
        guard let target, distance != 0 else { pendingTarget = target; return }
        pendingTarget = .init(index: target.index, forward: target.forward) { target.resolve($0, $1) + distance }
    }

    private func clearPendingDisplayViews(keeping retained: Set<ObjectIdentifier> = []) {
        pendingDisplayGeneration &+= 1
        for (key, view) in pendingDisplayViews where !retained.contains(ObjectIdentifier(view)) {
            view.readinessObserver = nil
            if views[key.identity] !== view, carried[key.identity]?.view !== view { view.removeFromSuperview() }
        }
        pendingDisplayViews.removeAll(); pendingDisplayRequired.removeAll(); pendingDisplayMeasurements.removeAll()
    }

    private func updateViewportInsets(_ insets: ListInsets, compensates: Bool, transition: ListTransition) {
        guard insets != viewport.insets else { return }
        let started = CACurrentMediaTime()
        defer { MainThreadMonitor.shared.note("list inset compensates=\(compensates) \((CACurrentMediaTime() - started) * 1000) ms") }
        passing = true
        defer {
            passing = false
            if !transition.isImmediate { handleScroll(engine.offset) }
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
        animations.replace(.viewport, .viewportOffset, from: transition.isImmediate ? 0 : oldOffset + correction - engine.offset, to: 0, at: time, transition: transition)
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
                view.visibleRectUpdated(nil); view.removeFromSuperview(); animations.unbind(.row(id)); views.removeValue(forKey: id)
            }
            let nextOrigin = engineMode == .uiKit
                ? base + settledWindow.minY
                : engine.containerOrigin(height: settledWindow.height, top: settledWindow.range.lowerBound == 0, bottom: settledWindow.range.upperBound == items.count)
            let shift = nextOrigin - settledWindow.minY - base
            origin = nextOrigin; shiftDetached(by: shift)
            engine.shift(by: shift); previousOffset = engine.offset
            CATransaction.begin(); CATransaction.setDisableActions(true)
            container.frame = .init(x: 0, y: origin, width: viewport.width, height: max(1, settledWindow.height))
            for row in settledWindow.rows {
                let id = items[row.index].identity
                guard let view = views[id] else { continue }
                carried.removeValue(forKey: id)
                carryGenerations.removeValue(forKey: id)
                if view.superview !== container { container.addSubview(view) }
                view.place(in: .init(x: viewport.insets.left, y: row.y - settledWindow.minY, width: viewport.contentWidth, height: row.height))
                view.onContentDidChange = { [weak self] animated in self?.markDirty(id, animated: animated) }
                animations.bind(.row(id), layer: view.layer)
                view.readinessObserver = { [weak self] in self?.accessibilityCoordinator.reconcile() }
                if !previous.range.contains(row.index) { animations.seed(.row(id), width: viewport.contentWidth, height: row.height) }
            }
            declaredEdges = settledWindow.edges(origin: origin, count: items.count, viewport: viewport, pinnedIndex: pinnedIndex)
            engine.setEdges(declaredEdges); resolveAttachments(transition: .immediate)
            CATransaction.commit()
        }
        if let index = settledWindow.rows.first(where: { base + $0.maxY > offset })?.index {
            let direction = engine.coveredOffsets(horizon: 0.3).map { $0.lowerBound + $0.upperBound < 2 * engine.offset ? -1 : 1 } ?? (delta < 0 ? -1 : 1)
            requestAhead(anchor: index, direction: direction)
        }
        sweepPreparations()
        renderAttachments(); reportVisibility(); super.handleScroll(engine.offset)
    }
    private static func mergePreparedMutations(_ old: PreparedMutation, _ new: PreparedMutation) -> PreparedMutation {
        var result = new
        if result.target == nil, let target = old.target {
            result.target = target; result.targetIdentity = old.targetIdentity
            result.animatesInsertions = old.animatesInsertions
            if result.additionalDistance == 0 { result.additionalDistance = old.additionalDistance }
        }
        if result.viewportRequest == old.viewportRequest {
            result.size = result.size ?? old.size; result.insets = result.insets ?? old.insets
        }
        result.blocks = old.blocks + result.blocks
        return result
    }
    private func preparedTarget(_ mutation: PreparedMutation) -> ListScrollTarget? {
        guard let target = mutation.target else { return nil }
        guard let identity = mutation.targetIdentity else { return target }
        guard let index = mutation.items.firstIndex(where: { $0.identity == identity }) else { return nil }
        return .init(index: index, forward: target.forward, resolve: target.resolve)
    }
    private func requestedPreparations(_ mutation: PreparedMutation) -> [(item: any ListRow, key: MeasurementKey, width: Double)] {
        guard !mutation.items.isEmpty else { return [] }
        let currentViewport = mutation.viewportRequest == viewportRequest
        let insets = currentViewport ? mutation.insets ?? viewport.insets : viewport.insets
        let width = max(0, (currentViewport ? mutation.size.map { Double($0.width) } ?? viewport.width : viewport.width) - insets.left - insets.right)
        guard width > 0 else { return [] }
        let witness = settledWindow.rows.first(where: { (settledFrame(at: $0.index)?.maxY ?? 0) > viewport.insets.top })
        let identity = witness.flatMap { items.indices.contains($0.index) ? items[$0.index].identity : nil }
        let anchor = preparedTarget(mutation)?.index ?? identity.flatMap { id in mutation.items.firstIndex { $0.identity == id } } ?? 0
        return MeasurementCache.priority(count: mutation.items.count, anchor: anchor, direction: 1, limit: min(80, max(24, settledWindow.rows.count + 8))).compactMap { index in
            let item = mutation.items[index], key = measurementKey(item, width: width)
            guard item.measuresAsynchronously else { return nil }
            return (item, key, width)
        }
    }
    private func drainPreparedMutations() {
        guard !passing, !drainingPreparations else { return }
        drainingPreparations = true
        defer { drainingPreparations = false }
        while !preparationQueue.isEmpty {
            preparationKeys.removeAll(keepingCapacity: true)
            for entry in preparationQueue.entries {
                let effective = entry.generation == preparationQueue.latest?.generation
                    ? preparationQueue.inFlight.map { Self.mergePreparedMutations($0.value, entry.value) } ?? entry.value
                    : entry.value
                let requests = requestedPreparations(effective)
                preparationKeys.formUnion(requests.map(\.key))
                let missing = requests.filter { measurements.height(for: $0.key) == nil && !unavailableMeasurements.contains($0.key) }
                preparationQueue.replaceWaiting(generation: entry.generation, with: Set(missing.map(\.key)))
                for request in missing { requestMeasurement(request.item, key: request.key, width: request.width) }
            }
            guard let ready = preparationQueue.takeReady(merge: Self.mergePreparedMutations) else { return }
            let mutation = ready.value, currentViewport = mutation.viewportRequest == viewportRequest
            if let target = mutation.target, let identity = mutation.targetIdentity {
                preparationQueue.updateNewest { successor in
                    if successor.target == nil, successor.items.contains(where: { $0.identity == identity }) {
                        successor.target = target; successor.targetIdentity = identity
                    }
                }
            }
            applyingPreparedMutation = true
            applyChanges(items: mutation.items, newSize: currentViewport ? mutation.size : nil, newInsets: currentViewport ? mutation.insets : nil,
                scrollTo: preparedTarget(mutation), additionalScrollDistance: mutation.additionalDistance, anchorMode: mutation.anchorMode,
                compensatesInsetChange: mutation.compensates, absorbsEdgeChangeIntoOverscroll: mutation.absorbsOverscroll,
                animatesInsertions: mutation.animatesInsertions, transition: mutation.transition)
            applyingPreparedMutation = false
            if pendingItems != nil { pendingBlockAnimations += mutation.blocks }
            else { for block in mutation.blocks { animateInsertedBlockNow(block) } }
        }
        preparationKeys.removeAll(keepingCapacity: true)
    }
    private func markDirty(_ id: String, animated: Bool) {
        if scheduler.mark(id, animated: animated) {
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                scheduler.beginFlush()
                if !scheduler.dirty.isEmpty {
                    if let retry = pendingScroll { pendingScroll = nil; retry() }
                    else { applyChanges(transition: scheduler.animated ? defaultTransition : .immediate) }
                }
            }
        }
    }
    private func requestMeasurement(_ index: Int) {
        guard items.indices.contains(index) else { return }
        let item = items[index]
        guard item.measuresAsynchronously else { return }
        let width = viewport.contentWidth
        requestMeasurement(item, key: measurementKey(item, width: width), width: width)
    }
    private func measurementKey(_ item: any ListRow, width: Double) -> MeasurementKey {
        .init(identity: item.identity, revision: item.revision, width: width, environment: measurementEnvironmentKey &+ item.measurementEnvironment &* 0x9e3779b97f4a7c15)
    }
    private func requestMeasurement(_ item: any ListRow, key: MeasurementKey, width: Double) {
        let environment = measurementEnvironment
        guard width > 0, !unavailableMeasurements.contains(key), let ticket = measurements.request(key) else { return }
        measurementTickets[key] = ticket
        measurementTasks[key] = Task { [weak self] in
            let preparation = await item.prepare(width: width, environment: environment)
            guard let self else { return }
            guard measurementTickets[key] == ticket else { return }
            measurementTickets.removeValue(forKey: key)
            measurementTasks.removeValue(forKey: key)
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
                    guard let index = identityIndices[item.identity], items[index].revision == item.revision,
                          measurementKey(items[index], width: viewport.contentWidth) == key else {
                        measurementFailures.removeValue(forKey: key); return
                    }
                    requestMeasurement(items[index], key: key, width: width)
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
        speculativeRequests = indices.compactMap { index in
            let item = items[index], key = measurementKey(item, width: viewport.contentWidth)
            guard item.measuresAsynchronously, measurements.height(for: key) == nil, measurementTasks[key] == nil else { return nil }
            return (item, key, viewport.contentWidth)
        }
        pumpSpeculativePreparations()
    }
    private func pumpSpeculativePreparations() {
        while speculativeKeys.count < 6, !speculativeRequests.isEmpty {
            let request = speculativeRequests.removeFirst()
            guard measurementTasks[request.key] == nil, measurements.height(for: request.key) == nil,
                  !unavailableMeasurements.contains(request.key) else { continue }
            requestMeasurement(request.item, key: request.key, width: request.width)
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
            preparations.removeValue(forKey: key); measurements.forget(key)
        }
    }
    private func retainsPreparation(_ key: MeasurementKey) -> Bool {
        if preparationKeys.contains(key) || pendingDisplayViews[key] != nil || pendingDisplayMeasurements.contains(key) { return true }
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
        animations.replace(.viewport, .viewportOffset, from: correction, to: 0, at: time, transition: transition)
    }
    private func oldOriginForStrip(oldBase: Double, window: ListWindow) -> Double { oldBase + window.minY }

    private func reservedHeights(at index: Int) -> (Double, Double) {
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