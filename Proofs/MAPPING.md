# Proofs: model to code

Machine-checked Lean 4 proofs of correctness and work bounds for an
algorithmic model of UltraView's pipeline, under the hypotheses below.
`scripts/proofs.sh` builds them and fails on any `sorry`, `admit`, new
`axiom`, or a theorem depending on an axiom other than Lean's `propext`,
`Classical.choice` and `Quot.sound`.

The model follows the **algorithms and invariants**, not the Swift line by
line: the same flags, caches, comparisons and keys, in the same order. The
historical table pins each model definition to the Swift **as of commit
`22e6866`**. The later review below records coverage at **`a8fc6d3`**;
it does not replace the historical mapping or establish a formal refinement
from the newer Swift to Lean. When the Swift changes, re-check the rows
whose files changed.

The cost results count specific operations in the model: visits, scheduled
passes, drawing jobs and commit entries. They do not prove minimum total
CPU work, memory traffic, latency or electrical energy. There is no hardware
energy model, compiler proof, or proof that all work is performed only once.
In particular, the text-cache bound requires at most four distinct widths,
and the newer percentage-edge repair can invoke Yoga repeatedly in one pass.

## Map

| Model (`Proofs/UltraProofs/…`) | Swift at `22e6866` |
| --- | --- |
| `Scheduling.State.needs` / `.desc` | `UltraNode.needsSync` / `descendantsNeedSync` (UltraNode.swift:26-28) |
| `Scheduling.Step.mutate`, `.walkUp`, `.walkRoot` | `UltraNode.setNeedsSync` (UltraNode.swift:295): store the flag, walk up exchanging `descendantsNeedSync`, stop at a set one, at the root `Renderer.setNeedsPass` (Renderer.swift:131) |
| `State.scheduled`, `.queued` | `Renderer.passScheduled`, the `runPass` blocks on `Pipeline.layoutQueue` |
| `Step.hostUpdate` | `Renderer.update` (Renderer.swift:107): sets the flag and always enqueues |
| `Step.start` | `Renderer.runPass` (Renderer.swift:162-164): clears `passScheduled` |
| `Step.visitA` / `.visitB` | `Renderer.sync` (Renderer.swift:244-268): exchange `needsSync`, then `descendantsNeedSync`, then visit the children |
| `Step.finish` | the rest of `runPass` (steps 2-7) |
| `Commits.Entry`, `Kind`, `Change` | `CommitEntry`, `CommitEntry.Kind`, `ContentsChange` (Commit.swift:76-127) |
| `Entry.merge` | `CommitEntry.merge` (Commit.swift:104) |
| `Commit.merge` | `Commit.merge` (Commit.swift:66) |
| `Entry.apply`, `Commit.apply` | `CommitApplier.apply`, `UltraNode.apply/ensureView/unmountView` (CommitApplier.swift:14-95) |
| `Sys.post` / `Sys.takeApply` | `CommitMailbox.post` / `take` (Commit.swift:141-160), `NodeHostView.apply` and its generation guard (NodeHostView.swift:140) |
| `Pass.Sh` | `Shadow`: `frame`, `interfaceState`, `isMounted`, `sentFrame`, `sentProps`, `contents`, `drawnKey` (Shadow.swift) |
| `Pass.IState` | `InterfaceState` (InterfaceState.swift:13) |
| `Pass.frameStep` | `Renderer.collectFrames` (Renderer.swift:360-382) |
| `Pass.transition`, `assignStep` | `Renderer.transition`, the `old != state` guard in `assignState` (Renderer.swift:398-472) |
| `Pass.evaluate` | `Renderer.evaluate` (Renderer.swift:476-525) |
| `Pass.childrenStep` | the `childrenChanged` loop (Renderer.swift:227-230) |
| `Pass.drawStep`, `Ctx.cancelled` | `Renderer.draw` (Renderer.swift:618-642), `displaySentinel` |
| `Pass.recordE` / `updateE` | `Commit.record` / `Commit.update` (Commit.swift:41-61) |
| `Ctx.synced` / `forced` / `extra` | `pass.evaluate` from `sync`; `firstPass \|\| environmentChanged`; `pass.evaluate(scroll)` when the content frame changes (Renderer.swift:371-374) |
| `Pass.Deps` | what `makeProps` / `drawingInput` read (Renderer.swift:527-590, UltraTextNode.contributeProps / contentDrawing) |
| `Walks.Reached`, `YogaContract` | `collectFrames` descending through `layout.hasNewLayout` |
| `Walks.localSt`, `spec` | `assignState` / `assignInheritedState` / `updateRanges`, `RangeTuning.state ∩ cap` |
| `Walks.IStep` | one `assignState` call: recompute from the parent, recurse on change |
| `Global.passCommit`, `Run` | `pass.commit` handed to the sink (Renderer.swift:236-239), passes in sequence |
| `Ranges.overlaps` | `RangeTuning.state`'s `overlaps(extendedBy:)` (InterfaceState.swift:47-51) |
| `Text.request`, `run` | `UltraTextNode.textLayout(fitting:)` (UltraTextNode.swift:170-193): reuse the first layout that `fits`, else build, keep four |
| `Power.Idle` | no pass running or queued, no `setNeedsSync` in flight |
| `Optimality.roundGrid` | Yoga's `roundLayoutResultsToPixelGrid` (yoga 3.2.1, PixelGrid.cpp) |

## Review at `a8fc6d3`

The following references are to files at this exact commit. This is a
source review of the changed mechanisms, not a new machine-checked proof
of the implementation. No claim here covers subsequent changes or the
separate list implementation.

| Mechanism | Swift at `a8fc6d3` | Coverage and limits |
| --- | --- | --- |
| Host-update coalescing (finding 1) | `Renderer.update` (Renderer.swift:112-123), `setNeedsPass` (135-144), `runPass` (166-170) | The atomic false-to-true guard now follows `Corrected.FixedStep.update`. `fixed_passes_le` gives the model's bound with guarded updates. The original `Scheduling.Step.hostUpdate` still describes the historical unguarded implementation; queue hops and dispatch fairness remain abstractions. |
| Sync and range scans (findings 2 and 3) | `Renderer.sync` (273-297), `updateRanges` (468-486) | Still walks children of marked ancestors and scans every scroll-content child for range updates. The dirty-queue model and contiguous-range theorem describe possible improvements, not implemented optimizations. |
| Mailbox and host waiting (finding 4) | `CommitMailbox.post` (Commit.swift:163-176), `waitForPost` (195-200), `NodeHostView.commitArrived` (NodeHostView.swift:170-175) | The host no longer blocks waiting for a commit. Signals occur only on empty-to-full transitions. This is different from `Corrected.permitsFixed`, which models signalling only with a registered waiter: background consumers that take without waiting can still accumulate semaphore permits. `fixed_spins` does not certify this implementation. |
| Rounding, moves and appearance (findings 5, 6 and 7) | `Renderer.runPassSteps` (Renderer.swift:186-215), `attach` / `detach` (348-395) | Yoga still rounds; moving a subtree still detaches, remounts and redraws it; appearance changes still force sync and text preparation. The corrected rounding and retained-move models have not been implemented here. |
| Percentage edges and other layout outputs (finding 8) | `LayoutNode.calculateLayout` (LayoutNode.swift:141-152), percentage-edge tracking (173-234), `Renderer.collectFrames` (Renderer.swift:400-434) | The wrapper invalidates stale percentage edges and retries Yoga; changed padding plus border now queues evaluation even when the frame is unchanged. This addresses the reproduced dependency gap using the mechanism required by `deps_of_inputs`. The invalidation algorithm and convergence are not proved: the retry loop has a fixed limit of three additional layout calls. Arbitrary nested or cyclic percentage dependencies remain outside the guarantee. |
| Reparenting race (finding 9) | `Renderer.attach` (Renderer.swift:348-370), `collectFrames` (432-434), `assignState` (461-464), `updateRanges` (479-485) | Removes a moved child from its former parent's shadow list and checks actual parent identity during walks. This addresses the reproduced stale-parent assignment. `Walks.assign_correct` still assumes a fixed tree and assignments from each node's actual parent; arbitrary concurrent structural changes are not proved safe. |
| Commit representation and application | `Commit.record` / `merge` (Commit.swift:43-86), `CommitQueue` (CommitQueue.swift:17-95), `CommitApplier.apply` (CommitApplier.swift:17-54), `NodeHostView.applyTurn` (NodeHostView.swift:186-214) | Per-node merge semantics remain the relevant model, but the new queue applies visible work immediately and defers offscreen mounts and unmounts. Splitting, returning remainders and merging later commits into partially applied work are not modeled by `Commits.Sys`, `Global` or `EndToEnd`. |
| Text layout cache | `UltraTextNode.textLayout(fitting:)` (UltraTextNode.swift:179-209), `updateContentForFrame` (229-236) | Retains four layouts and reuses a fitting layout. `Text.builds_le_distinct` models requests from an empty cache with fixed content and at most four distinct widths. Preparation in parallel, cache invalidation and eviction across more widths need separate reasoning. |
| Offline measurement | `NodeMeasurement.measure` / `measureNow` (NodeMeasurement.swift:14-53) | Runs an unhosted tree through a temporary renderer. Ownership handoff, measurement followed by hosting, and reuse of these caches are outside the model. Changes to this API after this commit require a separate review. |

The three regression cases in `ProvenPropertyTests.swift` are ordinary
assertions at `a8fc6d3`, following their import in `f026507` and repair in
`301f4f3`. They exercise percentage padding after a resize, text links
inside a fixed frame, and a simulated reparenting interleaving. They support
these particular repairs; they do not discharge the universal hypotheses.
The historical tests on the proof branch retain their known-issue markers.

### Consequences for the theorem claims

- `Global.run_sound` and `EndToEnd.quiescent_shows_fresh_render` apply to
  the whole-commit model. A proof for the newer host must additionally model
  deferred entries, parent availability, newer commits overtaking deferred
  work, and eventual application. An idle renderer alone is insufficient:
  the mailbox and `CommitQueue` must also have drained. Even that condition
  needs a refinement proof before the theorem can be claimed for this host.
- `Renderer.transition` (Renderer.swift:515-518) now emits visibility-only
  updates so a deferred mount can be promoted. The original
  `entry_only_if_changed` spec records frame, props, key and children, but
  not this scheduling state. Its entry-minimality result cannot be applied
  unchanged to these entries.
- `Power.idle_only_client` is a property of the scheduling model. The newer
  host has a display link while deferred work remains and pauses it once
  drained. That delivery mechanism is outside the model.
- `Power.apply_local` states that an absent entry leaves that node's value
  unchanged in a functional map. It does not bound UIKit traversal cost:
  subtree removal, sibling search, ordering and framework work can touch
  more views than the number of commit entries.
- `LayoutNode.calculateLayout` can call Yoga once initially plus up to
  three retries. Neither a single Yoga call per pipeline pass nor absence
  of repeated measurement follows for this implementation.

## Host lifetime review at `7238cbe`

`Renderer.detach()` now schedules a bitmap purge on the serial layout queue.
It checks that the root still has no renderer before clearing contents, drawing
keys, published interface state, mount state and sent properties/frames for the
shadow subtree. Layout and text caches remain available. A replacement renderer
registers synchronously before its first queued pass, so an earlier purge skips
that root. The pipeline's existing per-pass subtree `detach(_:pass:)` algorithm
is unchanged. Linux regressions cover bitmap release with retained text layout
and detachment followed by registration of a replacement host before the queued
purge runs.

The offline-measurement and host-lifetime mapping remains outside the formal
model. These tests do not establish a refinement theorem for renderer ownership,
queued purging or the list-owned preparation cache. All 57 existing theorems were
checked after this change, with no new axiom dependencies.

## List at `61ff81d`

`Proofs/UltraProofs/List/` models UltraList. The rows below pin the Swift as
of `61ff81d`, plus the commit that adds this section, which adds
`ListAnimationModel.retime(since:)`, the `restarts:` parameter of
`transition`, and `AnimationController.retime(at:transition:)`, with no call
sites yet. Coordinates are `Rat`; the Swift uses `Double`, so equalities hold
up to rounding.

| Model (`Proofs/UltraProofs/List/…`) | Swift |
| --- | --- |
| `Window.Row`, `Window` (`minY`, `maxY`, `translate`), `Viewport` | `WindowRow`, `ListWindow`, `ListViewport` (ListWindow.swift:13-47) |
| `Window.prepend`, `append`, `pinRoom`, `place`, `underfill`, `build` | `ListWindow.build` and its `prepend`/`append` helpers (ListWindow.swift:62-104) |
| `Window.pinSlack` | `ListWindow.pinSlack` (ListWindow.swift:48-52) |
| `Window.dropFront`, `dropBack`, `rebalance` | `ListWindow.rebalance` (ListWindow.swift:107-119) |
| `Diff.search`, `step`, `run`, `walk`, `kept` | `ItemDiff.init`: the binary search over `tails`, `predecessors`, the walk back from the last tail (ItemDiff.swift:12-27) |
| `Diff.survivors`, `moves` | the `kept` split into `survivors` and `moves` (ItemDiff.swift:28-32) |
| `Animation.Track`, `value`, `deadline` | `AnimationTrack` (ListAnimation.swift:108-119) |
| `Animation.Model.replace`, `transition`, `finish` | `ListAnimationModel.replace` / `transition` / `finish` (ListAnimation.swift:138-171) |
| `Animation.Model.retime`, `fixedPass` | `ListAnimationModel.retime(since:)` (ListAnimation.swift:157), `AnimationController.capturePositions` / `retime` (AnimationController.swift:42, 81) |
| `Animation.swiftPass` | the `transition`/`replace` calls of one `applyChanges` pass, all at one `time` with one transition (UltraListView.swift:207-483) |
| `Pass.screen`, `displaced_row_screen`, `kept_row_screen` | the settled-rows loop's `oldY`/`newY` (UltraListView.swift:465-466) and the viewport replace (431) |
| `Pass.detached_jump`, `scroll_carry_jumps` | `shiftDetached(by: shift)`, `makeDepartures(coordinateShift: shift)`, the carried placement and the crossing samples (UltraListView.swift:395, 400, 406, 439) |
| `Pass.compensated`, `inset_moves_content`, `inset_top_pinned` | `build`'s `resolveY` with `compensatesInsetChange` (UltraListView.swift:352) |
| `Pass.containerOrigin` | `ScrollCore.containerOrigin` (ScrollCore.swift:52) |

**Gaps at `61ff81d`, reproduced in `Tests/UltraViewUIKitTests/ListSyncTests.swift`**
(known issues until the call sites land):

1. `detached_jump`: in a displacing pass (a target, a size or inset change in
   the full pass, an additional scroll distance) carries and departure
   blocks move by `shift` while the viewport track starts from
   `coordinateMap`, so they jump by `shift - coordinateMap`. Simulator: row 0
   of a 320 × 400 list goes from 0 to 300 on `scrollTo(index: 3)`, as
   `scroll_carry_jumps` computes. The fix moves them by `coordinateMap` in a
   displacing pass (`detached_fixed`, `scroll_carry_fixed`) and gives the
   rigid carry a track for the pass (`restarts:`), since a no-op transition
   would end it at once.
2. `kept_track_desyncs`: `transition`'s settled no-op keeps a track on the
   previous pass's timing while its neighbours restart. Simulator: two rows
   overlap by 50 points. The fix is `retime` at the end of every animated
   pass that started a track (`fixed_one_timeline`, `fixed_pass_sync`,
   `fixed_scenario_touches`); `swiftPass_started` shows the Swift's
   generation guard is the model's condition.

**Not covered.** `updateViewportInsets` (UltraListView.swift:486-514), the
inset-only path, shifts the engine and the viewport track only; the
inset theorems model the full pass's `resolveY`, not this path. Its
viewport-only motion is common to everything in the content view, which
the tests `contentFollowsAnInsetChangeInOnePass` and
`contentMovesWithAnAnimatedInsetChange` check on screen. `CrossingPlanner`,
attachments, the carousel, ghosts' geometry, measurement scheduling and the
scroll physics are not modeled. `lockstep_iff` states when content and an
animated input stay together; that the host passes the keyboard's curve and
duration is a hypothesis.

## List integration review at `ddf8cb5`

The call sites for the two gaps above are now integrated. Displacing full
passes move detached rows and departure geometry by `coordinateMap`, restart
rigid carries, and retime kept geometry after creating the pass's tracks.
`ListSyncTests` checks the carried row's start and midpoint and that touching
rows remain touching during a second resize. These are ordinary assertions.
Retiming excludes existing viewport motion, which is common to all rows and
must keep the input's timing, and opacity, whose completion deadline must not
be extended by ongoing geometry changes. Two further simulator tests pin
preservation of an existing viewport spring and opacity deadline. The generic
retiming model remains broader than this selection policy; it does not prove
the controller's filtering or callbacks correct.

The `Window.dropFront` / `dropBack` / `rebalance` mapping was rechecked.
`ListWindow.rebalance` now accepts a temporal coverage interval and an optional
budget for added rows. It still removes only end rows and adds linked rows
only through prepend/append, preserving the structural hypotheses of
`rebalance_keeps`. The budget can stop before filling the requested extent.
The theorem does not guarantee coverage of a future viewport, content
readiness, finite-edge playback or a frame/CPU budget. Exact-value Swift tests
check the interval envelope, row budget and missing-measurement frontier;
simulator tests check release-turn mounting and finite-edge discovery.

All 98 theorems pass at this review. The scroll driver, opacity lifetime,
render-server playback and keyboard integration remain outside the model.

Integration rechecked at `bc756b6`: `applyChanges` also keeps a scroll target
requested before the first layout through `pendingTarget` in the zero-viewport
guard. The List models cover passes with non-empty items and a positive
viewport. Retaining a target before layout, then resolving it, is outside
them; the UIKit first-layout test checks this behavior. Prepared mutations
also carry a still-present identity target to a pending successor when the
older preparation finishes first. The preparation queue and its target policy
remain outside these models.

## Immediate passes and retiming's selection at `8afead2`

These rows pin `8afead2` plus the commit that adds this section.

| Model (`Proofs/UltraProofs/List/Animation.lean`) | Swift |
| --- | --- |
| `Model.transitionNow`, `nowPass` | `ListAnimationModel.transition`'s immediate branch (ListAnimation.swift:153-161): opacity lands at once; an additive key in flight keeps its track; an absolute key in flight moves its track by the change unless an end would go below zero; otherwise `replace` |
| a moved track keeps its timing | `AnimationController.transition` reinstalls it at the running animation's `beginTime` (AnimationController.swift:62-68) |
| `Model.retime`'s `incl` | `AnimationController.retime`'s `including:` (AnimationController.swift:87-88): a bound layer, not `.viewport`, not `.opacity` |

`fixed_one_timeline` and `fixed_pass_sync` now hold over the accepted keys, and
`fixed_keeps_excluded` shows retiming leaves the others unchanged.
`common_mode_cancels` is the reason the viewport may keep its own timing: a
relation between content positions whose coefficients sum to zero does not
depend on it. The model still does not cover completions, layer binding or
`resumeValue`'s presentation snapshots.

**Gap, fixed in the same commit.** `immediate_desyncs`: an immediate change
mid-slide (a row measured again during an insertion slide, flushed with
`.immediate`) landed the keys whose settled value changed and left the rest
sliding. The model gives 50 points between two rows at the pass and 25 at
0.75 s. `touchingRowsKeepTouchingWhenARowGrowsImmediatelyMidSlide` reproduced
it on main (100, 75 and 50 points at 0.5, 0.75 and 1 s of a 1 s slide; the
stopped test clock starts the first slide when the test flushes, so the gap
it reads is larger). With `transitionNow` the rows touch throughout:
`now_shifts` shifts every shown value by exactly its settled change, and
`now_keeps_relations` carries any relation the settled values keep. Where a
size would go below zero the key lands at once (`aGrowingRowSetImmediatelyToZeroNeverHasANegativeHeight`);
then `now_nonneg` does not apply and the relation can break for the rest of
that slide. `now_nonneg` needs a curve that does not overshoot.

## Inset-only path at `76bac32`

`Proofs/UltraProofs/List/Insets.lean` models `updateViewportInsets`
(UltraListView.swift:496-526), which handles an inset change that touches
nothing else without a full pass, and `ListWindow.rebalance` with its
covered offsets (ListWindow.swift:107-123).

| Model (`Proofs/UltraProofs/List/Insets.lean`) | Swift |
| --- | --- |
| `Edges`, `clamp` | `ScrollEdges`, `clamped` (ScrollMath.swift:11-14) |
| `edgesAt` | `ListWindow.edges` with `origin = base + minY` (ListWindow.swift:53-59) |
| `move` | `resolveY`'s `compensatesInsetChange` term, `Δtop + updatedSlack − oldSlack` (UltraListView.swift, `build`'s closure) |
| `fullPass` | the full pass for an inset change: rigid rebuild (`ListPass.rigid`), `destination = newEdges.clamped(newBase) + oldOverscroll` |
| `cheapSwift` | `updateViewportInsets`'s `shift = oldTop − newTop` with `compensates` (UltraListView.swift:515) |
| `cheapFixed` | the proposed destination: `clamp(new, clamp(old, offset) − move) + overscroll` |
| `rebalanceIn` | `ListWindow.rebalance` with `low = min(offset, covered.lower) − margin`, `high = max(offset, covered.upper) + vh + margin`; fuel stands for the row budget |

- `cheap_eq_full`: with `compensates`, every row is drawn where the full pass
  draws it exactly when the inset-only path moves the offset to `cheapFixed`.
  `cheapFixed_settled`: settled content stays settled.
  `uncompensated_keeps_offset`: without `compensates` the offset is left alone
  and overscroll is the engine's to return (the keyboard's detached-gesture
  rule).
- `rebalanceIn_keeps_covered`, `track_in_hull`: if the viewport track's
  progress stays in `[lo, hi]`, covering the offsets it shows at `lo` and `hi`
  keeps every row it shows at any time, whatever the budget adds. The
  progress bound is a hypothesis: `[0, 1]` for curves that do not overshoot,
  wider for springs and Bézier curves with control points outside it.

**Gaps at `76bac32`** (the Swift at `bc756b6` is the same apart from timing
instrumentation; repros and fixes are with the list implementation):

1. `cheap_swift_overscrolls`: the inset-only path moves by the inset change
   alone, ignoring the pin slack and the edges. A short list with its last row
   pinned, gaining a 100-point top inset, ends 100 points past its top edge;
   content at its end losing a 252-point top inset ends 252 points past it.
   Both then bounce back. `cheapFixed` leaves both in place.
2. `inset_drops_shown`: after the change, `rebalance` covers only the final
   offset and the engine's flight, while the viewport track still shows the
   content where it was. A change larger than the preload margin drops rows
   on screen at its start: with 50-point rows and a 252-point inset, row 7,
   whose band `[350, 400]` is on screen. The full pass drops the same rows,
   since it carries outgoing rows only for a target or a row mutation.

**Not covered.** The `holdsPinnedRow` branch (the pinned row's boundary
formula) is outside `cheap_eq_full`. The momentum flight, the engine bounce
and the render server's timing are outside the model.

Integration review at `d672151`: with compensation enabled and no held pin,
`updateViewportInsets` now uses the `cheapFixed` destination, including both
the inset and pin-slack changes, the new-edge clamp, and the old overscroll.
Without compensation it leaves the offset unchanged. The held-pin boundary
branch remains unchanged and outside `cheap_eq_full`.

`handleScroll` adds the flight coverage to the whole viewport track's
`valueBounds`, as modeled by `track_in_hull` and
`rebalanceIn_keeps_covered`. `ListCurve.progressBounds` supplies `[0, 1]` for
standard curves, `[0, 2]` for springs starting at rest, and the cubic hull of
the endpoints and vertical control points for a custom Bézier curve. The
curve bounds are still hypotheses of the Lean theorem; Linux tests check
sampled curves and exact bounds, including simultaneous scroll and viewport
motion. Full passes also retain outgoing shared rows
during viewport displacement. Simulator regressions check both paths, pin
slack, compensated edge clamping and uncompensated offset preservation.

`sum_covers` is the bound `handleScroll` computes at `b5667e5`
(UltraListView.swift:551-557): `AnimationTrack.adding(to:)` adds the viewport
track's `valueBounds` to the engine's flight range (or to the current offset
when nothing is in flight), the sum of the two ranges. `hull_misses`: their
hull is not enough, since a 100-point flight under a 252-point viewport delta
shows offset 352.

## Preparation queue and sent rows at `b5667e5`

Integration review after `e12559b`: engine flight callbacks during
`UltraListView.applyChanges`, `updateViewportInsets` or `handleScroll` defer
attachment rendering until row and run state is consistent. The attachment
owner lookup also checks its item index. These callback and UIKit lifetime
boundaries are outside the rational geometry model; simulator regressions
exercise empty collections and zero viewports during active flights in all
three engines. The mapped pass geometry, inset destinations and preparation
queue algorithms are unchanged. Programmatic momentum in the native engine
now uses its existing stepped replay driver; native delegate behavior and
display-link scheduling remain outside the proofs.

`Proofs/UltraProofs/List/Preparation.lean` models `PreparationQueue`
(PreparationQueue.swift) and how `UltraListView` drives it.

| Model (`Proofs/UltraProofs/List/Preparation.lean`) | Swift |
| --- | --- |
| `Entry`, `Q` | `PreparationQueue.Entry`, `inFlight`, `latest`, `generation` (PreparationQueue.swift:4-12) |
| `Q.submit` | `submit(_:waiting:merge:)` (PreparationQueue.swift:17); `applyChanges` submits with no waiting keys (UltraListView.swift:235) |
| `Q.replaceWaiting` | `replaceWaiting(generation:with:)` (:26), called by `drainPreparedMutations` for every queued entry (UltraListView.swift:646-655) |
| `Q.complete` | `complete(_:)` (:31), from the measurement callback (UltraListView.swift:747) |
| `Q.takeReady` | `takeReady(merge:)` (:36), the drain's apply (UltraListView.swift:656) |
| `Q.updateNewest` | `updateNewest(_:)` (:47): a block appended while preparing (UltraListView.swift:821), the target carried to the successor (:659) |
| `Op.clear` | `removeAll()` (:52), when the items become empty (UltraListView.swift:228) |
| values as lists, merge as `++` | `mergePreparedMutations` (UltraListView.swift:606): the newest items win, an older target and the blocks carry forward |

- `inv_run`, `applied_increasing`: under any sequence of operations, applied
  generations strictly increase, so a superseded mutation never applies after
  a newer one.
- `conserves`: what has applied, followed by what is queued, is everything
  submitted since the last `removeAll`, in order: nothing lost or doubled.
- `newest_applies`, `busy_producer`: once the awaited keys are measured, the
  newest submission applies; submissions never touch the entry in progress,
  so a steady stream of mutations cannot starve it. That the measurements
  finish is a hypothesis (the measurement scheduler's side).
- `alternating_schedule`, `slot_starves`: with a submission every step whose
  measurement ends the step after, the queue applies at every step, while a
  single newest-wins slot never applies.

Not covered: which fields `mergePreparedMutations` keeps,
`requestedPreparations`' choice of keys, and the reentrancy guards
(`passing`, `drainingPreparations`).

`Pass.inserted_gap`, `inserted_once` model a sent row: a row inserted during a
pass whose viewport delta already carries it. It and its neighbour touch at
every frame iff their own deltas agree, so the inserted-block animation's
`-h` on top of the pass (the second `animateInsertedBlock` call the chat
screen made before `b5667e5`) opens a gap of `h * (1 - p)`. The chat screen
now inserts with the pass alone (ListChatController.swift:243).

## Theorems

**Correctness**

- `Scheduling.Inv.step`: the coverage invariant (every set flag has a walk,
  a scheduled pass or the running pass on its way to it) holds under every
  interleaving of atomic steps.
- `Scheduling.quiescent_clean`: no walk, pass or scheduled pass ⇒ every
  flag clear: no lost update. `progress`: a pending change always has a pass
  running or queued.
- `Scheduling.settles`: after the last walk ends, the first pass that starts
  leaves every flag clear when it finishes: idle within two passes.
- `Commits.Commit.apply_merge`: applying a merged commit = applying both in
  order (given updates only target existing views).
- `Commits.take_is_newer`, `views_after_take`: commits reach the main thread
  in generation order; the host's guard never drops one; the views equal
  applying every posted commit in order.
- `Pass.nodePass_shown` / `nodePass_sound`: one node through one pass:
  shadow and main-thread view end up matching the node's new spec (a
  cancelled drawing keeps the old bitmap).
- `Pass.nodePass_entries`: updates only for nodes with views; mounts carry
  frame and props.
- `Walks.collectFrames_complete`: every changed frame is found (Yoga's
  contract). `Walks.assign_correct`: interface states end at the top-down
  spec, in any order of assignments.
- `Global.pass_sound`, `Global.run_sound`: a pass's commit and a whole run
  of passes are sound. `EndToEnd.quiescent_shows_fresh_render`: at
  quiescence the main thread shows a fresh full render of the current tree.
- `Ranges.bitmap_iff`: a node holds a bitmap iff it is in the display range
  and has something to draw. `Ranges.visible_implies_displayed`: drawn
  before visible while the shown commit's offset is within the display
  margin of the real one.

**List**

- `ListWindow.build_good`, `rebalance_good`: every window is linked (each
  row's band starts where the previous one ends) and measured.
  `linked_y`: a row's `y` is the anchor's plus the measured extents between.
- `ListWindow.resize_frames`: with the anchor fixed, resizing row `i` by `Δ`
  keeps the rows between the anchor and `i` and moves the far side by `Δ`.
- `ListWindow.rebalance_keeps`, `rebalance_screen`: scrolling never moves a
  loaded row. `build_top_pinned`: the pinned top edge is at
  `insets.top + slack`.
- `ListDiff.kept_increasing`, `kept_longest`, `partition`: survivors keep
  their order, no order-preserving choice keeps more rows (fewest moves), and
  each surviving row is a survivor or a move.
- `ListAnimation.lerp_sync`, `affine_sync`, `order_sync`, `touching_sync`:
  tracks with one timing keep every linear relation (and, with a curve in
  `[0, 1]`, order) between presented values at every frame.
  `transition_continuous`, `retime_continuous`: retargeting and retiming
  never jump. `finish_rejects_stale`: generations guard completions.
- `ListPass.displaced_row_screen`, `kept_row_screen`: loaded rows go from
  where they were to where they settle. `inset_moves_content`, `rigid`,
  `immediate_same_frame`: an inset change moves the content by the inset
  plus slack change in the same pass. `lockstep_iff`: content keeps its
  distance to an animated input iff their progresses agree.
  `inserted_once`: a row inserted with the pass touches its neighbour at every
  frame.
- `ListInsets.cheap_eq_full`: the inset-only path draws every row where the
  full pass does. `sum_covers`: covering the sum of the engine's and the
  viewport track's ranges keeps every row on screen.
- `ListPreparation.applied_increasing`, `conserves`, `newest_applies`,
  `busy_producer`: prepared mutations apply in order, each once, the newest
  eventually, and a busy producer never starves the one in progress.

**Optimality**

- `Scheduling.visit_once`, `sync_cost`: each node synced at most once per
  pass; the sync walk visits exactly 1 + Σ children of marked nodes.
- `Scheduling.epoch_enqueues_at_most_one`, `passes_le`: at most one pass
  enqueued per epoch however many mutations; passes ≤ flips + host updates.
- `Walks.collectFrames_visits`: `collectFrames` looks at the root and the
  children of flagged nodes only.
- `Pass.nodePass_draws_only_stale`, `Optimality.draws_exact`: a node draws
  iff it is in the display range and its key differs from its bitmap's.
- `Pass.nodePass_unchanged`, `clean_not_evaluated`: an unchanged node gets
  no entry and no drawing; a clean one is not evaluated.
- `Optimality.must_read`, `must_send`: within the stated input-reading and
  per-node commit models, a correct algorithm must read each relevant input
  and include an entry for each changed view. `entry_only_if_changed`:
  without cancellation and given `Deps` and `KidsOk`, an entry implies a
  changed modeled view or a reported child-list change. It does not prove
  that reported child-list changes are necessary or that bitmap pixels
  differ whenever a drawing key differs.
- `Text.builds_le_distinct`: from an empty cache with fixed text and
  measurer, requests confined to at most four distinct widths build no more
  layouts than that number. More widths can evict a layout and later
  rebuild the same width; the theorem does not exclude this.
- `Power.idle_only_client`, `idle_clean`: when idle only a client can cause
  a step, and nothing is owed in the scheduling model. `Power.apply_local`:
  the modeled view value is unchanged at any node without a commit entry.

## Hypotheses (theorem arguments or structure fields, never axioms)

- **Yoga** (`Walks.YogaContract`): frames change only on nodes flagged
  `hasNewLayout`, and the flagged set is parent-closed. Layout is a pure
  function of the style tree and constraints (`EndToEnd`'s `render`).
  Finding 8 shows the first part fails for percentage padding.
- **Dependencies** (`Pass.Deps`): a node's props and drawing key change only
  if it was synced, the pass is forced, its frame changed, or (`extra`) its
  content frame changed. `Optimality.deps_of_inputs` derives it from "props
  and key are functions of snapshot, frame, environment and `aux`" provided
  an `aux` change queues the node; `stale_when_aux_ignored` is the failure
  when it doesn't (finding 8).
- **Child lists** (`Pass.KidsOk`, from `Global.kidsOk_of`):
  `childrenDidChange` is called whenever a child mounts or unmounts or the
  child list changes, and a mounted node's parent is mounted
  (`Walks.spec_le_parent`).
- **Setters**: a node's live state differs from the last snapshot only while
  `needsSync` is set (`EndToEnd`'s `hfresh`).
- **Measurer**: a text layout fits the width it was built for.
- **Rasterizer**: a bitmap is a function of its drawing key.
- **Scheduler**: a queued `runPass` block eventually runs (`progress` gives
  the queued block; dispatch runs it). The host has supplied a size, so
  `runPass` doesn't return early.
- **Fixed tree** during a burst: structural edits are mutations of the
  parents involved. Finding 9 is what goes wrong when a move races a pass.
- **No cancellation in the last pass**: a cancellation comes from a mutation
  during the pass, which schedules another pass.

## Abstractions

- A `mount` entry builds the view from the entry. Swift reuses a view a
  merged unmount-then-mount left in place and keeps its `mountedChildren`
  when the entry has no child list; those children have no views then, so
  the difference isn't observable.
- Child order is a list on the parent's record; `CommitApplier.order`'s
  incremental subview moves are not modeled.
- `Pass.evaluate` dedup (`Pass.evaluated` set) and one `calculateLayout`
  per pass are structural in the Swift and not modeled further.
- Within one pass, the model sees the net change of a node's interface
  state; a mount and unmount of the same node in one pass is not modeled.
- `setNeedsPass` on the main thread hops through the main queue before
  enqueueing on the layout queue; the model folds the hop into the enqueue.

## Findings (Swift at `22e6866` against the optimal model)

These are historical findings. The review at `a8fc6d3` above identifies
which repairs are present and which proposed improvements remain absent.

1. `Renderer.update` (Renderer.swift:115-118) enqueues a pass on every call,
   bypassing `passScheduled`. Corrected model: `Corrected.FixedStep`,
   `fixed_passes_le`.
2. The sync walk costs Σ children of every marked ancestor
   (`Scheduling.sync_cost`). Corrected model: a dirty queue,
   `Corrected.DQInv.step`, `dq_idle_clean`, `dq_start_work`.
3. `Renderer.updateRanges` (Renderer.swift:414-433) tests every child of the
   content container, and the `childrenChanged` loop (Renderer.swift:227-229)
   filters every child. `Ranges.range_contiguous` justifies a windowed
   update.
4. `CommitMailbox.post` (Commit.swift:151) signals on every post; stale
   permits make `waitForCommit` spin. `Corrected.swift_spins` / `fixed_spins`.
5. Yoga rounds the whole tree on every layout. `Optimality.round_relative_stable`:
   rounding the flagged nodes in `collectFrames` would give the same frames.
6. `Renderer.attach` → `detach` (Renderer.swift:319-356) remounts and redraws
   a moved subtree. `Corrected.move_redraws` / `kept_draws_only_changed`.
7. An appearance-only environment change re-measures all text and re-runs
   Yoga, though frames can't change.
8. Percentage padding: Yoga's layout cache keeps padding resolved against
   the old parent width, and `collectFrames` (Renderer.swift:365) evaluates
   only on frame changes, which text inset and links depend on beyond the
   frame. `Optimality.stale_when_aux_ignored`; tests in
   `Tests/UltraCoreTests/ProvenPropertyTests.swift`.
9. A move racing a pass: `Renderer.attach` leaves the node in the old
   parent's `shadow.children`, and `assignState` (Renderer.swift:408-410)
   can give it the old parent's state for good. `Walks.assign_correct`
   requires every assignment to use the node's real parent; test in
   `ProvenPropertyTests.swift`.
