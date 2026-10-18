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
| `Animation.Model.retime`, `fixedPass` | Historical: `ListAnimationModel.retime(since:)` (ListAnimation.swift:157), `AnimationController.capturePositions` / `retime` (AnimationController.swift:42, 81). Since `460d78f` the controller does not retime; see "Independent size and position motion" |
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
   generation guard is the model's condition. `460d78f` replaced retiming
   with size followers on each height's own clock (`composed_seam`).

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

The carry-placement follow-up after `746e713` rechecks the `Pass.detached_jump`
and `scroll_carry_jumps` rows above. `shiftDetached` and crossing placement now
translate layer positions directly; row and attachment size placement uses
`place(in:)`. Ghost wrappers set their bounds and layer position explicitly.
The modeled coordinate shifts are unchanged. UIKit's inference of bounds and
position when assigning a transformed view's `frame` is outside those equations;
the simulator carry regression exercises repeated stream revisions during an
insertion with both normal and inverted rows. "Placing transformed row views
at `460d78f`" below maps the new writes (`retarget_exact`, `replans_follow`).

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
| `Model.retime`'s `incl` | Historical until `460d78f`: `AnimationController.retime`'s `including:` (AnimationController.swift:87-88): a bound layer, not `.viewport`, not `.opacity` |

`fixed_one_timeline` and `fixed_pass_sync` held over the accepted keys until
`460d78f` removed the controller's retiming, and `fixed_keeps_excluded`
shows retiming leaves the others unchanged. The immediate-branch rows still
apply.
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

The follow-up after `0592bc8` fills content and attachment flight keyframes
backwards before their layer-local start times. This preserves the first
trajectory value over the parked final model value when the render server's
frame precedes that start. Simulator presentation tests cover both an initial
flight and one shifted to a new coordinate base, plus a pinned attachment.
Core Animation's fill behavior remains an environment assumption; the flight
trajectory and pass-geometry equations are unchanged.

The readiness follow-up after `d844843` holds a pure immediate disjoint target
while its destination lacks visible-band measurements or a row's first visible
commit. Views are staged by measurement key and reused by the eventual pass;
an obsolete target's generation cannot resume a newer request. A scroll waiting
for its first height no longer creates a pending collection snapshot. These
callbacks and the display-ready predicate are outside `Preparation.Q`; its
active/latest collection algorithm is unchanged. The pass equations apply when
the ready pass executes. `ListDisplayReadinessTests` covers late callbacks after
a superseding target in all three engines, and a real-node regression checks
that the destination exposes ready visible rows. Staging retains views, while
node-host ownership remains with each view's displayed or pending slot, as in
the host model below.

The input follow-up after `72d9ec7` applies vertical-only viewport insets before
pending dirty-row or collection work. It leaves that work queued and retains
the current viewport request for its eventual pass. The inset placement
equations and collection preparation queue are unchanged; choosing compensation
for a programmatic keyboard/composer change is the host's policy. Interaction
coverage now starts away from newest and observes the same surviving row
through keyboard show, composer growth/shrink and programmatic hide in every
engine. The interactive dismissal latch still disables compensation through
release, so a later hide cannot snap the content back.
The typing follow-up after `6d94fd0` applies ordinary text edits' height and
inset with an immediate transition in the editing turn. It keeps the animated
Send and keyboard transitions. This changes the host's timing choice, while
the inset equations and `Momentum`'s compensation policy remain unchanged.
The historical chat-policy transitions in `Momentum` at `0e5c7b6` still describe
that earlier host policy. The new host no longer tests whether content is at
newest before a programmatic change. The conditional flight-translation and
inset-placement lemmas retain their hypotheses; the revised host policy is
modeled in "Momentum and the keyboard at `b896af1`" below.

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

## Node row hosts at `1dd0bb4`

`Proofs/UltraProofs/List/Hosts.lean` models how node rows hand a prepared
root between row views (NodeRow.swift), the host a preparation draws ahead
(`staged`), and the two cleanups that must not touch a hosted root: the
renderer's queued purge and the list's preparation sweep. (First mapped at
`0592bc8`, before `staged`, and at `44f8a0c` with it. `1dd0bb4` stages
every live node row, not only animated ones; the model's `stage` already
allows any fresh root, so no theorem changes.)

| Model (`Proofs/UltraProofs/List/Hosts.lean`) | Swift at `1dd0bb4` |
| --- | --- |
| `S.displayed`, `S.pending` | `NodeRowView.displayedHost`, `pendingHost` (NodeRow.swift:121-122) |
| `S.hostOf`, `S.weak` | `PreparedNodeContent.host` (weak) and `hasLiveHost` (NodeRow.swift:23, :27) |
| `S.owner` | `PreparedNodeContent.owner` (weak, NodeRow.swift:24) |
| `S.staged`, `S.Staged` | `PreparedNodeContent.staged` (strong, NodeRow.swift:26) |
| `S.renderer` | the root's `state.renderer` (Renderer.swift:92-96) |
| `S.stage` | `NodeRow.prepare` (NodeRow.swift:87-105): for a row whose identity is live, or an animated row whose appearance is still to show (:97), a `NodeHostView` for the root the same call made (:100-101), so the root has no renderer |
| `S.start` | `NodeRowView.start` with `checkout(owner:)` (NodeRow.swift:227, :29-40): the live host, else `staged`, else a new `NodeHostView` (:35), and `staged = nil` (:37). Under `accept`'s and the queued candidate's guard: nothing pending, a different root shown (:264-273, :222-225) |
| `S.release` | `NodeRowView.release(_:)` (NodeRow.swift:155): the old owner lets the host go and keeps a snapshot |
| `S.reveal` | `showPreparedHost(_:)` (NodeRow.swift:166): the pending host replaces the shown one. A shorter one ready inside an animated pass waits for the pass's end (:191-197), then `passDidEnd` reveals it (:279-284): the same step later, and the model allows reveals at any time, with any operations between; the host stays pending meanwhile, so `start` on that view is refused and `accept` queues (:264-273) |
| `S.free` | a row view deallocated: its hosts go, weak `owner`s read `nil` |
| `S.drop` | the last reference to a preparation goes after the store drops it with `hasLiveHost` false (UltraListView.swift:895, :958 in `sweepPreparations` :952), taking `staged` with it |
| `S.collect` | `NodeHostView.deinit` (NodeHostView.swift:109-110) calling `Renderer.detach()` (Renderer.swift:101), which clears the renderer if it is still this host's |
| `purge_unhosted`'s hypothesis | the purge's check on the layout queue, `renderer == nil` (Renderer.swift:108) |
| `sweep_never_drops_hosted`'s hypothesis | `hasLiveHost` false at UltraListView.swift:895 and :958 |

- `inv_run`, `one_host_always`: after every sequence of stagings,
  checkouts, reveals, view deallocations and drops, a root has at most one
  live host, staged or kept (`one_host`), and a kept host is kept by one
  view (`one_slot`). `staged_unkept`, `staged_unkept_always`: a staged host
  exists only while no view keeps a host of its root, so `staged` is set
  only while `host` reads `nil`.
- `start_reuses`, `start_uses_staged`, `start_creates`: a checkout takes the
  live host from the view that had it, else the staged host (no new
  renderer, `next` unchanged), and makes a host only when there is neither.
  `checkout_never_trips`: a host is made only for a root with no renderer,
  so the precondition at Renderer.swift:94 holds; `stage` makes one only for
  a fresh root. `hosted_has_renderer`: a checkout that ignored the live or
  staged host would trip it.
- `purge_never_frees_hosted`: a purge whose check finds no renderer acts on
  a root with no live host, staged or kept. `sweep_never_drops_hosted`: a
  sweep that finds `hasLiveHost` false drops a root no view keeps (a staged
  host can go with it, by design). `drop_detaches`: a dropped preparation's
  staged host goes and detaches the root's renderer, so its bitmaps can be
  purged.

The model reads a host as alive exactly while a row view's `displayedHost` or
`pendingHost`, or the preparation's `staged`, keeps it (the superview goes
with the slot, and the commit and reveal closures capture it weakly), and
deallocation as happening in the turn that lets it go. `drop` is the
preparation's last reference going: a `Candidate` a view still queues
(`pendingCandidate`, `queuedCandidate`) keeps the preparation, and its staged
host, alive past the sweep, which the model reads as the drop happening
later. While `prepare` awaits `prepareContent`, the task also holds the
staged host; the preparation isn't visible to anything else until it
returns, so `stage` is one step. Not covered: the snapshot's content, the
reveal's deadline and `hasContent` wait (any order of reveals is allowed),
the legacy `NodeRow.prepared` cache's eviction, the window of the purge
between its check and its last write (a host attaching then runs its first
pass after the purge on the same serial queue), and the retention policy
(`retainsPreparation`: ±80 rows, the pinned row, the pending target), which
decides only when a sweep runs.

## Drawing ahead for rows shown soon (integrated after `f5124f8`)

The list tells a row's `prepare`, through the task-local
`ListPreparationHint.showsSoon`, that it will show the row as soon as the
preparation is ready, and a node row then stages its host before it
returns. A preparation started without the hint, or stored before the list
came to show the row soon, is drawn ahead later through
`ListPreparedContent.drawAhead()`. Both stage through the same function, so
`S.stage` now maps to more than one call site; its guard is unchanged.

| Model (`Proofs/UltraProofs/List/Hosts.lean`) | Swift |
| --- | --- |
| `S.stage` | `PreparedNodeContent.drawAhead()` (NodeRow.swift:35-45): only while `host` reads `nil` (no view keeps a host of the root, so the root has no renderer: a host's renderer detaches when it deallocates, and `host` is weak), and only when nothing is staged; a `NodeHostView` for the root, kept in `staged`. Called from `NodeRow.prepare` (:105-121) for a live identity, an appearance still to show, or `showsSoon` (:115-118); from `UltraListView.showSoon` (UltraListView.swift:1296-1299) for a stored preparation the list will show soon, called for a mutation's nearest requests (:1243), a request with the hint (:1316) and prepared rows ahead of a scroll, queued by the scroll turn (:1385-1386, `drawAheadLater` :1300-1304) and drawn about a millisecond's worth per later main-queue turn (`drainDrawAhead` :1306-1310); and before a running preparation is stored, when the list came to show it soon meanwhile (:1324-1326), which stores only while its ticket is current (:1328-1335) |
| `S.start` | `NodeRowView.start` (NodeRow.swift:243) with `checkout(owner:)` (:46-57): the live host, else `staged`, else a new `NodeHostView` (:52), and `staged = nil` (:54). Under `accept`'s and the queued candidate's guard (:280-290, :238-241) |
| `S.reveal` | `showPreparedHost(_:)` (NodeRow.swift:182), with the pass-end wait (:207-213) and `passDidEnd` (:295-300) |
| `S.drop`, `sweep_never_drops_hosted` | `hasLiveHost` false at UltraListView.swift:1340 and in `sweepPreparations` (:1404-1415) |

A staging after the preparation is stored is a separate step in the model
(the model allows `stage` between any others); a `drawAhead` that finds a
host kept does nothing, so a checkout racing it keeps `staged_unkept`. The
drawing task holds the staged host until `prepareContent` returns, as
`prepare` did: while it does, the host is alive and `host` (weak) is not
`nil` once it is checked out, so no second host is made. Which rows count as
shown soon (`rowsShownSoon`, about two screens and their preload margins
around the anchor, alternating sides) and when a stored preparation is drawn
(only ahead of the scroll's direction, on turns after the scroll's) are
scheduling, outside the model: a queued key runs `showSoon` like any other
call, so its guard is the same.

A premount (see "Premounted rows and deferred unmounts") checks out like
any row: `applyPreparation` takes the live host, else one a `drawAhead`
staged, else makes one, so a row drawn ahead is premounted without drawing
again, and `one_host` holds as before. The idle turn is a timer and
`drainDrawAhead` a main-queue block, so they run in either order; a
`drawAhead` after the premount finds the host kept and does nothing.

Integration preserves the edge-target and pending-item retention fix from
`1a4e486`: `atEdge` is now UltraListView.swift:848, `recordPendingTarget`
is at :856, and the unchanged retention predicate is at :1416-1428. It
keeps pending-item preparations in addition to the existing band and live
hosts. The edge regression file is unchanged (SHA-256 `63a61cd7…`), including
all 12 arriving-edge cases. The keyboard controller, gesture, composer and
app settings are unchanged from `f5124f8`.

The premount and collapse mappings above retain their historical citations.
The current `departureEdge` is at UltraListView.swift:258-262. NodeRow.swift
lines from :106 on at `f478507` move by 16, so `showPreparedHost`'s appearance
condition the premount section cites (:178-179) is at :194-195. Current SHA-256:
`UltraListView.swift`
`7d693ea8717ac587ca58cfc1b0419e4ba8cdfcd9f51f582113033cf5801d4389`,
`NodeRow.swift`
`39aab7f88e95818b717c81ac2e507a3c5bcab8ce19d83e1c691076a5675b7767`,
`ListRow.swift`
`50806041d14cec55b4c33d52fe18b6ae137f9665e5ba9f3941d07d125558a24f`.

The carousel readiness follow-up after `dc33dfc` changes no host operation or
theorem. `DemoCarouselView.isDisplayReady` additionally requires its placed
bands to cover the visible axis, unless they reach the actual content ends,
and requires a restored anchor to be in the window. A ready first card alone
therefore cannot release an enclosing jump while more visible cards are still
unmeasured. Its deadline remains a bounded fallback, outside these models.
`CarouselReadinessTests` controls missing measurements synchronously before
the deadline and retains the existing bitmap jump assertion. These are ordinary
runtime regressions, not new proofs. `HorizontalListDemo.swift` SHA-256:
`2ea08d1448aa28a06d0f64c84c6088af75d80ea60514582f85d79a8a7c4f4ed4`.

## Node transitions at `44f8a0c`

Node rows can now animate their content (`NodeRow.animatesContent`). This
section records how that touches the mapped Swift; nothing here is a new
machine-checked result.

- `Pass.Deps`: `makeProps` also reads the node's `transitionKey`, which
  comes from synced node state like every other prop, and text props also
  carry line boxes taken from the text layout they already used.
  `drawingInput` adds a contents placement (top-anchored text,
  nine-slice boxes, or fill), a function of the inputs it already read.
  Dependencies keep the shape `deps_of_inputs` requires.
- `Entry.apply`: `CommitApplier.apply` also sets the layer's contents
  gravity and center from that placement when the placement changes. The
  entries applied, and their order, are unchanged.
- `Hosts.lean`, `S.start`: a prepared content can hold a `staged` host,
  made in `NodeRow.prepare` for the content's root before any row view
  checks it out. `checkout` uses it in place of making one and clears it,
  so `staged` is set only while `host` is `nil`, and a root still has at
  most one host. Until the checkout, the staged host is owned by the
  prepared content, not by a row view, so a sweep that drops the content
  frees it. `Hosts.lean` now models this state (`S.stage`, `S.drop`; see
  "Node row hosts at `44f8a0c`").
- The animations themselves (`NodeTransitionAnimator`, `NodeRowMotion`)
  run after a commit applies, as Core Animation, and are outside the
  model. The invariant they keep (inner frames use the row height
  animation's begin time, duration and curve, so a node sized with the row
  keeps its edges on the row's edges in every frame) is checked in the
  simulator by `NodeTransitionTests`; `Content.lean` proves the timing
  argument, mapped in "Content inside an animating row at `44f8a0c`".

## Momentum and the keyboard at `b896af1`

`Proofs/UltraProofs/List/Momentum.lean` models how a release, the physics
engine's flight and keyboard (inset) changes interleave, with the chat
screen's `followsComposer` policy that decides compensation. Events come in
any order. This section replaces the one at `0e5c7b6`, which modeled the
earlier newest-edge policy.

| Model (`Proofs/UltraProofs/List/Momentum.lean`) | Swift |
| --- | --- |
| `Flight`, `.offset`, `.velocity`, `.shiftBy` | `ScrollFlight` (ScrollCore.swift:60-70); `FlightState.shift(by:edges:)` (:89) moves only `coordinateShift` |
| `Baker` (structure fields: the first sample is the axis' offset and velocity) | `ScrollTrajectory(baking:)` with `FlightState(core:time:)` (ScrollCore.swift:79) |
| `St.now` | `engine.sync()` (ScrollEngine.swift:144): the flight's offset now |
| `Ev.touch` | `pan.touchDown` (ScrollEngine.swift:113) catching the flight, and `didTouchDown` clearing `holdsPinnedRow` (UltraListView.swift:144) |
| `Ev.dragBegin` | `handleDragBegin` (UltraListView.swift:196) and the chat's `willBeginDragging` recording the guide and setting `followsComposer` (ListChatController.swift:81-85) |
| `Ev.drag` | a drag sample with the chat's `onUserScrollDelta` (:86-89), or a layout while tracking (:147): the guide more than a point from where the drag found it clears `followsComposer` |
| `Ev.release` | `panned`/`receive` `.ended` (ScrollEngine.swift:285, :308): `endDrag` hands the release decision's velocity to `axis.release`, then `startMotion` bakes; the chat's `didEndDragging` sets `followsComposer` to whether the guide stayed (ListChatController.swift:90-93) |
| `Ev.keyboard`, `keyboardFollows`, `kbShift` | `keyboardWillChange` (ListChatController.swift:162-183: a growing overlap with the finger up sets `followsComposer`) and `applyComposerInset`'s `compensatesInsetChange: !isTracking && followsComposer` (:159), into `updateViewportInsets` (UltraListView.swift:558-594): the held-pin boundary, else `cheapFixed`, else 0, then `engine.shift(by:)` (:590) |
| `Ev.explicit` | the hide button (:103), `textViewDidChange` (:184-188) and `sendMessage` (:258-259) setting `followsComposer` |
| `Ev.rebake` | the tick's `rebake` (ScrollEngine.swift:253), re-baked from the axis reseeded by `beginTick` |
| `Ev.land`, `Ev.pinTarget` | the flight completing; `applyChanges(scrollTo:)` to the pinned row setting `holdsPinnedRow` (UltraListView.swift:307) |

- `release_hands_velocity`, `keyboard_keeps_velocity`, `run_keeps_velocity`:
  the flight starts with the release decision's velocity, dismissal or not,
  and any number of keyboard changes translate it without changing its
  velocity at any time. The keyboard path calls `engine.shift(by:)` only,
  never `setOffset` or `halt`. `rebake_continuous`: re-baking keeps the
  offset and the velocity at the splice. `edges_keep_finiteness`: an inset
  change keeps which edges are finite, so `setEdges` never takes its
  edge-discovery rebake for one. These hold unchanged from `0e5c7b6`.
- `grows_compensates`, `explicit_compensates`: with the finger up and no
  pinned row held, a keyboard that grows compensates at any scroll position,
  and after the hide button, a text change or Send every inset change does.
  `run_follows`: compensation stays on through any events but an
  interactive dismissal (the guide moving during a drag, or still moved at
  its release).
- `follows_moves_by_inset`: a compensated change moves the offset by exactly
  the screen move (inset plus pin-slack change) whenever that destination
  lies within the new edges, wherever the content is scrolled to, so the
  content keeps its distance to the composer. Where it would leave them (an
  inset shrinking with the oldest row at the far edge, say) the content
  settles at the edge. `follows_rides_edge`: content at or past the top edge
  always keeps its distance. With `ListPass.lockstep_iff`, the viewport
  track then keeps it at a fixed distance from the composer at every frame
  when the list and the composer share the keyboard's timing.
- `no_write_unless_following`, `tracking_never_writes`: a keyboard change
  writes neither the offset nor the flight unless the pinned row is held or
  the chat compensates, and never while the finger is down.
- `dismissal_latches`, `dismissed_never_moved`, `dismissal_then_quiet`: a
  dismissal's release keeps compensation off, and no later keyboard shrink,
  re-bake or landing writes the offset or the flight, so the hide that
  finishes the dismissal does not snap the content. A growing keyboard, the
  hide button, a text change, Send or a new drag turns compensation back on;
  `untouched_drag_resumes`: a drag that leaves the guide alone does.
- `run_unpinned`: after a touch, only a scroll target to the pinned row sets
  `holdsPinnedRow`, so the held-pin branch never re-pins content the user
  moved.

The hide button and Send set `followsComposer` even while tracking, and a
text change only with the finger up; the model sets it in every case. While
tracking nothing compensates, and the release then decides the latch, so
the difference never reaches an offset write.

The release decision itself (`ReleaseDecision.release`: velocity estimate,
the 250 pt/s threshold, the multiplier streak) is an input. The client hook
`shouldStopScrolling` (UltraScrollView.swift:24) zeroes a release when it
returns true; the chat screen does not set it, and the model assumes it is
unset. Not covered: the trajectory physics (deceleration, bounce, the
rubber band), the edge-reach `rebakePending` test (a rebake may come at any
tick in the model), braking on a touch, the UIKit engine's native
deceleration (`PlatformEngine.shift` moves `bounds` without
`setContentOffset` for the same reason, which is the system's to keep), and
the overscroll an uncompensated change leaves for the engine to return
(`Insets.uncompensated_keeps_offset`).

## Engine callbacks during a pass at `0e5c7b6`

`Proofs/UltraProofs/List/Reentry.lean` models the guard `0592bc8` added to
`onFlightChanged` (UltraListView.swift:140).

| Model (`Proofs/UltraProofs/List/Reentry.lean`) | Swift |
| --- | --- |
| `L.items`, `L.reads` | `items` and the indices `renderAttachments` reads through `settledWindow` and `runs` |
| `Micro.swap` | `items = incoming` (UltraListView.swift:292) |
| `Micro.rebuild` | the window and runs rebuilt for the new items (the empty branch's `runs.removeAll()` at :336, `resolveAttachments`) |
| `Micro.callback`, `guarded` | `onFlightChanged` from `halt`, `shift` or `setEdges` inside a pass: `guard !passing else { deferredAttachmentRender = true; return }` |
| `pass` | `passing = true` (:251) to the `defer` that clears it and renders if deferred (:256-260) |
| `unguarded` | the callback before `0592bc8`, rendering at once |

- `guarded_pass_renders`: whatever the order of swaps, rebuilds and
  callbacks, a guarded pass renders only after it ends, on its final state,
  exactly when some callback ran: no callback observes a half-applied list,
  and none is lost. `guarded_consistent`: every such render reads indices
  inside the items when the pass ends rebuilt.
- `unguarded_reads_outside`: the chaos crash. Emptying a 5-item list whose
  window reads row 3, the empty branch halts the engine after the swap, and
  the unguarded callback renders row 3 of no items.

Not covered: the renders a pass makes itself (`handleScroll` and
`updateViewportInsets` call `renderAttachments` after their rebuilds), the
`handleScroll` the callback also starts (guarded by the same `passing`
check), and the content of a render.

## Flight band at `8d425b6`

`Proofs/UltraProofs/List/Flight.lean` models the band `handleScroll`
rebalances around while the engine is in flight.

| Model (`Proofs/UltraProofs/List/Flight.lean`) | Swift |
| --- | --- |
| `Sample`, `Sorted` | `ScrollTrajectory.Sample` and `init`'s precondition (ScrollTrajectory.swift:4-14) |
| `sampleAt`, `lerp` | `sample(at:).offset` (:33-44), the binary search modeled by the segment it finds |
| `inside`, `extent` | `extent(from:through:)` (:49-64): the ends' samples and the vertices strictly between, folded with `min`/`max` |
| `Flight`, `.offset`, `.covered` | `ScrollFlight`, `offset(at:)`, `coveredOffsets(at:horizon:)` (ScrollCore.swift:60-70) |
| `flight_rows_kept`'s rebalance | `handleScroll`'s `flightOffsets` plus the viewport track's `valueBounds`, into `ListWindow.rebalance` (UltraListView.swift:613-619) |

- `sample_in_extent`: at every time in `[start, end]` the trajectory lies in
  `extent(from: start, through: end)`. Its bounds are values the trajectory
  takes, so no smaller range contains it.
- `flight_in_band`: the flight's offset at every time from `time` to
  `time + horizon` lies in `coveredOffsets(at: time, horizon:)`.
- `flight_rows_kept`: with `ListInsets.sum_covers`, every loaded row the
  flight shows until the horizon, under any viewport delta within the
  track's bounds, survives the rebalance. The track bounds remain the
  hypothesis of `track_in_hull`.

The band covers the next 0.3 s; that the next `handleScroll` comes sooner
(every display-link tick in flight) is outside the model. So are the
stepped engine's `coveragePrediction` (a trajectory baked from the axis that
the ticks then step, ScrollEngine.swift:99-102), whose agreement with the
ticks is the physics' own, and the `maximumAdditionalRows: 64` budget, which
`rebalanceIn_keeps` does not need (it bounds new rows, never removes loaded
ones).

The flight-publication follow-up at `a75c785` groups `startMotion`,
`catchMotion`, `shift`, `setEdges` and `tick` in outer Core Animation
transactions. A parked bounds origin, its compensating animation and the
synchronous rows and attachments mounted by their callbacks reach the render
server together. The trajectory and coverage equations above are unchanged;
they assume UIKit's transaction semantics and do not model intermediate
render-server commits or pixels. A rendered probe on `460d78f` showed a
fully blank list at one frame of the first release (3.197 s); at
`a75c785` none of 359 frames was blank.

## Independent size and position motion at `460d78f`

`Proofs/UltraProofs/List/Layers.lean` states what keeping a size motion's
clock through a later move pass requires, and `460d78f` implements it: the
controller's whole-pass retiming is replaced by size followers. The older
`fixed_pass_sync` model describes the earlier retiming policy (see the
historical rows above). `ListAnimationModel.retime` remains as a legacy
helper for ordinary property keys; it excludes the follower keys, and the
controller no longer calls it. The rows pin `460d78f`.

| Model (`Proofs/UltraProofs/List/Layers.lean`) | Swift |
| --- | --- |
| a presented value as base plus one term per clock (`superpose`) | `ListAnimationModel.value`: the base track plus `positionLayerValue`, the sum of the `.positionY` keys with a `positionSource` (ListAnimation.swift:146-195) |
| `residual`, `residual_exact` | `AnimationTrack.residual(multipliedBy:)` (ListAnimation.swift:138): `(from - to) · c` to 0 on the height's start and transition |
| `coef common own s i` | `SizePositionGeometry.coefficient(source:row:from:to:ownPlacement:)` (SizePositionGeometry.swift:8): `common s` is `0` when the window anchors its top, `-[s < anchor]` otherwise, and the pinned secant for the anchor when it holds a pinned row; `own` is `placementOffset` at height 1 less at height 0 (UltraListView.swift:556) |
| `secant`, `pinned` | the `pinsAnchorBottom` branch, with `half = visibleHeight / 2` (SizePositionGeometry.swift:10-15) |
| `composed`, `composed_seam` | a row's position after a pass: `rowPositions`' settled place, its own move (`.positionY`), one follower per running height (`positionLayers`, UltraListView.swift:555-565) and the one layout layer every row gets (:574-584) |
| `hs s`'s clock shared by its followers | `heightMotions` reads each height's installed origin, and `setPositionLayers` installs the followers with it (AnimationController.swift:131, :139-150, :262-268) |

Swift tolerances the model drops: a coefficient within `1e-6` of 0 gets no
follower (the model's term is that small), and heights within `1e-6` take
the equal-heights branch of the secant.

Position and size resumes use the same captured presentation frame. A size
follower's captured contribution is its source's presented height residual
times its coefficient; other common terms use the capture's time. Before a
view has a presentation layer, capture uses its existing model tracks and
bounds, so a new size follower is still removed from the own-move resume. Carry
retention uses a separate generation and deadline (`retainCarry`, `finishCarry`,
UltraListView.swift:617, :635), so holding an outgoing row does not require
restarting its position clock. These controller and UIKit choices are tested,
not established by `superpose`.

- `superpose`: terms of a linear relation split into groups, each on one
  timing and each keeping its share at start and end, keep the relation at
  every frame. A presented value is its base plus one additive layer per
  timing.
- `layered_touches`: a row growing 100 → 150 over 1 s, and both it and the
  row below moving up 40 in a pass at 0.5 s. With the lower row following
  the growth on a layer with the growth's timing, and the move on a second
  layer, the rows touch at every frame.
- `single_layer_opens`: folding the lower row's remaining growth delta into
  the move's one track, while the height keeps its timing, overlaps the rows
  by 12.5 points at 1 s.
- `follower_exact`: a follower copying a height track's start and transition,
  from `src - dst` to 0, equals the height's remaining change at every time.
- `prefix_seam`, `prefix_touch`: rows that follow every height above them
  and none above the anchor (coefficient `[s < i] - [s < anchor]` for source
  `s` on row `i`), with their own moves on top, are apart by the upper row's
  presented height plus the difference of their moves, whatever each
  height's timing: adjacent rows with equal moves touch at every frame.
  `prefix_anchor`: the anchor moves only by its own move. `prefix_rest`: at
  rest every row is at its settled place plus its move.
- `common_seam`: the seam holds with any term every row shares, so the
  anchor's compensation and a pinned anchor's term are free to differ from
  the prefix form. `position_top`: with source `s`'s coefficient on row `i`
  `common s + [s < i] + own·[s = i]` (`own` is 1 for rows placed by their
  bottom edge), the row's position less `own` times its presented height is
  its top with the common term `Σ common s · (h s - dst s)`; each source's
  share of that term is on the source's height timing, not the move's.
  `anchor_common`: `common s = -[s < anchor]` is `prefix_seam`'s form.
- `residual_exact`: a follower that is a height's residual scaled by `c`,
  on the height's clock, is `c` times the height's remaining change at every
  time. `composed_seam`: rows composed as the list composes them (settled
  place, own move, those followers, a shared layout layer) are apart by the
  upper row's presented height plus the difference of their moves at every
  time, for every height clock and every common coefficient.
- `pinned_ends`, `pinned_left`, `pinned_right`: a pinned anchor's common
  coefficient is the chord of `max 0 (h - half) - h` from the old height to
  the new (or `0`/`-1` when they are equal). Both ends are exact, and on one
  side of `half` the term is the boundary at every presented height.
  `pinned_kink`, `kink_bound`: across `half` it is not. Between
  `lo ≤ half ≤ hi`, growing or shrinking, it is above the boundary by at
  most `(half - lo)(hi - half) / (hi - lo)`, at the kink: 25 points for 50 →
  150 in a 200-point viewport. Rows still touch; this is the path the
  window takes, not a gap.

`LayeredAnimationTests` checks superposition with two size curves, move retargeting,
unchanged generations and stale completions on Linux. `SizePositionGeometryTests`
checks anchor and pin coefficients and adjacent-row relations. The simulator
matrix covers Resize→Move, Move→Resize, same-row resize retargeting, Insert→Resize,
the growing row itself moving, two independent sizes, a resize below the
moved range, and Insert→(Move + Resize) where unrelated rows must retain the
insertion's clock, interrupted at 0, 0.25, 0.5 and 0.75 seconds.
`composed_seam` holds for every choice of common coefficient and layout
layer, so rows touch at every frame whichever anchor, pinned secant or
layout offset the Swift picks, as long as adjacent rows' own moves agree and
each follower plays on its height's clock. Where that common term puts the
window (the anchor staying put, the pinned boundary) is the choice's, which
`prefix_anchor` and the `pinned_*` theorems describe but no theorem shows is
the Swift's intent. UIKit playback (that installed clocks are the model's)
and generation callbacks are hypotheses, checked by the tests above.

### Mount continuation at `cde2528`, `ec6b5ae`, `0abfaac` and `3ffd162`

`cde2528` adds `PositionSource.continuation` to the same additive sum.
The `ListAnimationModel.value`, `positionLayerValue`, generation replacement
and `AnimationTrack.residual` rows above were rechecked: their algorithms are
unchanged. `superpose` still describes the sum of independent clocks, and
`composed_seam` still requires the stated relation between adjacent own moves.
Neither theorem establishes that the mount code chooses those moves correctly.

`ContinuationField.delta` (SHA-256
`d5bd0e643ab027a4ac14f2a7a5d2ee048008276e132939954ad44ac59e97ca39`)
subtracts old and new band prefixes, including reserves and placement offsets.
It visits at most 64 entries in either order and returns no estimate if a
necessary height is unknown. Its exact-value Linux tests cover both directions,
repeated index differences across move boundaries, reserves, placement, and
unknown or distant bands. `ListMount.delta_spec` refines it (the next section).

Source pins (SHA-256): `UltraListView.swift` at `c5743ae`
`d5e39147faa14c9216beb7a51479cded7f3ccbd11dd5cf92b60e9f95c409b790`
(`3ffd162`'s `7496a1ca5c38bf8a4fc18270c119b5924be5d2805e84ccc69349ead02fb5e4d7`
plus `performAfterCurrentPass`, which shifts its lines from 251 by 7) and
`AnimationController.swift` at `3ffd162`, unchanged since,
`79a898b507478a4a989f8b502382c5f6c9ea1f453f371f82381db536e96880b7`, with
the UIKit suites that check what Lean doesn't,
`AnimationClockBoundaryTests.swift`
`8237737afeb4cbade1f5a6d978bcf43e1cc3a7c8356bdc5b261e98bc41bf22ea` and
`OffscreenMotionTests.swift`
`9c795b8117b27b082c6e5de804f5ca44abdad8570dbda14a7efcae1fd7f1da69`.
`UltraListView.mountMotion` saves the latest `SizePositionGeometry` and keeps
the source heights presented when the structural pass began. Both band orders
use those frozen heights, including a source crossing their interval in a move.
An already-running resize is not subtracted twice, and later resizes remain
independent. Surviving rows first measured by the full pass use this calculation
before becoming witnesses for later mounts. The record retains both identity
orders across immediate updates;
it uses record-time bands and copies its neighbour when a needed band is unknown.
`AnimationController.inheritPosition` copies an own track and its origin, leaving
an uncommitted origin unset so the native transaction assigns it to all rows.
The saved record outlives a short or immediate structural pass if its witnesses
still carry an older motion. A carried view's join solves for a new start on the same clock from its
presented position; a small remaining fraction or more than threefold travel
uses a fresh transition. This is position continuity, not a velocity guarantee.
Capturing the origin before detaching its layer is part of the UIKit contract.
These installation, fallback and bounded-history choices remain outside Lean.

The clock-boundary follow-up (`0abfaac`) checks the installed animation's generation before
reading its native origin. After incoming rows finish installing their clocks,
the structural witness prefers an installed continuation, then a participant's
own position clock, before the pass-time fallback. If a carry has only follower
motion, its join uses a
fresh transition on the longest remaining follower timing. The UIKit boundary
suite checks stale row and viewport generations and the carry's presented
positions. A single scan collects the participant deadline; idle mounts skip
the reconstruction when there is no continuation, height, layout or carry.
The additive-sum and height-coefficient model rows above remain unchanged;
neither these UIKit guards nor their execution cost have a Lean refinement.

The origin follow-up (`3ffd162`) checks a delayed native commit when deleting the last
loaded row: incoming rows can replace their own track with a continuation, so
the witness is selected after that replacement. Fresh joins undo the existing
duration and playback scaling before `replace` applies it once. UIKit tests
check the shared commit origin in all three engines, plus duration, playback
scale and linear or damped-spring positions at scale 2. The row-by-row restart
policy remains: a later structural pass can place one row's continuation on a
new clock while an unaffected neighbour retains its old clock, delaying gap
closure across multiple mutation boundaries. This policy is outside Lean.

Where the models touch this code, lines at `c5743ae`:

| Model | Swift at `c5743ae` |
| --- | --- |
| `superpose`: one more term in the sum | `PositionSource.continuation` (ListAnimation.swift:168, keyed `ultraview.list.continuation` at :182), installed with the followers by `setPositionLayers` (AnimationController.swift:204-218; UltraListView.swift:635-637, :939, :958-962) |
| a copied track on the same clock (`progress_timing`) | `inheritPosition` (AnimationController.swift:160-172): the reference's own track's `from`, `to`, start and transition, installed with the reference's origin |
| the continuation term's clock | the record's clock (UltraListView.swift:689), with its origin read from the witness's installed animation only when the generation matches (`resolveMountContinuation` :898-905, `clockOrigin` AnimationController.swift:151-159, `animationOrigin` :359-366); the witness is chosen after incoming rows install (UltraListView.swift:707-721) |
| `ListContent.joinStart` with target 0; `join_exact`, `join_remap` | `joinPosition`'s own-track branch (AnimationController.swift:173-195): `remaining` is `1 - p` on the own clock, and `from = residual / remaining` on the same start and transition is `joinStart residual 0 p`, so the joined track shows the carried view's presented displacement at the join and reaches 0 at the old deadline. The fresh-transition branches (:196-202) are outside the models |

No theorem statement or hypothesis changed with these four commits; none of
them touches `Proofs/UltraProofs`.

## Rows mounted during a structural move at `3ffd162`

`Proofs/UltraProofs/List/Mount.lean` refines `ContinuationField.delta` and
states what a mounted row's motion is. A pass that inserts, removes or moves
rows animates the rows in its window on one clock. A row that scrolling
mounts while that motion runs copies a surviving neighbour's own position
track and gets a continuation term on the pass's clock that starts at the
neighbour's continuation plus `δ`, which `delta` computes.
`ContinuationField.swift` is unchanged since `cde2528`; lines are as of
`c5743ae`, which adds only `performAfterCurrentPass` to `Sources/UltraList`.

| Model (`Proofs/UltraProofs/List/Mount.lean`) | Swift at `c5743ae` |
| --- | --- |
| `Band`, `Band.extent` | `ContinuationField.Band` (ContinuationField.swift:4-9) |
| `delta`'s guard | `abs(row - reference) <= limit` in both orders and all four indices in range (:15-17), as `Nat` differences both ways and `< length` |
| `slice`, `sign`, `tally` | the two loops filling `coefficients` (:18-24): `±1` per index of `min ..< max`, by direction. The dictionary is a function that is 0 off its keys (`tally_eq`) |
| `keyTerm`, `keySum` over `keys` | the loop over `coefficients` (:25-31): the skip for equal coefficients with no band in either order, `nil` for a nonzero coefficient without a band, else `old · extent - new · extent`. `keys` is the dictionary's iteration order, which the theorems leave open; they require it to list each identity once (`Nodup`) and to include both intervals' identities |
| `endTerm` | the loop over the row and the reference (:32-41): nothing when neither order has a band, `nil` when one does, else the change in top reserve plus placement times the change in height |
| `oldBand`, `newBand` | `MountContinuation.band(_:before:)` (UltraListView.swift:142-149): the record-time band in that order, else the other order's, with the height presented when the pass began (`presentedHeights`, :684-688) in both |
| `place B order i pl` | where a layout puts row `i`'s own motion: the extents before it, its top reserve, its placement coefficient times its height. `pl` is `placementOffset` at height 1 less at height 0 (`placement`, :913-917; `record.placements`, :681-683, :947) |
| `delta`'s arguments | `mountMotion`'s call (:948-957): `record.oldIDs`/`newIDs`, the indices of the row and the witness in each order (one identity each, `hRow`, `hRef`), and their placements. `nil` falls back to 0 (:956) |
| `copy_value` | `inheritPosition` (AnimationController.swift:160-172): `model.replace` with the witness's own track's ends, start and transition, a new generation, and the witness's origin |
| `cont clock c` | the continuation layer (UltraListView.swift:958-962): `record.clock` (from 0 to 0 at the pass's time on its scaled transition, :689) with `from` set to the witness's continuation's `from` plus `difference`, and `record.origin` |
| `shown` | a row's settled place plus its own `.positionY` track plus its continuation; the height followers (:918-928) are `composed_seam`'s and go on their own clocks |
| a witness the pass moved (`pass_witness`) | a participant row whose own track the pass replaced at `time` with the transition scaled by `durationScale` (UltraListView.swift:659-662 through AnimationController.swift:258-267), which is `record.clock`'s timing |
| chains (`delta_telescopes`) | `witnesses.append(row.index)` (UltraListView.swift:970): a mounted row is a witness for the next, nearest first (:940-944) |

- `delta_spec`: whenever `delta` returns a value, it is the row's place less
  the witness's in the old layout less the same in the new, for any
  iteration order of the keys and any layouts the known bands describe
  (`hOld`, `hNew`) in which a row with no band in either order is unchanged
  (`hSame`, what the two skips assume).
- `mount_relative`: the mounted row less its witness is their settled
  difference plus `δ` times what is left of the pass's clock, at every frame,
  whatever clock the witness's own track is on. With `δ` the change in their
  offset, they start at the old layout's offset and end at the new one's.
- `mount_moved`, `mounted_as_moved`: when the witness moves from its old to
  its new place on the pass's clock (`pass_witness`: a participant the pass
  restarted), the mounted row is where the pass would have put it at every
  frame, given that each layout's places are `place` plus one constant per
  layout and one per view. The mounted row then satisfies the same
  hypothesis, so a chain of mounts does too.
- `delta_sample`: `a b c d` (extents 10, 20, 30, 40) reordered to `a c b d`:
  `d` against `a` changes by 0, `c` against `a` by 20.

Not covered: a moved row and a row whose bands `delta` can't resolve get
`δ = 0` and follow their witness (:949-956); a witness whose displacement
the pass left unchanged keeps its earlier clock (AnimationController.swift:232-238),
so only `mount_relative` describes it; a participant's existing
continuation is kept as is (UltraListView.swift:938-939); a carried row's
join is `joinStart`'s (the table above). That the window's settled places
are `place` plus constants is a hypothesis, which `ContinuationFieldTests`
checks with exact values. Floating point and the 64-row limit are not
modeled.

## Pending scroll targets and readiness holds

`Proofs/UltraProofs/List/Readiness.lean` models how `applyChanges` keeps a
scroll target it cannot apply yet, including the readiness hold `75fe3c8`
added for immediate distant jumps (animated ones too since `1fd22d3`). The
rows pin `6d94fd0` plus the commit that adds the zero-viewport fix below.

| Model (`Proofs/UltraProofs/List/Readiness.lean`) | Swift |
| --- | --- |
| `S.pending`, `S.retry`, `S.gen` | `pendingTarget`, the target `pendingScroll` re-requests, `pendingDisplayGeneration` (UltraListView.swift:69-74) |
| `pick` | `scrollTo ?? pendingTarget` (:308) |
| `Out.apply` | the pass: `pendingTarget = nil; pendingScroll = nil` (:401), and `clearPendingDisplayViews` at its end (:553, :563) |
| `Out.hold` | the distant-jump readiness branch (:422-453): records the target and the closure, starts a generation, installs observers |
| `Out.empty` | the empty-window guard (:385-400): records the target, and the closure for its own `scrollTo` |
| `Out.zero` (`fix = true`) | the zero-viewport guard with items (:316-344): records the target, the closure for its own `scrollTo`, and `clearPendingDisplayViews()` (:325) |
| `Ev.observe` | a readiness observer: `pendingDisplayGeneration == generation` and every awaited height and view ready, then `pendingScroll` (:445-448) |
| `Ev.flush` | the dirty flush: `pendingScroll` if set, else a pass without a target (:758-759) |

- `applies_latest`, `run_applies_latest`: every target that applies, after
  any sequence of calls, flushes and observers, is the most recently
  requested one. A hold changes nothing shown, so the old window stays until
  then.
- `stale_noop`, `later_gen_lt`: an observer from an earlier hold does nothing
  after any later call that applies, holds or meets a zero viewport.
  `resume_applies`: the current hold's observer applies its target when its
  check passes.

**Gap at `060cb79`, fixed.** `zero_reverts` (`fix = false`): the
zero-viewport guard replaced `pendingTarget` but kept an older
`pendingScroll`. A held jump to row 50, a layout to zero width, a jump to
row 80, then a dirty flush (a measurement finishing) ran the row-50 closure,
which recorded row 50 again; when the width returned row 50 applied, not row
80. The simulator reproduced it in all three engines. The guard now records
the closure for its own `scrollTo` (and clears it with the items), which is
`zero_fixed` and `applies_latest`.
`ListPendingTargetTests.theNewestTargetAppliesAfterAZeroWidthLayout` covers
the sequence in every engine, and checks that the first hold's late
readiness callbacks do not bring row 50 back.

The same test found that a pending target resumed by a pass without its
call (here the layout when the width returns) lost the call's
`additionalScrollDistance`. `recordPendingTarget` (:558) now folds the
distance into the recorded target's `resolve`, so the layout and the
closure place it alike. The model's targets are row indices and do not
carry options. A pass that resumes a pending target uses its own
transition and flags; the closure keeps the original call's.

Not covered: which way a call ends (the destination check, the measurement
and display readiness themselves), the empty-items case of the zero guard
(both cleared, nothing can apply), staged view reuse, mutations with new
items (the preparation queue), and the `passing` deferral.

**Animated destination coverage at `1fd22d3`.**
The distant-jump hold now applies to animated transitions too. The only
source change removes `transition.isImmediate` from its guard
(UltraListView.swift:519); that file's SHA-256 at `1fd22d3` is
`cb717770cdaf2db62d8a760422a2404534c378cd59c212597a5e6042c5461965`, and
`FarJumpCoverageTests.swift`'s is
`a3aa09813c864084936acd79c08f17fd9a9f46e99ed1c428416e668e3a01c0dd`.
The `Out.hold`, `Ev.observe` and `Ev.flush` rows above retain their behavior:
the original target and transition are retried after the destination's
visible geometry is measured and its required views report ready. The hold
returns before replacing the settled window or promoting the departing
strip. A target still halts the engine before this check.

Previously an animated jump could start with a partial destination window.
Later rows covered the old strip, which stayed beneath their transparent
areas until its departure deadline. `FarJumpCoverageTests` gates the fourth
100-point destination row of a 400-point viewport in every engine. Before
the source change it failed the hold, coverage and stale-strip overlap
checks in all three engines. After the change these checks and eventual
departure cleanup pass; all 183 UIKit tests pass. Cleanup waits for the
existing real-time completion fallback when the test pauses layer time.

No Lean definition changes. `Readiness` has no transitions: how a call
ends is an input, so `applies_latest`, `stale_noop`, `later_gen_lt` and
`resume_applies` hold for animated holds as they are. The destination
predicate, literal pixel coverage, measurements and UIKit readiness remain
outside it. The requested animation starts with its full duration when the
hold ends; tap-to-motion latency and rows mounted beyond the initial
destination margin during travel require interaction evidence.

Pending-target behaviour that animated jumps now reach, unchanged by this
commit and not covered:

- A successful pass without its own `scrollTo` takes the held target
  (`target = scrollTo ?? pendingTarget`, :404) and applies it, and a pass
  that changes the collection skips the destination check (`!changesCollection`,
  :519). So a mutation applied while a jump is held performs the jump at
  once, without waiting for coverage (`pass_takes_held`), and on the
  mutation's transition. The held target is an index, so after rows are
  inserted or removed before it, it names a different row. A pass with its
  own target replaces the held one (`applies_latest`).
- A touch or a drag doesn't cancel the hold: `didTouchDown` and
  `handleDragBegin` (:179, :231) leave `pendingTarget` and `pendingScroll`
  as they are, so the readiness observer still resumes the jump (:545),
  and that pass halts the engine (:368).

## Placing transformed row views at `460d78f`

`Proofs/UltraProofs/List/Placement.lean` relates the list's content
coordinates (a row's frame top, which the `Pass`, `Window` and `Insets`
models compute) to the layer position UIKit draws from, for row views whose
layer anchor point is the top-left corner and whose transform may flip them
(an inverted list's rows, `scale(1, -1)`). At `746e713` carries and detached
views were moved through the frame setter; `2b33902` moves them through the
layer position. UltraListView.swift lines are at `460d78f`, which moved
them but changed no placement logic (unchanged through `0ef4e78`).

| Model (`Proofs/UltraProofs/List/Placement.lean`) | Swift |
| --- | --- |
| `offsetY`, `frameTop` | `ListRowView.placementOffset(size:)` (ListRow.swift:81-84); the frame getter, the transformed bounds' box |
| `place` | `ListRowView.place(in:)` (ListRow.swift:76-80), also for attachment views (UltraListView.swift:1340) |
| `retarget` | `carry.view.layer.position.y += next - oldY` after reading `frame.minY` (UltraListView.swift:587-589); at `460d78f` a size-only pass (`preservesMoveClock`) writes the position and keeps the move's track |
| `moves` | `child.layer.position.y += delta` in `shiftDetached` (:1014); carousel strips (:1156) |
| `replans` | the carried rows across passes: each pass's endpoint is the view's `frame.minY` (:519), `CrossingPlanner.infer` plans its next top (:522), and `retarget` writes it |
| `Setter`, `write`, `writes`, `setterReplans` (a structure field: UIKit leaves the setter undefined under a transform) | `UIView.frame`'s setter, as the same sites used it at `746e713` (:524, :917) |

- `place_exact`, `translate_exact`, `retarget_exact`: `place(in:)` and
  moving `layer.position` by `next - frame.minY` land the frame exactly
  where the models put it, flipped or not.
- `replans_follow`: over any number of passes, whatever the planner, a
  carried row moved through its position is on the planner's result at
  every pass, flipped or not. `moves_exact`: `shiftDetached`'s moves add up
  exactly. `stream_carry_fixed`: five stream passes that replan a 140-point
  row in place leave it on its plan.
- The `746e713` baseline: `setter_drifts`, `writes_drift`: each frame write
  through the setter moves a flipped row `h` past the requested top;
  `setter_exact_iff`: it is exact only for unflipped (or empty) rows.
  `setter_replans`: through the setter a flipped carried row follows
  `plan · - h`. `stream_carry_drifts`: the five stream passes left it 700
  points off its plan, about one row height per token, as the Send traces
  showed (+129.5 and +138.8 for 140-point rows, 90 to 107 for 116-point
  rows, with the plans' own motion on top).

Ghost and carousel wrappers have the anchor at the top-left and no
transform; their bounds and position are now set separately (:1058-1059,
:1136, :1161, :1169-1170), and `place false` is the identity on their top.
The `Pass` theorems about carries and departures (`detached_fixed`,
`scroll_carry_fixed`, `inserted_once`) are about frame tops and hold for the
Swift through `retarget_exact` and `moves_exact`.
`Tests/UltraViewUIKitTests/CarryContinuityTests.swift` checks an outgoing
row stays beyond its loaded neighbour through stream revisions during a
Send, for every engine, normal and inverted rows. The setter hypothesis is
the observed behavior, not documented API.

## Swipe actions at `76eab99`, guarded at `dc430c2`

`Proofs/UltraProofs/List/Swipe.lean` models the pure decisions in
SwipeReveal.swift, which last changed at `76eab99`, and how the controller
(UIKit/SwipeActions.swift at `a489e36`) drives the registry. Distances are
rationals.

| Model (`Proofs/UltraProofs/List/Swipe.lean`) | Swift |
| --- | --- |
| `Axis`, `dominant`, `decide` | `GestureAxis`, `AxisLock.decide(dx:dy:slop:)` (SwipeReveal.swift:15-18) |
| `step` with `Op.update`, `Op.force` | `AxisLock.update` (:20-23), `force` (:25-30) |
| `release`, `projection` | `SwipeRelease.decide` (:104-108), `projection` (:101) |
| `threshold_above_half` | `SwipeRevealLayout.fullSwipeThreshold` (:54-58) |
| `begin`, `settle`, `remove` | `SwipeRegistry` (:196-209) |
| `C`, `cstep` | the controller's `registry`, the rows with a reveal, and the rows animating closed: `begin` settles the returned row closed (SwipeActions.swift:110, :492); `settle` (:214-234); a closing animation's `finish`; `remove` in `release`, `settle` and `reconcile` (:199, :215, :393-409) |

- `lock_keeps`, `lock_run_keeps`: once decided, every later `update` and
  `force` returns the same axis, for any translation. `run_none_iff`: from
  no axis, `update` returns nil exactly while every sample stays within the
  slop disc. `run_first`: the first sample past the slop decides, by its
  dominant axis; `dominant_tie`: a tie goes vertical. `decide_symm_x`,
  `decide_symm_y`: mirroring either component keeps the decision.
- `release_monotone`: more reveal and more opening velocity never give a
  lower outcome; it holds for any threshold, without the threshold being
  past half the open width. `release_full_iff`: a full swipe exactly when a
  threshold is present and reached. `release_open_at_rest`: at zero
  velocity a row opens exactly from half the open width up to the
  threshold. `threshold_above_half`: the layout's threshold
  `max(openWidth + 48, rowWidth * 0.55)` is past half the open width.
- `begin_active`, `begin_closes`, `settle_keeps_open`, `settle_keeps_other`,
  `remove_keeps_other`: the registry's contract.
- `inv_run`, `one_open`: every row with a nonzero reveal is the active row
  or one animating closed, after any sequence of begins, settles, finished
  closings and removals in which the caller closes what `begin` returns and
  settles open only the active row (`RunOk`); so at most one row is revealed
  and not closing. `guarded_inv`: with the pan guarded by the active row
  (`tracked(_:)` at `dc430c2`), that holds for every sequence of pan
  events, closes and removals, with no hypothesis on the caller.
  `unguarded_breaks`, `guarded_drops`: the sequence the chaos soak hit,
  without and with the guard.

**Gap from `a489e36` until `dc430c2`, found by the swipe agent's chaos
soak.** `RunOk` was read as the controller's: `release` settles the pan's
candidate, which its `.began` made active. But the pan keeps `tracking`
apart from the registry, and `close()` (a list pan, a tap, a performed
action or a VoiceOver action settling the row closed) or `reconcile`
dropping the row's actions clears the registry's active row while the pan
still tracks it; only a deleted row clears `tracking` (:397), and
`release`'s early return needs `reveals[x]` gone, which a close keeps. The
next `.ended` then settles a row open with no active row (chaos seeds 101
and 303). `unguarded_breaks` is that sequence. The fix (`dc430c2`) makes
the pan's `changed` and `ended` act only while `registry.active` is the
tracked row and drop the gesture otherwise: `T.acts` with `guarded`, and
`guarded_inv` proves the invariant over any sequence of pan, close, finish
and removal events with no `RunOk` hypothesis (`guarded_issues_ok`
discharges it).

| Model (`Proofs/UltraProofs/List/Swipe.lean`) | Swift at `dc430c2` |
| --- | --- |
| `T.tracking` | `ListSwipeController.tracking` (SwipeActions.swift:38) |
| `GEv.panBegin` | `beginTracking` (:132-139), from the pan's `.began` (:108) or `receiveInput`'s (:120, :123-126, only with no gesture tracked, the list still by `listIsMoving` :69, the row loaded and with actions or active): `registry.begin`, the returned row settled closed, `tracking` set. A refused begin is no event; `guarded_inv` holds for every sequence, so for the refused ones too |
| `T.acts true` | `tracked(_:)` (:152-156): the gesture on the row, while `registry.active` is that row; otherwise `tracking` is cleared |
| `GEv.panChange` | `continueTracking` (:140-143), from `.changed` (:109, :127) |
| `GEv.panEnd` | `endTracking` (:144-148), from `.ended` and `.cancelled` (:110-111, :128-129): clears `tracking` and calls `release` (:230-240), which settles the decided outcome, or removes the row from the registry when it has no reveal |
| `GEv.close` | every closed settle (`settle`, :246-266): `close()` (:60-61), a tap, `perform` (:241-245, including VoiceOver's custom actions and a full swipe's action), `begin`'s returned row (:134) |
| `GEv.remove` | `registry.remove` in `reconcile` (:425-441: a gone view, a deleted row, a replaced view, no actions left) and in `settle`/`release` for a row with no reveal (:231, :247) |
| `GEv.finish` | a closing animation's completion calling `finish` (:257-261, :269) |

A deleted row also clears `tracking` in `reconcile` (:429); with the guard
that is redundant, since the next sample finds the row inactive. The test
hooks `simulateDrag` and `simulateRelease` (:528-535) go through
`continueTracking` and `endTracking`; `simulateBegin` (:523-527) sets
`tracking` without the first `track` and is `panBegin`. Chaos seeds 101 and
303, the `unguarded_breaks` sequence, run with no violation at `163e3f0`.
Gesture delivery, the reveal's rubber band and spring
(`displayed`, `SwipeMotion`) and the buttons' spans are outside the model.
At `a489e36` the controller refuses a touch while the list moves
(`shouldReceive`) and counts size position layers as neighbour motion in a
collapse; neither touches the registry, so the rows above still hold.
`ListRubber.rubber_unrubber` covers `displayed` and `proposed`.

## Content inside an animating row at `163e3f0`

`Proofs/UltraProofs/List/Content.lean` proves that inner node frames on the
row's own height timing, with running inner animations moved onto each new
row timing from their presented values, keep a constant inset from the
row's edge at every frame. A `Track` is one scalar of a frame (a
`CABasicAnimation` interpolates a `CGRect` or `CGPoint` value componentwise
with one progress); an edge in row coordinates is a sum of such scalars on
one timing, which is again a track on it. (First mapped at `44f8a0c`; the
per-axis retiming and the moved content are `163e3f0`'s, the late join is
`4f3d0fa`'s, and line numbers are as of `3ffd162`, where the mapped code
is unchanged apart from `237be64`'s early return for appearances, covered
in the viewport profile's section.)

| Model (`Proofs/UltraProofs/List/Content.lean`) | Swift at `3ffd162` |
| --- | --- |
| a `Track`'s `start`, `transition` | a `CABasicAnimation`'s begin time, duration, speed and curve or spring, held by `NodeAnimationTiming` (NodeTransitionAnimator.swift:11) and copied by `animation(_:from:to:)` (:104) |
| `Shared` | `NodeAnimationTiming.isTiming(of:)` (NodeTransitionAnimator.swift:81): same begin (within 1e-6), duration, speed, offset, and curve or spring |
| a new timing at `t0` | `NodeRowLayer.add` (NodeRowTransition.swift:21-31) reporting the list's height or width animation to `NodeRowMotion.rowDidAnimate` (:148-162), which takes its timing only when `beginTime == 0` (added in this transaction, so it begins at the commit) |
| `retime`, `retimes` | `NodeTransitionAnimator.retime(root:_:axis:)` (NodeTransitionAnimator.swift:348-367), called through `retimeTransitions` from `rowDidAnimate` (NodeRowTransition.swift:154-161): every transition animation under the root not on the timing restarts toward its `toValue`; with an axis, x or y key paths of the other axis are skipped (:353) |
| `retime`'s `tr.value C t0` | the start value: the presentation layer's value (:357-358); `retime_unstarted`: an animation with `beginTime == 0` has not started and restarts from `fromValue` (:355-356) |
| `retime_same` | the `!timing.isTiming(of: running)` skip (:352) |
| the row's track restarted from its presented value | `ListAnimationModel.transition` (ListAnimation.swift:247; the controller has not called `retime` since `460d78f`) with the height resumed from the row's presentation captured at the pass's start (`capturePositions`, AnimationController.swift:44-57, `resumeValue` :269-270) |
| a track that continues unchanged | `value(...)`'s carrier copy (NodeTransitionAnimator.swift:441-456): a new tree's layer takes the old layer's running animation when it ends at the same value |
| `Axis`, `onAxis` | `TransitionAxis(keyPath:)` (LayoutTransition.swift:236-248): `position.x`, `bounds.size.width`, `bounds.origin.x` horizontal, the `y` and height paths vertical, anything else none; `rowDidAnimate` takes the axis from the row animation's key path (NodeRowTransition.swift:158), and `retime` skips key paths of the other axis (NodeTransitionAnimator.swift:353), so each axis's key paths see only its own row animation's retimings |
| `axes_keep` | the two filters together: x and y insets each through `retimes_keep` on their own row animation |
| `shift` | `TransitionShift.start(from:to:target:)` (LayoutTransition.swift:254-259), `from + (target - to)`, applied by `NodeTransitionAnimator.shift(root:from:)` (NodeTransitionAnimator.swift:373-396): a copy of the old view's running animation (same begin, duration, speed and curve) on the matching new view, from that start to the new model value |
| content replaced with no timing | `NodeRowMotion.show`'s `else` branch (NodeRowTransition.swift:122-128): `replacementTiming()` is `nil` (an immediate pass, or one whose time is up), so `NodeHostView.continueTransitions(from:)` (NodeHostView.swift:317-322) calls `shift` |
| the row's moved track | `ListAnimationModel.transition`'s immediate branch (ListAnimation.swift:236-244): `from + new - to`, same start and transition, which is `shift` of the row's height |
| `joinStart` | `TransitionJoin.start(shown:to:progress:)` (LayoutTransition.swift:264-271), applied to every numeric `from`/`to` pair a joined timing builds (`animation(_:from:to:)`, NodeTransitionAnimator.swift:109-111; `joinProgress` :14-16, set by `joined(at:)` :51-56, which clamps it to `[0, 0.999]`) |
| the join's `p` (`valueProgress_eq`) | `NodeRowMotion.progress(of:on:)` (NodeRowTransition.swift:193-198): `(shown - from) / (to - from)` of the row's running height animation on its own key path, read from the presentation; `nil` when the row moves less than half a point or has no presentation |
| `join_remap`, `join_within` with `Curves.Bounded` and forward progress | `replacementTiming`'s join (NodeRowTransition.swift:175-181): the row's own timing joined at `p` when `staysWithinItsEnds` (NodeTransitionAnimator.swift:59-79) and `p < 0.98` |
| `bezier_mono`, `bezier_bounded`, `solved_mono` | `staysWithinItsEnds` for a basic animation: control points 1 and 2 with `y` in `[0, 1]` (no timing function is linear) |
| `catchup_ends` | otherwise (:182): a 0.15 s ease-out of its own, from the content as shown (`s`) to its layout (`T`) |

- `edge_lerp`, `edge_constant`: on one timing, a child edge minus the row
  edge is `(1 - p) * d0 + p * d1`; equal end differences make it constant.
- `retime_keeps`, `retimes_keep`: restarting both from their presented
  values toward their targets on a new timing, any number of times, keeps a
  constant inset at every frame. `retime_unstarted` and `retime_same` show
  the Swift's two special cases are that same step.
- `alone_drifts`: retiming the row alone, with a 10-point inset bubble left
  on its timing, overlaps the row's edge by 2.5 points at 1 s.
- `axes_keep`: x key paths retimed only by the row's width animation and y
  key paths only by its height animation keep both insets through any
  interleaving. `last_wins_drifts`: moving all content onto the last one
  added (the Swift before `163e3f0`) puts the bubble 35 points off instead
  of 10 at 1 s in the sample.
- `shift_value`, `shift_keeps`: content replaced with no timing, each
  running animation moved by its own destination's change on its own
  timing, is the old motion plus that change at every frame, and keeps the
  inset with the row moved the same way. `row_only_off`: moving only the row
  (before `163e3f0`) left the inset off by the row's change.
- `join_jump`, `join_exact`, `shift_sample`: content joining a running
  animation (below).

Both start values are read from the same rendered frame: the inner one from
its presentation layer in `retime`, the row's from the presentation captured
at the pass's start, in the same main-thread turn. Where a layer has no
presentation yet, `retime` uses the value its carrier showed when the
animation was copied (`shownKey`, :359-360), else `fromValue`; the model
assumes that is the value at `t0`. Not covered:

- content that arrives after its pass (`replacementTiming`,
  NodeRowTransition.swift:166-190) joins the running height animation at its
  phase. Before `4f3d0fa` it started from the old tree's snapshot:
  `edge_lerp` holds (one progress), but
  its start inset is the snapshot's, not the row's at the animation's begin,
  so `edge_constant` does not apply; with no running height animation it
  animates over the pass's remaining duration while the row's height is
  still. `join_jump`: at the join the content shows `s + (T - s) p`, a jump
  of `(T - s) p` from the snapshot `s`; `join_exact`: a start of
  `(s - T p) / (1 - p)` would show `s` there. Only the late path (pre-render
  timeout, a row not live) takes this branch. At `4f3d0fa` (rows above) the
  content joins with that start when the row's timing can't overshoot, so
  it shows `s` at the join and the row's remaining progress rescaled after
  (`join_remap`), within `[s, T]` (`join_within`); otherwise it catches up
  over 0.15 s (`catchup_ends`), off the row's clock until then. A clamp of
  the start to `[s, T]` would have changed nothing: the start lies beyond
  `s`, away from `T`, and inside only when `p = 0` or `s = T`
  (`joinStart_beyond`, `joinStart_inside_iff`, `clamped_is_snapshot`,
  `clamped_jump`). Assumptions and what stays outside:
  - a spring with `initialVelocity == 0` and damping at least `0.99` of
    critical is taken not to overshoot. A ratio of 1 or more from rest
    doesn't (that needs the exponential, so it is an assumption); at 0.99
    it overshoots by about `e^-22`, times `1 / (1 - p) <= 50` since
    `p < 0.98`, under `1e-8` of the move. The list's springs are critical
    (`smoothDeceleration`) or within `1e-5` of it (`keyboardSpring`,
    555.027 / 47.118);
  - `solved_mono` needs the control points' `x` in `[0, 1]`, which Core
    Animation requires of a timing function;
  - `p` and `s` are read in the main-thread turn, the content's animation
    shows from the next frame on, at that frame's progress: continuous by
    `join_remap`, since it holds at every time;
  - every key path joins at the height animation's `p`. A vertical row
    whose width runs on another timing gives its content's x the height's
    phase, as `last_wins_drifts` describes for retiming;
  - colors and transforms are not remapped and keep the jump; they set no
    edge;
  - tests: `joiningPartwayShowsTheCurrentValueAndCoversTheRestInStep`
    (Linux, `clamp_sample`'s 90 to 140 at `p = 0.5`),
    `contentJoiningARunningTimingStartsWhereItIsShown` (simulator: 88 at the
    join, 118 at three quarters, 148 at the end) and
    `overshootingSpringsAreTold`;
- in `shift`, a child whose parent is unmatched: positions carry only
  within a matched parent (NodeTransitionAnimator.swift:379-384), so its
  position lands at the new value while the row still moves, outside
  `shift_keeps`. Its size, opacity and radius still carry. Values that are
  not single numbers (colors, transforms) land, which has no inset
  consequence;
- `shift` needs nothing about where the old animation came from: a
  non-additive `CABasicAnimation` shows `fromValue + (toValue - fromValue)
  * p` on its own timing, retimed or carried or not, which is the `Track`
  it shifts. A key whose carrier has no running animation, or whose values
  are not numbers, lands;
- axis-less key paths (opacity, corner radius, the ghost's and the reveal
  bands' opacity) follow every retiming, so with width and height on
  different timings the last one wins for them; they set no edge, so no
  inset depends on them;
- a turned row (the cards across) reports its width under the height key
  with key path `bounds.size.width`; the axis comes from the key path, so
  its content's x follows it. `ElasticResizeTests` checks both directions;
- springs and curves past their duration: `Track.progress` is 1 from the
  deadline on, the model's reading of `CASpringAnimation.duration`.

## Departure blocks at `460d78f`

`Proofs/UltraProofs/List/Departures.lean` models `DepartureLedger`
(DepartureGeometry.swift, unchanged since `e0a2c2c`). The list's calls pin
UltraListView.swift at `460d78f` (unchanged through `0ef4e78`). Block ids and row identities are numbers,
coordinates rationals.

| Model (`Proofs/UltraProofs/List/Departures.lean`) | Swift |
| --- | --- |
| `Edge`, `Witness`, `Block` | `BoundaryEdge`, `DepartureLedger.Witness`, `.Block` (DepartureGeometry.swift:3-25) |
| `insert` | `insert(_:)` (:28); its precondition is the model's guard, and the list's ids come from `serial` (UltraListView.swift:1049, :1061) |
| `walk`, `link` | `link(_:to:edge:)` and its loop over `seen` (:29-42), with the loop bounded by `fuel` |
| `bound`, `solve` | `targets(rows:)`'s `solve` (:43-60); `solve 0` is the `visiting` guard's value |
| `promote` | `promoteToViewport(_:offset:)` (:63-66) |
| `modify` with `setRoot`, `close`, `shift`, `finish`, `addMember` | `setRoot`, `seal`, `shift(by:)`, `finishMember`, `addMember` (:61-75) |
| `drop` | one removal of `collect()`'s loop (:76-83) |
| `Op`, `run` | the calls in UltraListView.swift: `makeDepartures` (:1061, :1081-1082), `updateGhosts` (:1104-1138), `shiftDetached` (:1015), `promoteCarousel` (:1159-1161) and `departAttachment` (:1310, :1319-1320) |

- `inv_run`: after any sequence of these operations from an empty ledger,
  every chain of carriers ends (`Inv.acyclic`) and every carrier exists
  (`Inv.closed`). `link_inv` rests on `walk_sound`: the loop accepts a
  carrier only when its chain ends without reaching the block being linked.
  A Swift link that accepts after `n` steps is the model's with fuel
  `n + 1`; one that rejects is the model's with any fuel.
- `no_cycle`: no chain returns to a block on it, so `targets`' `visiting`
  guard never fires. `stable`, `resolves`: each target is fixed after
  finitely many steps of the recursion, so the memo holds the recursion's
  value whatever order `blocks.keys.sorted()` visits.
- `weld_block`, `weld_row`: a block's riding edge (`localTop` or
  `localBottom` by its `edge`) lands on its carrier's resolved edge, or on
  its witness row's edge. `keeps_root`: with no witness, or a witness row
  outside `live`, it stays at its root. The list then animates each block
  from its old root to that target on the pass's timing
  (UltraListView.swift:1134-1138), and
  `ListPass.ghost_follows_witness` gives that the block moves with what it
  rides at every frame when the witness's track shares the timing.
- `collect_empties`: once every member has finished, a stopped `collect()`
  leaves no block, so no wrapper outlives its rows.

Which witness `updateGhosts` picks (the predecessor survivor, a matching
inserted row, the nearest row on the anchor's side) is the list's choice and
not modeled; the theorems hold for every choice. Member fades finishing is a
hypothesis (`finished`).

## Rubber banding and re-anchored drags at `1768f72`

`Proofs/UltraProofs/List/Rubber.lean` models the rubber band and its
inverse (ScrollMath.swift), the drag that uses them, and the re-anchor the
list runs when a pass changes the edges during a drag and the axis runs
when a drag begins. `1768f72` adds the adapted drag range the `adapt`
theorems describe. Swipe reveals use the same pair (SwipeReveal.swift at
`76eab99`). ScrollMath.swift lines are at `1768f72`.

| Model (`Proofs/UltraProofs/List/Rubber.lean`) | Swift |
| --- | --- |
| `band`, `rubber` | `ScrollMath.rubberBand` (ScrollMath.swift:25-31); `0 < r` stands for `range > ulpOfOne` |
| `unband`, `unrubber` (`cap` is `1 - 1e-6`) | `ScrollMath.inverseRubberBand` (:32-38) |
| `Drag`, `drag` | `ScrollAxis`'s `anchor`, `proposed`, `offset` (:55, :58-59) and `drag(translation:)` (:72-75), banded with `dragRange` |
| the range `drag` and `reanchor` share; `adapt` | `dragRange = max(range, expandedDragRange ?? range)` (:60-61); `reanchorDrag` sets `expandedDragRange = max(dragRange, 2 · distance)` when `distance > dragRange · (1 - 1e-6)` (:87-92) |
| `reanchor` | `ScrollAxis.reanchorDrag()` (:85-95), with `dragRange` after the expansion; called by `UltraListView.applyChanges` after `setEdges` and `shift(by:)` when `absorbsEdgeChangeIntoOverscroll` (UltraListView.swift:504) |
| `begin_catches`'s drag `⟨o, o, o⟩` at translation 0 | `beginDrag()` (:68-71): resets the range, puts anchor and proposed at the shown offset, then `reanchorDrag()` |
| the range reset between drags | `resetDragRange()` (:96) from `beginDrag`, `release` (:77) and `ScrollCore.touchDown` (ScrollCore.swift:20) |
| `rubber_unrubber` with the swipe's edges | `SwipeRevealLayout.displayed` / `proposed` (SwipeReveal.swift:62-71), and the replayed drag's inferred anchor (GestureRecording.swift:41) |

- `band_bounds`, `band_mono`: the shown overscroll is in `[0, range)` and
  grows with the drag.
- `rubber_unrubber`, `unrubber_rubber`: within the cap the two are inverse,
  so catching a revealed row in motion, or replaying a recorded drag, starts
  from what is shown.
- `reanchor_no_jump`: after an edge change and the re-anchor, the drag's
  current translation shows the offset shown before it, for any new edges,
  provided the shifted offset is within `range * cap` of its new edge. The
  next finger movement continues from there. `reanchor_idle`: with
  unchanged edges a re-anchor is a no-op, so passes that re-anchor during a
  drag never drift it.
- `reanchor_capped`, `capped_jump`: with a fixed range, when the shifted
  offset is farther than `range * cap` past the new edge, the next drag
  sample jumps to `range * cap` past it: with a 400-point viewport and an
  offset 500 past the edge, by just over 100 points. This was the Swift
  before `1768f72`.
- `adapt_covers`, `adapt_no_jump`: with the range adapted as `reanchorDrag`
  does, the cap always holds and nothing jumps, whatever the overscroll;
  `adapt_example`: 500 points past the edge in a 400-point viewport bands
  with 1000 and stays at 500. `adapt_idle`: within the cap the range is
  unchanged, so ordinary drags band as before. `adapt_ge`: the range never
  shrinks within a drag, and `drag` uses the same `dragRange`, so
  `reanchor_idle` holds with it. `adapt_depth`: the band's slope there is a
  quarter of its slope at the edge, so the content keeps following the
  finger.
- `begin_catches`: a drag that begins on overscrolled content shows the
  caught offset at once, however far past the edge; it is `adapt_no_jump`
  at translation 0. `begin_unanchored_jumps`: without the re-anchor
  `beginDrag` now runs, the first sample would show less overscroll than
  was caught (for coefficients at most 1; the Swift's are 0.55 and 0.715).

The shift before the re-anchor (`ScrollAxis.shift(by:)`, :84) moves offset,
anchor and proposed together, so the model's `Drag` is the state after it.
Gesture delivery (that the next sample repeats the current translation when
the finger has not moved) is outside the model. The replay's inferred anchor
uses the base range; recorded drags never re-anchor, so their range is the
base one.

## Deceleration frame by frame at `1768f72`

`Proofs/UltraProofs/List/Decel.lean` models the coast and spring branches
of `ScrollAxis.step(milliseconds:)` (ScrollMath.swift; `step` is unchanged
since `b82d7b9`), apart from the step that crosses an edge.

| Model (`Proofs/UltraProofs/List/Decel.lean`) | Swift |
| --- | --- |
| `coast` | the inside branch of `step` when the destination stays inside (ScrollMath.swift:107-111): `offset + v·rate·(1 - decay)/(1 - rate)·multiplier`, `velocity *= decay` |
| `spring` | `spring(milliseconds:)` (:127-131) |
| `Decay` (structure fields: `pow` of a sum is the product) | `pow(rate, dt)` and `pow(0.99, dt)` for `dt ≥ 0` |
| `coasts`, `springs` over frame lengths | the stepped engine's display-link steps (UIKit/ScrollEngine.swift:288, at least 1/120 s), and the `1/120` s steps of `ScrollTrajectory(baking:)` (ScrollTrajectory.swift:16-27) that the keyframe engine plays and the stepped engine predicts coverage from (ScrollEngine.swift:249, :253) |

- `coast_frames`, `spring_frames`, `engines_agree`, `springs_agree`: steps
  compose, so frames of any lengths with the same total time give the same
  offset and velocity. The stepped engine's frames and the baked
  trajectory's vertices agree exactly at every time both reach, while both
  coast inside the edges or both spring toward the same boundary: the
  motion does not depend on the display's frame rate.
- `coast_monotone`, `coast_rest`: a coast never reverses or speeds up and
  never passes `o + v·rate·m/(1 - rate)`. `coast_between`: a frame between
  two others of one coast lies between their offsets, so splitting a coast
  that stays inside the edges never takes another branch, and a frame
  between two baked vertices lies between them.

Not covered: the step that reaches an edge interpolates its coast time
linearly in the offset (:112-118), so where it switches to the spring depends
on the frame lengths; and the settling frame (`|v| < 0.01`, then a snap of
at most half a point, :121-122) depends on them too. The engine's
settlement scheduling (`settleIfNeeded`, added in `1768f72`) is not modeled.

## A cancelled keyboard dismissal at `f683c2f`, followed up at `44e5d85`

`Proofs/UltraProofs/List/Return.lean` models the chat screen's
`KeyboardInsetGesture` (Sources/UltraViewDemo/List/KeyboardInsetGesture.swift)
and the controller calls that feed it (ListChatController.swift). A drag
that begins with the keyboard shown (more than half a point above its
resting height) snapshots the starting inset and keyboard height; one that
begins with it closed records nothing and never returns
(`begin_closed_never`). While the finger is down a tracked sample records
the inset unless its height matches the recorded target within half a
point; a keyboard animation with a duration records its target height, the
last one winning; zero-duration notifications record nothing. The release
resolves with the recorded target, or the guide's height without one. A
height within half a point of the starting one returns the content by
`start - latest`; one at most half a point above the resting height is a
dismissal; anything else waits for a later notification or layout.
Resolving clears the gesture, and a new drag replaces it.

| Model (`Proofs/UltraProofs/List/Return.lean`) | Swift at `f683c2f` |
| --- | --- |
| `G` | `KeyboardInsetGesture.Gesture` (KeyboardInsetGesture.swift:8-14): `inset`, `height`, `restingHeight`, `latestInset`, `pendingHeight`; `released` is `!isTracking` while a gesture is held (`awaitsOutcome`, :17) |
| `near`, `G.isOpen`, `G.isClosed` | `abs(_ - _) <= 0.5` (:28, :45) and `outcome(height:)` (:43-49) |
| `Ev.begin` and its guard | `begin` (:20-25), `height > restingHeight + 0.5`, from `keyboardDragBegan` (ListChatController.swift:203-207) in `willBeginDragging` (:89-94) with the composer inset, the guide's height and the safe-area bottom |
| `Ev.track`, `matchesTarget` | `track` (KeyboardInsetGesture.swift:26-31), from `keyboardDragChanged` (ListChatController.swift:208-213) with the applied inset (the new one if it moves by more than half a point, else the current one), which `keyboardTrackingLayout` (:175-185) reaches only while the input tracks (`list.isTracking && list.isDragging`, :167) |
| `Ev.outcome` | `keyboardOutcome` (KeyboardInsetGesture.swift:37-42) while the finger is down: a will-change notification with a duration (`keyboardFrameChanged`, ListChatController.swift:255-256), or a layout that is animated or comes with the input no longer tracking, whose guide is conclusive (`recognizesOutcome`, :178-181) |
| `Ev.release` | `end` (KeyboardInsetGesture.swift:32-36) from `keyboardDragEnded` (ListChatController.swift:214-219) in `didEndDragging` (:99-103), with the guide's height |
| `Ev.layout` | after the release: `viewDidLayoutSubviews`' `awaitsOutcome` branch (:169-170) into `keyboardGuideChanged` (:220-226), and a will-change notification with the finger up (:255-256, applied at :260) |
| `resolve`'s shift | `resolveKeyboardGesture` (:234-246): `.returned` turns `followsComposer` on and applies the starting inset with compensation (`applyComposerInset`, :187-193), so the content moves by `start - composerInset`, and `composerInset` is `latest` because each tracked sample applies the inset it records |
| `jump_as_outcome` | `keyboardTrackingLayout`'s first branch (:178): the guide's unanimated jump after the lift, with the input inactive and a conclusive height, is an outcome; a partial one is ignored (:182-183); with the input active it is a tracked sample |

- `resolution`: for every order of tracked samples, notifications and
  layouts around the one release, the returns are `verdict` of the last
  target before release (or the guide at release) followed by each later
  height in order: one return of `start - latest` if the first conclusive
  height is open, none if it is closed or none is conclusive.
- `open_once`, `closed_never`, `missing_recovers`: an open outcome returns
  exactly once; a closed release never shifts (so `ListMomentum`'s
  `dismissed_never_moved` still describes it); with no notification and the
  keyboard mid-way at release, the first layout that sees it open returns.
- `at_most_once`: a run never returns more often than it begins gestures,
  plus one for a gesture already running, so duplicated notifications and
  layouts after the return do nothing. `begin_fresh`: a new drag replaces
  the whole snapshot. `notify_keeps_latest`: only tracked samples change the
  recorded inset, so the return is the inset the finger took away.
- `jump_as_track`, `jump_as_outcome`: taken as a tracked sample, the jump
  sets the recorded inset to the start and the return is 0 (the cause of the
  reversal clips before `f683c2f`); taken as an outcome, as the controller
  now does, the release returns `start - latest`.

The Swift calls `end` once per `begin` (`didEndDragging` follows
`willBeginDragging`); the model ignores a second release. The models take the chat's
events as delivered; that the guide's moves reach the chat as layouts is
a hypothesis ("Keyboard guide delivery" below), which `44e5d85` broke and
`843e14a` restores with a view constrained to the guide. The return runs
the inset-only path with compensation and a screen move of
`start - latest`: `ListMomentum.keyboard_keeps_velocity` and
`run_keeps_velocity` (a flight is translated and keeps its velocity),
`follows_moves_by_inset` (the offset moves by exactly that much inside the
edges) and `ListPass.lockstep_iff` (in step with the composer when both use
one timing) cover it. Its timing (`keyboardReturnTransition`, :227-233) and
the composer bar's clock against it are not modeled; the commit records that
the rows lag the bar during the return.

**Gap at `f683c2f`: a touch while the outcome is awaited.** After a release
at a partial height the gesture waits (`awaitsOutcome`). A touch on the list
then sets `keyboardDragHasEnded = false` (:86-88), so `isTrackingKeyboard`
(:23) reads true while `keyboardGesture.isTracking` is false. An outcome in
that state still resolves the gesture, but `keyboardFrameChanged` returns
before applying it (`guard !isTrackingKeyboard`, :258) and
`keyboardTrackingLayout` discards it (`_ = keyboardOutcome`, :181); its
else branch also applies the bar's inset uncompensated (:184), so a later
resolution would not move by `start - latest` either. `touch_loses`: the
return is then lost for good, whatever notifications, layouts and releases
follow; `touch_drops` is the sample (a return of 100 becomes none). A new
drag in the waiting state replaces the gesture (`begin_fresh`), which drops
the waiting return as well; the new snapshot starts from the displaced
inset.

**The follow-up at `44e5d85`, lines as of `c5743ae`.** The rows below replace
the `f683c2f` table's for the files it changed.

| Model (`Proofs/UltraProofs/List/Return.lean`) | Swift at `c5743ae` |
| --- | --- |
| `G` | `KeyboardInsetGesture.Gesture` (KeyboardInsetGesture.swift:8-14); `released` is `awaitsOutcome` (:17) |
| `Ev.begin` | `begin` (:20-25) |
| `Ev.resume` | `resumeTracking(inset:)` (:26-32): only while `awaitsOutcome`; keeps the snapshot, sets the latest inset, clears the target |
| `Ev.track`, `matchesTarget` | `track` (:33-38), from `keyboardDragChanged` (ListChatController.swift:347-352), reached from `keyboardTrackingLayout` (:208-224) only while `keyboardInputIsTracking` (:201-207: the native pan began or changed with a touch on it, else the list tracking and dragging) |
| `Ev.release` | `end` (KeyboardInsetGesture.swift:39-43) from `keyboardDragEnded` (ListChatController.swift:353-358) |
| `Ev.outcome` | `keyboardOutcome` (KeyboardInsetGesture.swift:44-49) with the finger down: a notification with a duration (ListChatController.swift:422-423), or an animated or input-inactive layout with a conclusive guide (:211-216) |
| `Ev.layout` | after the release: the `awaitsOutcome` branch of `viewDidLayoutSubviews` (:192-193) into `keyboardGuideChanged` (:359-365), and a notification with the finger up |
| `dragBegin` | `keyboardDragBegan` (:331-346): the waiting slot applied first (:332-335), a waiting gesture resolved at the drag's height when conclusive (:336-338), then `resumeTracking(inset: composerInset)`, else `begin` (:342-345) |
| `resolve`'s shift | `resolveKeyboardGesture` (:387-408): `.returned` applies the start inset with `compensatesInsetChange: true` on `easeInOut(duration * remaining / full height)` (:392-401) |
| `Slot`, `SEv.defer`, `SEv.flush` | `finishKeyboardGesture` (:366-379): with no timing, `pendingKeyboardResolution` and a main-queue turn applying it on `.keyboard(0.25)`; a notification with a duration takes it (:424-427), a drag's begin applies it (:332-335); layouts apply no inset while it waits (:194, :221) |

- `touch_loses` was the gap at `f683c2f`. At `44e5d85` a resolution while a
  touch is down applies: `keyboardFrameChanged` applies it before returning
  (:444-447), and `keyboardTrackingLayout` passes it to
  `finishKeyboardGesture` (:213-216); while the gesture waits no layout
  applies the bar's inset (:221). The run is plain `step`, so `resolution`,
  `at_most_once` and `resume_resolution` describe it.
- Momentum: the model's `tracking` is a drag in progress. A return applied
  under a touch that has not become a drag compensates (forced, :401); the
  engine's `shift` moves the axis' offset, anchor and proposed offset
  together (ScrollMath.swift:84), so a drag that then begins starts where
  the content is. Resolutions never apply during a drag: the gesture is
  tracking then, and `keyboardOutcome` only records a target.
- Finishing: `finishViewportTransition()` (UltraListView.swift:260-264) is
  `Ev.finishViewport` (`finish_keeps_engine`). `applyComposerInset`'s
  `finishesAnimation` (`applyComposerInsetNow`, ListChatController.swift:231-237) removes the bar's
  animations and finishes the viewport track in one transaction, as an
  immediate inset change does (`list.applyChanges(..., .none)` with
  `removeComposerAnimations`, :253-264): `finish_together`. It runs for a
  notification whose begin and end frames are already off screen (:313-326)
  and on `didHide` (:328-330).
- Lockstep: `applyComposerInset` copies the viewport animation onto the
  bar's position and height (:254-260, `animateComposerProperty`
  :287-312), the same begin, duration and speed. A basic animation keeps
  its curve and goes from the bar's displacement to 0; a keyframe one (the
  keyboard's profile, below) takes the viewport's progress samples as
  `displacement · (1 - p)` (:295-296), or, with no profile in the
  transition, its own values rescaled to the bar's displacement (:297-298,
  `ListDeferred.normalize_affine`). Either way the bar and the viewport
  are on one progress, so `ListPass.lockstep_iff` applies; the bar's start
  includes the residual of its running animation
  (`composerAnimationResidual`, :272-286), read from the same curve or by
  the same linear interpolation of its values (:279-282).

What the follow-up's models say: `Ev.resume` keeps the first drag's start
inset, starting height and resting height, records the current inset as
the latest and clears the recorded target; `resume_resolution`: the gesture
then resolves as one that never lifted, against the first start, so an open
return restores the original inset; `resume_sample`: beginning afresh from
the displaced inset (the behaviour at `f683c2f`) never returns. `dragBegin`:
a waiting gesture the guide already decides at the drag's start is resolved
first (`dragBegin_open`: one return, then a fresh snapshot;
`dragBegin_closed`: the dismissal, no gesture), otherwise the drag resumes
from `composerInset`, which nothing changes while the gesture waits
(`dragBegin_partial`); `dragBegin_Q`: a drag begin adds at most one return.
`slot_once`: every resolution waiting a turn for its timing is applied
exactly once, in order; `begin_flushes`: none waits past the next drag.

Momentum rows at `c5743ae` (the section at `b896af1` maps the earlier
controller; `f683c2f`'s rows are superseded): `Ev.dragBegin` is
`willBeginDragging` (ListChatController.swift:111-116), `Ev.drag` the
`onUserScrollDelta` guard (:117-120), the layout check (:184) and a tracked
sample's (:350), `Ev.release` `didEndDragging` (:121-125), `Ev.keyboard`
`keyboardFrameChanged` (:409-459, a growing overlap with the finger up at
:415) and `applyComposerInset`'s `compensatesInsetChange` (:252: the
caller's, else `!isTrackingKeyboard && followsComposer`), and `Ev.explicit`
the hide button (:137), `textViewDidChange` (:462), `sendMessage` (:556)
and a resolved return (:395, applied with compensation forced on, :401). A
resolved dismissal (:405) turns compensation off and applies uncompensated
(:406), as the release does. `isTrackingKeyboard` (:31) is the gesture's
own tracking or the list's touch before `didEndDragging`. While a drag runs
every inset goes in uncompensated, so `tracking_never_writes` holds; a
return applied under a touch that has not become a drag is the one
compensated write with the finger down (above).

**Finishing the viewport track at `44e5d85`** (lines as of `c5743ae`).
`UltraListView.finishViewportTransition()` (UltraListView.swift:260-264)
replaces a running viewport track with one from 0 to 0 at once, re-renders
attachments and reports visibility, and makes no engine call; with no
track it does nothing. It is `Ev.finishViewport`: `finish_keeps_engine`
(the offset, the flight and its velocity, and every flag unchanged), and
`run_keeps_velocity` and `dismissed_never_moved` include it. The chat
calls it from `applyComposerInset`'s `finishesAnimation` (ListChatController.swift:231-237)
in the same transaction that removes the bar's animations, for a
notification whose begin and end frames are already off screen
(:313-326) and on `didHide` (:328-330): `ListPass.finish_together`
(landing both in one turn keeps their distance). `finish_alone`: landing
one leaves the gap off by `Δ (1 - q)`, the 90 points the bar's clock left
before, with the same-inset guard.

A running hide interrupted by that zero-duration notification lands at
once. `keyboardFrameChanged` with `finishesHide` (ListChatController.swift:409-412)
takes duration 0 and calls `applyComposerInset` with `.none`: if the
inset changes, the list's immediate inset change removes the viewport track
and `removeComposerAnimations` the bar's (:253, :261-262); if it doesn't,
`finishesAnimation` removes both (:231-235). Either way, in one
transaction: `interrupt_lands` (bar and content on their settled values,
so the bar is at the final inset) and `interrupt_keeps_gap` (the bar's
residual is a copy of the viewport's, so they share one; their distance
is the settled one before, at and after the land, on any curve, an
overshooting spring included: the jump is common). `interrupt_one_off`:
landing one alone leaves the gap off by what the other's residual shows
(`interrupt_sample`: 4.5 points with a 90-point residual overshot by 5%).
The engine's flight goes on: `finish_keeps_engine`, or for an inset that
changes `keyboard_keeps_velocity`. The shared residual holds while the
viewport's compensated move equals the inset's (`follows_moves_by_inset`,
content inside the edges); content held at an edge has its own.

## Elastic resize at `44f8a0c`

`Proofs/UltraProofs/List/Elastic.lean` covers a bubble that resizes with its
row: its background follows the row's width and height with a fixed corner
radius, and its text keeps its padding and crossfades. The demo opts in
(`animatesContent`); the core code is the node transitions at `44f8a0c`.

| Model (`Proofs/UltraProofs/List/Elastic.lean`) | Swift at `44f8a0c` |
| --- | --- |
| `bg m W H` | the card node's layer: `position.x`, `position.y`, `bounds.size.width`, `bounds.size.height` (NodeTransitionAnimator.swift:243-246) on the row's height timing (`rowDidAnimate`, see "Content inside an animating row"). With the card's edges at fixed margins from the row's at both ends, `ListContent.edge_constant` puts them there at every frame, so the card is `bg` of the row's presented size |
| `boundsCorners`, `bounds_round`, `bounds_rigid` | a layer-representable box (uniform radius and border): `layer.cornerRadius` is a model value, the same at both ends, and `scalar` adds no animation when it doesn't change (:253, :373-374, :391) |
| `slice`, `slice_bands`, `slice_seams` | any other box: drawn once at its final size with `ContentsPlacement.stretch` (Drawing.swift:49-66), bands as wide as the widest corner or border, applied as `contentsCenter` (CommitApplier.swift:290-292, :297) |
| `corners_fit`'s `2 * r` | Core Animation clamps a corner radius above half the shorter side, and shrinks nine-slice bands that don't fit; `stretching` leaves at least one pixel in the middle (Drawing.swift:59-61), so `2 * b < w1` holds at the final size |
| `textFrame`, `text_inset` | the text node's layer, with the same four animations, and `.top(alignment)` (Drawing.swift:48; CommitApplier.swift:283-289): contents unscaled against the top edge |
| `layered` | `fadeOut` (NodeTransitionAnimator.swift:436-462): the old bitmap as a ghost at sublayer index 0, over the view's own contents and under its children, `opacity` 1 → 0, at the new view's size; `reveal` (:406-431): the new bitmap through a mask, stable bands at 1 and new regions from `fromOpacity` to 1, all on the row's timing |

- `bounds_round`, `bounds_rigid`: resizing the bounds keeps every corner a
  quarter circle of radius `r` at any size, each moving as a rigid piece.
  `scale_distorts`: scaling the final background instead gives its corners
  `r * sx` by `r * sy`, which are `r` only at the final size.
  `slice_bands`, `slice_seams`: a nine-sliced box's bands move rigidly with
  its edges and meet the stretched middle, so its corners are the final
  bitmap's.
- `corners_fit`: with each clock a track on a curve that doesn't overshoot,
  a background at least `2r` wide and tall at both ends is at every frame,
  on any pair of timings, so the radius is never clamped.
- `text_inset`: under any clocks the text keeps its padding and its laid-out
  size. `text_fits`: a text that fits both ends fits at every frame.
  `overflow_lerp`: one that fits only the end (the new text of a growing
  bubble) would overflow by `(1 - p)` of the growth at progress `p`; the
  reveal mask fades new regions in instead.
- `stable_steady`, `ghost_shared`, `ghost_new`, `ghost_old`: stable lines
  show the new bitmap throughout, ink both texts share stays full while the
  old one fades over the new, new-only ink shows at once, old-only ink fades.
  `both_dip`: fading both would dim shared ink to three quarters at
  mid-fade.

Assumptions and gaps: `corners_fit` and `text_fits` need curves that don't
overshoot (`Curves.Bounded`); a `dampedSpring` row with an end exactly `2r`
tall can dip below it and clamp the radius for those frames. Text placed
`.top(.center)` or `.top(.right)` sits relative to the layer's animated
width, so it moves with the width clock; the model's `textFrame` is the
left-aligned case. A pixel's ink is a coverage in `[0, 1]`; antialiasing,
subpixel positioning and the reveal mask's band edges are not modeled.
`ElasticResizeTests` (at `621e7a1`, where the demo's cards opt in) checks
the same invariants in stopped time at six points of a resize, in height and
in width: card edges on the row's less the inset, title at the card's
padding, radius 16 with no bitmap, one revision shown.

## Text crossfade layering (the commit after `f6e590e`)

`layered` above takes the old bitmap at `1 - p` over the new one, and the new
one at `p` where it fades in. Through `3ffd162` the Swift didn't keep that:
`reveal` put its mask on the text view's own layer, and `fadeOut` put the
ghost in that layer's sublayers, so the mask covered the ghost too. A changed
region showed the old bitmap at `(1 - p) * p` and the new at `p`, together
`p * (2 - p)`: blank at the start, three quarters at mid-fade. A whole-line
rewrite (no stable band) went blank for the transition's first frames.

| Model (`Proofs/UltraProofs/List/Elastic.lean`) | Swift |
| --- | --- |
| `layered`, the new bitmap's part | `reveal` (NodeTransitionAnimator.swift:480-505) moves the view's bitmap onto a sublayer, `revealedLayer(of:)` (:516-536), anchored at the view's origin, with the view's size and its running size animations (`follow`, :553-563), and puts the mask on that sublayer. Commits applied meanwhile set their bitmap there (`contentsLayer(of:)`, :509-511; CommitApplier.swift:135-158), and when the reveal ends or is cancelled, `endReveal(on:)` (:539-548) puts the bitmap back on the view's layer |
| `layered`, the old bitmap's part | `fadeOut` (:571-611) and `carryGhost` (:615-630) put the ghost directly above that sublayer (`ghostIndex(in:)`, :634-638), outside the mask, under the view's children, with the view's size animations copied the same way. Parts of the old bitmap that were still fading in get mask bands at the opacity they were shown at (:583-606), so the ghost starts where the old view was |

The invariant, at every phase `p` of the transition's timing: where a line
changed, the old bitmap is shown at opacity `1 - p` and the new one at `p`,
so neither text is ever hidden; where it kept its start, the new bitmap
shows at 1 with no ghost over it; appended glyphs show at `p` with nothing
under them. A change that arrives halfway fades the older bitmaps out from
the opacities they were shown at and the newest in from 0, so the
opacities still add to 1. These are layer opacities, not ink: composited
source-over, a pixel where both texts have opaque ink shows
`1 - p * (1 - p)` of it, at least three quarters at mid-fade, and a pixel
inked in one text only shows that text's opacity. `TextCrossfadeTests`
checks the opacities in stopped time, reading each layer's presented
opacity times its ancestors' and their masks' alpha: a whole-line rewrite,
a kept first line with the next one rewritten, an append, a second change
halfway through (three hosts, as a list shows revisions), and a bitmap
applied while the text fades in. With the fix reversed, the changed point
read old `(1 - p) * p` exactly (0.25 at `p = 0.5`) and the tests failed.

Not modeled: a ghost's mask keeps the old size while the ghost follows the
new one; its bands reach far past both, so only their `limit` (both sizes
and 40 points around) bounds them. `replica(of:)`, which keeps a node that
leaves while its text fades in, copies the bitmap but not the reveal mask,
so such a leaving text shows whole as it fades out (as before this
change).

## The keyboard's viewport profile at `926e692`

`Proofs/UltraProofs/List/Profile.lean` maps `926e692`'s clamp, with line
numbers as of `c5743ae`. The keyboard travels farther than the chat's
occlusion (the tab bar sits below the chat), so the composer's inset follows
the keyboard's overlap clamped at the resting edge, `max(resting, height)`,
and the viewport correction follows that clamped height through a sampled
progress profile, which the bar's animation copies.

| Model (`Proofs/UltraProofs/List/Profile.lean`) | Swift at `c5743ae` |
| --- | --- |
| `height r b e φ`, `max r (b + (e - b) φ)` | `KeyboardViewportMotion.height(at:)` (KeyboardViewportMotion.swift:10-12): `r` is the safe-area bottom, `b` and `e` the keyboard's signed overlaps with the chat from the notification's begin and end frames (ListChatController.swift:321-326, :430-431), `φ` the keyboard's physical progress |
| `prog r b e φ` | `viewportCurve(physicalProgress:)` (KeyboardViewportMotion.swift:14-20): `(height(φ) - height(0)) / (height(1) - height(0))` per sample. It returns `nil` (no profile, the ordinary curve) when the clamped travel is at most half a point, which gives the theorems' `height r b e 1 - height r b e 0 ≠ 0`, or when the samples don't start at 0 and end at 1 |
| the samples `φ_k` | `keyboardFrameChanged` (ListChatController.swift:428-440): 481 values of `ListCurve.keyboardSpring` at `k / 480`, the last set to 1; only for a curve-7 notification with a duration, the finger up, and no gesture outcome pending |
| `interp f0 f1 t` between samples | `ViewportCurve.value(at:)` (ListAnimation.swift:81-85): the phase scaled to `count - 1` even segments, linear between neighbouring samples. The compiled `CAKeyframeAnimation` (AnimationController.swift:376-382) has values `from + (to - from) p_k`, `.linear` calculation, no key times (so they are even) and no timing function, the same function on the same clock. The bar's residual reads its own values the same way (ListChatController.swift:279-282) |
| `Curves.start`; `Track.progress` 1 from the deadline | `ViewportCurve`'s precondition (ListAnimation.swift:78): first sample 0, last 1, all finite |
| the profile's hull as a `Curves.Bounded` curve's bounds | `progressBounds` (:86), which `AnimationTrack.valueBounds` uses for the coverage read (:143-148) |
| the viewport's offset only | `replace` gives a track the profile only for `(.viewport, .viewportOffset)` (:224-225), and `applyChanges` clears it unless the call changes nothing but the insets (UltraListView.swift:271-274). The immediate branch of `transition` (ListAnimation.swift:241-242), `residual` (:159-162) and `scaled(by:)` (:113-115) keep a track's profile |
| the bar on the viewport's progress | `animateComposerProperty` (ListChatController.swift:287-312) copies the keyframe animation (same begin, duration and speed) and sets its values to `displacement · (1 - p_k)` (:295-296) |
| one notification's profile | `keyboardTransition?.viewportCurve = nil` (:445): later layouts and gestures use the ordinary keyboard clock. A layout inside the notification's animation block (`viewDidLayoutSubviews`, :195) applies the same inset with the same transition, so the profile is applied once either way |

- `profile_exact`: at every sample the viewport and the bar are on the
  clamped keyboard edge. `profile_unit`, `profile_mono`: with the
  keyboard's progress in `[0, 1]` and moving forward, the samples are in
  `[0, 1]` and never go back, so the profile is a `Curves.Bounded` curve
  and its samples' hull (`ViewportCurve.progressBounds`) is the coverage
  read's range.
- `kink_bound`, `kink_bound_down`: between samples the interpolated clamp is
  never below the clamp of the keyboard's interpolated edge, in either
  direction, and is above it by at most a quarter of that segment's
  travel, only in the segment where the keyboard crosses the resting edge.
  A 335-point keyboard over 480 segments moves 0.7 points per segment on
  average, so the bound is under a point unless the crossing segment
  covers 4 points or more.

What the Swift keeps, checked against the models: only the viewport's
offset track takes the profile, and only on an inset-only pass, so the sync
theorems relating rows and the viewport (one progress) are unchanged, and
rows all move with the viewport, so relations among them don't depend on
its curve (`common_mode_cancels`). The bar's keyframes and the viewport's
share the samples, the key times and the clock, so `ListPass.lockstep_iff`
applies. Appearances of node rows revealed by a viewport moving on samples
land at their final state (`237be64`: `appearanceTiming` returns nil when
`NodeRowMotion.viewportMovesOnSamples(above:since:)`,
NodeRowTransition.swift:202-205 and :226-240, finds a non-basic viewport
animation added this turn), and a `.growing` appearance, whose start is in
window coordinates outside the list, lands while such a viewport animation
still runs at all (:291). The first is safe on any clock: within the
content the viewport's motion is common (`common_mode_cancels`). The second
is the relation to outside content that would need the viewport's own
progress (`lockstep_iff`), so landing it is the choice that keeps it.

Assumed, not proved: the samples are in `[0, 1]` and never go back.
`keyboardSpring` (ListAnimation.swift:36-37) has stiffness 555.027 and
damping 47.118, within 0.001 of critical: it rises from exactly 0 and its
first overshoot is more than two minutes away, so over a keyboard's duration
it stays below 1, and the caller's last sample of 1 is above the one before.
That the floating-point samples keep this order is the hypothesis.

Outside the model:

- `926e692` records an open value error: 2-3 isolated frames per engine where
  the bar and the keyboard differ by 1.8-2.9 points for 13-18 ms, on show at
  the first frame crossing the chat's bottom and on hide near peak
  acceleration. The models fix the sampled values and their interpolation.
  Between samples the chord never puts the inset below the clamp of the
  keyboard's interpolated edge, and differs from it only in the crossing
  segment, by at most a quarter of that segment's travel (above). That is the commit's own reading: the
  chord would advance the bar at the kink, so it can't explain a trailing
  frame. Whether Core Animation plays the keyframes on the same clock and
  frame phase as the system's keyboard animation, and whether
  `keyboardSpring` is the keyboard's actual curve, are not modeled; the
  error is in that part.
- Through `3ffd162`, an inset the list deferred (a call inside a pass,
  UltraListView.swift:276-279) left the bar copying the animation the
  earlier pass installed, and with a keyframe animation there and no
  profile in the transition the bar took the viewport's own offset values.
  `c5743ae` fixes both (the next section).

## Accessory updates deferred past a pass at `c5743ae`

`Proofs/UltraProofs/List/Deferred.lean` models `c5743ae`'s fix for the gap
recorded under the keyboard's profile. A call to `applyChanges` during a
list pass is queued and runs after it. Before the fix, the chat moved the
composer bar, called the list (queued), and copied whatever viewport
animation was installed, which was the earlier pass's. Now the chat queues
the whole update, so the list's inset change and the bar's copy run
together, and copied keyframes without a profile are rescaled to the bar's
displacement. SHA-256 at `c5743ae`: `UltraListView.swift`
`d5e39147faa14c9216beb7a51479cded7f3ccbd11dd5cf92b60e9f95c409b790`,
`ListChatController.swift`
`0432a9add257fef80ad819adda7bdcb7a4337c8e5fc9c884b3463e4f39e66fc7`,
`DeferredComposerInsetTests.swift`
`562412487f05f12d60f422cb3e2c83c3bbc274666107f6629bb1e5cdddca8ddc`.

| Model (`Proofs/UltraProofs/List/Deferred.lean`) | Swift at `c5743ae` |
| --- | --- |
| `S.passing`, `S.queue` | `passing`, `deferred` (UltraListView.swift:58, :60) |
| `Ev.finish`, `S.batch` | the end of a pass: `passing = false`, then the deferred operations dispatched as one block with `DispatchQueue.main.async` (:304, :315-318 in `applyChanges`; :785, :788-791 in `updateViewportInsets`; :824-829 in `handleScroll`) |
| `Ev.run` | the main queue running that block's operations in order, in a later turn outside any pass |
| `perform` | `performAfterCurrentPass(_:)` (:253-257): appends a closure that calls it again while `passing` (:254-255), else runs the update |
| `apply` | the chat's `applyComposerInset` (ListChatController.swift:225-229) passing `applyComposerInsetNow` (:230-266) to it: in one transaction the list's inset-only change (:253) installs the viewport animation, which the bar then reads (:254-255) and copies |
| `O.request`, `O.flush` | `3ffd162`: the same body run at once, with `applyChanges` queued inside it |
| `normalize` | `animateComposerProperty`'s second keyframe branch (:297-298): `displacement · (v - last) / (first - last)` when the values differ by more than `1e-6` |
| `a + b · p` | the viewport offset's keyframe values `from + (to - from) · p_k` (AnimationController.swift:378) |

- `shared_inv`: in every interleaving of passes, the running pass's own
  viewport animations, requests and main-queue turns, each applied update's
  bar copies the viewport animation the list installed for that update.
  `old_stale`: with the bar first and the list's part queued, it copied the
  previous one. So `ListPass.lockstep_iff`'s one-progress hypothesis now holds
  for an inset requested during a pass.
- `applies_idle`: updates apply only outside a pass. `once_inv`: every
  request is applied, queued or dispatched exactly once. `run_all`: once
  the pass has ended, the dispatched block applies the queued updates in
  request order.
- `normalize_affine`, `normalize_all`: whatever the copied viewport track's
  ends, rescaling its keyframes `a + b · p` (with `p` from 0 to 1, `b ≠ 0`)
  gives the bar `d · (1 - p)`: the viewport's progress with the bar's
  displacement, never the viewport's own values.

`DeferredComposerInsetTests` re-enters the chat from `onUserScrollDelta`
during a scroll pass and checks, in all three engines, that the bar waits
(:47), that its first keyframe is its own displacement (:57) and that the
row-to-bar gap holds at six phases in stopped time (:65).

Not covered:

- `overtake_sample`: ordering against updates that aren't deferred. An
  update requested outside a pass after the pass ended but before the main
  queue runs its block applies at once, and the queued one applies after
  it. The queued closure keeps the inset it was given and compares it with
  the current one only when it runs (ListChatController.swift:231), so if
  the keyboard's state changed in between, it reapplies the older inset.
  This review doesn't establish that a notification or layout can run in
  that window.
- The third keyframe branch (:299-303): a keyframe template whose values
  don't move (the viewport moved by less than `1e-6`) and no profile. The
  bar then takes 481 samples of the transition's own curve on the
  template's clock, while the viewport doesn't move.
- When the list's inset is unchanged (`updateViewportInsets`' guard,
  UltraListView.swift:780), the list installs nothing and the bar copies
  the running viewport animation. With the rescaling it is on that
  animation's remaining progress, which `normalize_affine` covers. Whether
  that animation's timing is the one the caller meant isn't modeled.
- That updates run atomically: nested passes inside `apply` are not
  modeled. Callbacks from the list's pass inside the update queue their
  own requests through the same path.

## Scroll to the top at `65db16e`

`65db16e` changes `UltraListView.swift` after the pins at `c5743ae`; its
SHA-256 at `65db16e` is
`fe10d6ba25eb58b5dbd5c40735150d9cf69c3a14dedf9f3d3399ac02985bd262`.
It adds `scrollToTop(animated:)`, an ordinary `applyChanges(scrollTo:)` with
a target that resolves when it applies, and a `didScrollToTop` report that
polls the list's state. Lines at `c5743ae` move by 5 from :154, by 46 at
:258, by 48 from :260, by 50 from :558 and by 53 from :814 (:174, :226,
:259, :261, :557, :813 and :1396 are the edited lines). The rows below are
at `65db16e`; no mapped value changes.

| Model | Change |
| --- | --- |
| `Ev.touch`, `Ev.dragBegin` | `didTouchDown` (:179) and `handleDragBegin` (:231) also bump `scrollToTopGeneration`, which only cancels a pending `didScrollToTop` report (:289-300) |
| `Ev.finishViewport` | `finishViewportTransition()` (:308-312) does nothing while the running viewport track is the one recorded as carrying a target's travel (`correctionCarriesTarget`, :301-303); otherwise it is unchanged |
| `Animation.swiftPass`, `Pass.screen` | the displacing pass records its viewport track's generation when the pass has a target, or when the track it replaces carried one and the correction it shows is more than half a point (:605-607); the replaced values are unchanged |
| `Insets.cheapSwift`, `Ev.keyboard` | `updateViewportInsets` records its new track only when the old one carried a target and the correction it shows is more than half a point (:864-866); `shift` and the replace are unchanged |
| `perform`, `apply` (`Deferred`) | unchanged: `performAfterCurrentPass(_:)` (:258-262), and the chat's `applyComposerInsetNow` still reaches the finish (ListChatController.swift:234) |

The record is a track generation (`targetCorrectionGeneration`, :158), so it
lapses when that track finishes or any writer replaces it, and a writer
that doesn't record leaves finishing as it was. A stale record never
matches a later track: `ListAnimationModel.generation` only increases
(ListAnimation.swift:189, incremented at :209, :221 and :240), and the list never calls
`AnimationController.reset()` (AnimationController.swift:305-310), the one
place that starts a new model. `promoteCarousel` records its own viewport
track whenever it animates (:1449). The half-point test reads the whole
correction shown, the target's remaining travel together with whatever
else the track carries. The report reads `pendingTarget` and
`pendingScroll` (`Readiness`' `S.pending`, `S.retry`) and writes neither.

The no-op leaves the engine as `Ev.finishViewport` does, so
`finish_keeps_engine`, `run_keeps_velocity` and `dismissed_never_moved`
still describe it. `ListPass.finish_together` doesn't apply while a target
travels: a scroll pass puts the viewport on its own curve, so content and
bar are no longer in lockstep, and when the keyboard reports it has hidden
the chat lands the bar while the content scrolls on (`finish_alone`'s gap,
here the rest of the scroll). The Lean model's `Ev.finishViewport` always
lands; the guard is not modeled. `ScrollToTopTests` and
`ChatScrollToTopTests` check it in UIKit: no jump at the finish, the scroll
lands on the top edge, and a correction that starts after the travel still
finishes at once. `Proofs/UltraProofs` is unchanged.

**Immediate inset changes during the travel at `c06d876`.**
The review above found that the guard covered `finishViewportTransition()`
only: an immediate inset change during the travel replaced the correction
with none (`from: 0` when immediate), so the target's remaining travel
landed at once. The chat applies immediate insets from tracking layouts
(ListChatController.swift:222, :351) and from a layout after typing, which
sets `keyboardTransition` to `.none` (:463, applied at :195), so a line
break typed during the travel landed it. `UltraListView.swift` at
`c06d876` has SHA-256
`e02b3c688db620c6ba55fd43584d48021ace7b3f91c9c91aaeaab967823eeee4`; lines
at `65db16e` move by 1 from :834, by 3 at :864 and by 6 from :867 (:836,
:863, :865 and :866 are edited).

| Model | Change |
| --- | --- |
| `Insets.cheapSwift`, `Ev.keyboard`; `ListPass.shownWith` with the engine offset as the settled value and the viewport correction as the residual | an immediate change while the running track carries a target with more than half a point shown (`keepsTravel`, :867-868) applies `shift` as before and leaves that track, its clock and its record as they are (:869-872); the deferred `handleScroll` then runs as for an animated change (:837). Any other change is unchanged |

So the content moves by the change's own `shift` at once and at every
later frame (`ListPass.keep_moves_by_shift`), and what is left of the
travel ends on its old deadline, at the new settled place
(`keep_lands_settled`, the correction ending at 0), which `cheapFixed`
decides as for any immediate change. Before, the change jumped by its
shift less the travel left (`land_jumps_travel`; `keep_sample`: 20 points
kept against a 280-point jump). Compensated on the
minimum edge (the test) that is the edge again. On an upside-down list's
maximum edge, the chat's oldest row, a grown top inset moves the content
with the composer and leaves it that far short of the edge, as typing
does at rest; `didScrollToTop` is then not called. With no target travelling, an
immediate change still lands everything, which is what `interrupt_lands`
and `interrupt_keeps_gap` describe. They don't describe a hide whose
correction had absorbed a target's travel (a keyboard change made during
the travel, recorded as carrying it): there the chat's zero-duration land
removes the bar's animations while the content keeps its correction, which
is on the bar's clock but carries the travel as well, so the gap is off by
that correction until it ends (`bar_lands_content_keeps`,
`interrupt_one_off` the other way round). The Lean `Insets` and `Return`
models don't have target travel, and `ListPass`'s lemmas are the
correction's arithmetic only; the rest is checked in UIKit by
`ScrollToTopTests.anImmediateInsetChangeDuringAScrollToTheTopLeavesItRunning`
(the travel left is unchanged across the change, the track still runs, it
lands where the list settles, and with no travel an immediate change still
removes the track), in all three engines, compensated or not.

Not covered: a structural pass with an immediate transition and no target
that displaces (a width or environment change, `applyChanges(newSize:)`,
UltraListView.swift:208) still replaces the correction with none, so a
rotation or appearance change during the travel lands it, along with
everything else that pass relays out.

## The bubble chat at `32bf281`

The chat shows bubbles (`ChatBubbles.swift`) unless a chaos run or
`-chatCards YES` asks for card rows. No mapped behaviour changes: every
keyboard, inset, drag and momentum function is untouched, and the
`Ev.explicit` writes of `followsComposer` stay in `textViewDidChange` and
at the top of `sendMessage`, which still inserts the sent row with the pass
alone (one `applyChanges`, no inserted-block animation). The edits add lines,
so the rows above that cite `ListChatController.swift` at `c5743ae`,
`65db16e`, `c06d876` and `1fd22d3` (the file is the same at all four) move:
lines 1-31 stay, 32-54 are edited or move (no row cites them), 55-148 move by
20, 149-460 by 21 (the keyboard functions), 461-538 by 23 (`textViewDidChange`
at :485), and `sendMessage`'s `followsComposer` write is at :583.
`ListChatController.swift` at `32bf281` has SHA-256
`4e374d5116195a0ce7767fb0f508012f4834ec89f262818fcf7cb30fc9892998`.
`Proofs/UltraProofs` is unchanged.

## Premounted rows and deferred unmounts (the commit after `4a99653`)

The list now builds the next row before a scroll needs it and removes rows
that leave the window later. After a scroll turn, an idle turn (a `Timer` on
the main run loop in the common modes, `scheduleIdleTurn`, :1042-1049) runs
`premount(_:)` (:1066-1096). It builds the row just past the window in the
direction of the latest scroll, as a scroll would mount it. The row is
hidden, in the container and laid out. There is one at a time, built at most
one per idle turn. When a rebalance asks for that row (:926-933), it takes
the premounted view instead of making one, and placement unhides the view in
the transaction that places it (:971). A row view that leaves the window
(:948-949), or a premount that goes unused, is hidden at once (`retire`,
:1021-1028). A later idle turn takes it out of the hierarchy, one per turn,
with at most 16 waiting (past that, the oldest goes at once). SHA-256:
`UltraListView.swift`
`8cd579a7cba67fb1f6286afd92ae2123358990bc6486c0726aab8227313e1845`,
`PremountTests.swift`
`248f0ad998afc1d6209f46a9522b077698c240acb704abfc6b60dc98fd6bcb10`.

The rows above that cite `UltraListView.swift` at `1fd22d3` (the same file
at `32bf281` and `4a99653`, `cb717770…`) shift as follows:
- lines 1-158 stay;
- 159-346 move by 21;
- 347-902 move by 23 (the far-jump hold's guard, :519, is now :542);
- 903-916 move by 31;
- 917, where the unmount removes the view, becomes :948-949;
- 918-938 move by 32;
- 939-952 move by 33;
- 953-956 move by 38;
- 957 to the end move by 141.

- `ListWindow.rebalance_keeps`, `rebalance_screen`: the rebalance's measure
  function returns the same height for every row. A premount is used only
  under the same measurement key (identity, revision, width, environment)
  and the same `appliedPassCount` (`takePremounted`, :1014-1019), so the
  items are those it was built for. A content change before placement drops
  it (:1090-1093), and asynchronous rows still read the measurement store.
  Only the source of the view changes, not the window's rows or frames.
- `Deferred.lean`, `Ev.finish` and `S.batch`: the idle turn is a timer turn,
  not the deferred block. It never calls `applyChanges` or
  `performAfterCurrentPass` and never touches `deferred`. During a pass it
  reschedules itself instead of running (:1054).
- `Hosts.lean`:
  - A premount's `applyPreparation` is `S.start`: the checkout takes the
    live host, else the staged one, else makes one. The view is in the
    container, so it has a window and `NodeRowLiveness` counts it.
  - A retired view keeps its host until it is released, which is `S.free`.
  - A row that comes back while its old view waits releases that view first
    (`releaseRetired`, :1031-1034, called at :927 and :1070). So the new
    view's checkout finds the staged host or makes one (`start_uses_staged`,
    `start_creates`), or takes the live host if the old view outlives the
    turn (`start_reuses`). `one_host` holds in every case.
  - A hidden view's host is live, so `sweepPreparations` keeps its
    preparation (`hasLiveHost` at :1282 and :1345, and
    `sweep_never_drops_hosted`).
- `Readiness.lean`:
  - `premountIndex` (:999-1012) returns nothing while a hold has staged
    views or a scroll is pending (`pendingDisplayViews`, `pendingScroll`,
    :1001-1002).
  - Every `applyChanges` pass releases the premount and the retired views
    before it builds its window (`releaseSpareRows`, :369, :1035-1039), so
    a hold's views and a pass's `oldViews` never include them.
  - A row that is mounted or carried is never premounted (:1008), so
    `promoteCarousel` and carried rows are untouched. `applies_latest`,
    `stale_noop` and `resume_applies` hold as they are.
- Premounted and retired views are hidden and are not in `views`. `views`
  is what accessibility, swipe reconciliation, attachments,
  `reportVisibility` and the chaos checks read. A premount is dropped:
  - when a scroll turns (:989);
  - when the window moves past its index (:1057-1059);
  - by every pass (:369);
  - by a content change (:1090-1093).

  The premount also skips a node row whose first-show appearance is still to
  play (:1011): the row itself or a `HorizontalRow`'s base, under the
  condition `showPreparedHost` consumes it on (NodeRow.swift:178-179). Rows
  of a list nested in the row are not checked. The premount's
  `layoutIfNeeded` (:1087) mounts them, so their appearances can play while
  hidden, one row before the preload margin would have mounted them (also
  off screen).
- A list that leaves its window with a premount and no idle turn pending
  keeps that one hidden view, with its host and preparation, until the next
  pass or scroll turn. Retired views always have a turn pending, and a turn
  without a window releases everything (:1053).

Not modeled: the premount, the idle turn's timing and the cap. No Lean
definition changes, and `Proofs/UltraProofs` is unchanged.
`PremountTests` checks the observable rules in every engine:
- a premount stays hidden and is the view shown;
- it is dropped by a pass, a content change, a reversal or a jump;
- nothing is premounted during a far-jump hold;
- a row that leaves is hidden at once and released later;
- a new revision still measuring never gets the old revision's view;
- a row whose first-show appearance is still to play isn't premounted, and
  the appearance plays once the row is shown.

## A swiped row's collapse edge (the commit after `f478507`)

`ListSwipeController.collapse` (SwipeActions.swift:457, called from
`reconcile` at :430) keeps the edge the deleted row's departing block is
welded by (:468), read through `UltraListView.departureEdge(forRowIdentity:)`
(UltraListView.swift:252-256), and falls back to its neighbours' motion only
while the block has no witness. Before, a delete that also resized the row
before it could weld the block by its bottom while the collapse kept the
top, so the shrinking row rode its block over the row above. `reconcile`
runs after `updateGhosts` in the same pass, so the edge is linked by then.
The lookup reads the ledger without changing it, and the collapse touches
neither the registry (`C`, `cstep`) nor the ledger (`Op`, `run`), so the
swipe and departure theorems hold as before; which edge a block is welded
by stays the list's unmodeled choice (see the departures section).

The new lines move SwipeActions.swift (the same file at `4a99653` and
`f478507`) from :454 on by 1 and from :467 on by 2, and UltraListView.swift
lines from :252 on at `f478507` by 5. Every UltraListView.swift line the
premount section above cites is past :252, so each is 5 lower (the far-jump
hold's guard is now :547), and for the rows that cite `1fd22d3`, lines from
231 on move by 5 more than that section lists. The rows that cite
SwipeActions.swift at `a489e36` and UltraListView.swift at older commits
stay as they are. SHA-256: `UltraListView.swift`
`8b5905c1b966d590135347ac4dd12b3dd297059fb773538d8fe18a195c7aeeb7`,
`SwipeActions.swift`
`97d76657f55d74af7530e66612316bb78aac14d28293be8bd2eca59eec7127ff`.
`Proofs/UltraProofs` is unchanged.

## Edge targets for a scroll to the top (the commit after `5b62b9b`)

`scrollToTop(animated:)` used to aim at the edge row's index as of the call:
0, or `count - 1` when the list is upside down. A scroll that waits for that
row's measurement keeps its target until a pass can apply it. If rows came
in at the edge meanwhile, the index then named another row:
- a newer message inserted at 0 in an upside-down chat moves the oldest
  row to `count`;
- older history appended at the end puts a new row past it.

In both cases the list landed a row short of the top, with the reserved
space of the row at the old index, and `didScrollToTop` never came,
because the list never rested on the edge.

The target now carries `edge` (`ListScrollTarget.edge`, ListRow.swift:122-125,
internal, set only by `scrollToTop`, :304). Each pass maps it to the edge
index of the items it shows, after it assigns them (`atEdge`, :841-847,
applied at :431-432). That includes a retry through `pendingScroll` or a
far-jump hold, which re-enters with the same target. The target's
`resolve` reads the reserved space of the edge row of the items it resolves
against (:299-303). Every other target, ordinary indices and the identity
remapping of `preparedTarget`, is unchanged. The pinned-row check (:431)
maps only an explicit `scrollTo`, as before, so a pending target never newly
holds the pinned row. `recordPendingTarget` (:850-855) copies the target
when it folds in an additional distance, so the edge survives it.

The same test found a second fault, which also affects ordinary targets.
New items whose target row isn't measured yet wait in `pendingItems`
while the list keeps showing the old items (:510-525). The measurement
for a row that only the waiting items have was dropped as it arrived:
`retainsPreparation` looked only at the shown items. The pass it marked
dirty then asked for the measurement again, so the target never applied
and the row was measured once a turn. `retainsPreparation` (:1365-1377)
now also keeps a measurement whose key matches a row of `pendingItems`.
When there is a pending target, that row must be within 80 rows of it,
the same band the shown items get. The pending target's index counts
among the waiting items, because the pass records it before it puts the
old items back (:510-525). `pendingItems` and `pendingIdentityIndices` are
written together, there and at :418, where the next pass takes them. While
they are set, the pending target was recorded by that branch: a pass that
records a target any other way takes the waiting items first. With no
pending target, every measured row of the waiting items is kept. Only rows
a failed build or a request ahead asked for are measured, and the next
pass that applies takes the waiting items, after which the usual band
applies. It is not a lasting cache. This adds a case to the retention policy noted under
"Node row hosts at `1dd0bb4`" and changes no sweep's decision for a
hosted root (`sweep_never_drops_hosted`).

SHA-256:
- `UltraListView.swift`
  `dd2b2128ffc438a9bb781c10f0a2f54c2e60491444dd5f678ae55d2ddb6524e2`
- `ListRow.swift`
  `82ca2a4bc8d0f88faf6bf8a023ea7e0719e23b6fa7d3e9e9cbb140249c3894cd`
- `ScrollToTopTests.swift`
  `63a61cd74ce95c5daf64c866f16c33f54cc30745799718c070e9031d4e91db61`

Lines of `UltraListView.swift` at `5b62b9b` (SHA-256 `8b5905c1…`) move
as follows:
- 1-294 stay;
- 295-304, `scrollToTop`'s target, are edited and keep their extent;
- 305-840 stay (:431-432 edited);
- `atEdge` is new at :841-847;
- `recordPendingTarget`'s body, :845, becomes :852-854;
- 846-1357 move by 9;
- `retainsPreparation`'s new lines are :1367-1371;
- 1358 to the end move by 14.

The premount section's citations, already 5 lower for those past :252
after the collapse commit, move by 9 more from :931 to :1350 (the
rebalance's take is at :940-947, `premountIndex` at :1013, `hasLiveHost` at
:1296 and :1359). Its :159-179 stay, and its :369 is :374.

| Model (`Proofs/UltraProofs/List/Readiness.lean`) | Swift after `5b62b9b` |
| --- | --- |
| `pick` | `(scrollTo ?? pendingTarget).map(atEdge)` (:432): the same choice, then an edge target's index read from the pass's items |

`Readiness` models targets as row indices chosen by `pick` and compares
calls by generation. An edge target is still one call with one generation;
only the index it names depends on the items of the pass that applies it.
`applies_latest`, `stale_noop`, `later_gen_lt` and `resume_applies` hold as
they are. No Lean definition changes.

`ScrollToTopTests.aScrollToTheTopGoesToTheRowAtTheEdgeWhenItApplies` runs
in every engine, with the edge row's measurement held:
- a new first row in an upright list;
- a newer row inserted at 0 in an upside-down list;
- an older row appended in an upside-down list;
- a new first row while an ordinary `scrollTo` row 0 waits, which reports
  no landing and must still apply.

The old edge row reserves 30 points and the arriving row 50. In each case
the test checks:
- that the list lands on the row at the edge when the pass applies, with
  that row's reserve;
- that `didScrollToTop` comes once and not again;
- that the arriving row is measured at most once.

Not covered: an edge target that applies against an empty list (it is
dropped, as every target is).

## Driven keyboard dismissal source review

The demo now uses the optional `KeyboardDismissalController` when a docked
phone keyboard host is available. The historical `Return` and `Momentum`
rows describe the system fallback's `KeyboardInsetGesture` route. They do
not prove the new controller's ownership protocol or UIKit host operations.
This review pins the new sources by SHA-256:

| Source | SHA-256 |
| --- | --- |
| `KeyboardDismissalGesture.swift` | `12be1df541aa8d78d7c882d71043df8e858633eb945fbc7721c42fc669ded5eb` |
| `KeyboardDismissalMotion.swift` | `32be8df047fa68c4608b987ddc2528085c53f09cd5aa7683c83b223f4c97187d` |
| `UIKit/KeyboardDismissalController.swift` | `34b30622ae9b09df411e8b393eba3a27910185463129c80a71d596a5523bedd7` |
| `UIKit/KeyboardDismissalAnimation.swift` | `a790414ac44028edd88335c0bebd6f7d8784c82a45cf8fb3e9b128faa8a16cb6` |
| `UIKit/KeyboardHostLookup.swift` | `b7d05de5c4fd9a1d03aa497ecf382b17bf1f0be22cf0879dd46b631feafc38a2` |
| `UIKit/KeyboardHostMotion.swift` | `3ea35b72d3d03adf395c6745f01af5b159d2aa52972c035f72ff0d27d1eb0768` |
| `UltraViewDemo/List/ListChatController.swift` | `5381dc8b29f886e1be05c709a0d5ae6149866571c93ec530af41ad5d11e0c73a` |

The pure gesture records a raw boundary separately from the committed boundary.
Tracking requires three points of absolute vertical travel until a layout commits
a boundary. Displacement is nonnegative with no upper clamp. The release uses
the last committed boundary, drops pending drag work, and requires the final
finger plus captured accessory height to cross the resting keyboard top. Its
velocity estimator retains six callback-time samples, includes whole pairs by
their second timestamp in the last 0.1 seconds, and averages slopes before
dividing by five. Cancellation uses committed position without adding an end
sample or velocity. `updateGeometry` refreshes the current window height and
resting keyboard top while preserving the captured accessory and committed
boundary. Linux regressions cover these exact boundaries, timing and
release endpoints. They are ordinary regressions, not a refinement theorem.

`stage` coalesces changes until `commitPendingLayout`. The synchronous callback
applies the list inset first and accessory frame second; `apply` then assigns
host bounds. Tracking and ordinary release introduce no enclosing driver
transaction. The callback receives signed overlap and an exact interactive flag.
`performUpdate` defers the whole operation past an active list pass and rejects
superseded requests. The demo disables inset compensation while its list tracks
or drags (`applyDrivenKeyboard`), and accepts subpixel inset changes.
Its owned `viewDidLayoutSubviews` restores the bottom constraint's exact position
after Auto Layout rounds the result, preserving its anchor when the composer
grows. The hosted subpixel regression keeps its exact-value comparison, and a
multiline-growth regression checks the anchor. The deferred-inset clock regressions now run
in `DeferredComposerInsetRuntimeTests` with a live window scene.

`KeyboardDismissalAnimation.make` creates a native additive spring on dismissal
and a cubic basic animation on return. `releaseTransition` supplies the same
curve to the app, which resolves its resting endpoint before interpolation.
These releases do not use the clipped viewport profile; `height` and `transition`
retain that profile for interrupted-hide recovery only. A shared clock therefore
does not imply a fixed keyboard-to-accessory gap during release. Completion or a
generation-checked deadline resolves ownership, including when an animation is
removed. A velocity-only end that interrupts a running return starts its new
host animation at the current presentation offset. An unmoved, nondismissing
touch leaves ordinary notification ownership intact. Completion delivery and
generation checks remain outside the models.

Owned frame notifications are consumed. `synchronizeGeometry` samples the
validated docked host's model before moves, release decisions and tracked layout
application. A tracking commit recalculates displacement from the boundary and
current top. Release application refreshes its displacement target without
changing the decision already made at end; dismissal completion refreshes it
again so a taller host ends fully below the window. `finishReturning` temporarily
resolves the current host, reconciles a changed top, then preserves the final apply,
idle and refresh order. A missing lookup therefore does not suppress the stored
host's final callback or animation cleanup.

This geometry path is not a model of native notification transition timing.
Without another finger sample a height change can leave an in-flight gap and
an immediate correction at completion. Four hosted height-change methods fail
on the staged baseline and pass with this geometry fix. They include six native
keyboard changes during tracking and return (335 to 399 points), with matching
notifications while owned, stable host identity and corrected final insets.
The dismissal growth check uses an injected host. Notification durations/curves,
changes between end and layout, native height changes during dismissal, host
replacement, hardware keyboard changes and rotation during a drag still lack
runtime parity evidence. The historical models establish none of these UIKit
behaviors. The final integrated 24-method hosted run passes, including the four
refocus and rotation methods, with no skips or Swift compiler warnings.

On a show that interrupts the driver's final system hide, a hold waits for
committed native position motion and the final shown model frame. The
controller reads fresh presentation geometry inside the applying closure,
removes validated native position animation keys, and starts its bounds
motion and the app on one new transaction clock (`handle` and `apply`). Native
animation cancellation delivers `finished == false`; notifications and
subsequent cycles need runtime evidence. Ancestor motion, host bounds or
transform motion, and a host that draws its own contents, background or
shadow reject takeover (`KeyboardHostMotion.positionKeys`). Invalid
configurations end owned recovery. A changed target during recovery
returns notification handling to the ordinary path. Animation
groups and transitions are not inspected by these property guards.

`Deferred.shared_inv` still supplies the relevant per-application clock
condition: an applied accessory update copies the viewport animation
produced by that update. Both the controller and the chat now drop
superseded requests (`applyComposerInset`),
so `once_inv` and `run_all`, which run every requested closure, are not
liveness results for this queue. The old `overtake_sample` regression is
checked by `DeferredComposerInsetTests` with a newer request made after
the pass ends and before its deferred closure runs. Private host lookup,
gesture delivery, native animation removal, cross-window coordinates and
rendered pixel continuity remain empirical obligations. No Lean model
changed in this source review.

Hosted simulator rotation checks report a stale layout-guide top after
refocus (minus 472 points against the host's physical 194 points). The same
failure occurs in all six system-path controls, with no driver instantiated.
Both paths keep the composer on the physical host and the next native cycle
repairs the guide. Rotation tests therefore compare the physical host and
bar immediately, and require the guide to match after the next native
cycle. The traces retain the stale guide frame. This is runtime evidence
for the tested simulator configuration, not a theorem about UIKit.

Validation for the revised gesture and release behavior: 322 Linux tests in 54
suites and all 390 Lean checks passed.
UIKit validation of these pinned sources is pending. The previous controller
checkpoint passed all 390 Lean theorems, and simulator validation passed 3 clock checks,
10 hosted runtime methods and 19 demo tests. Five interaction methods
passed 36 launches across all three engines and the system and driven
paths: 12 card-row momentum comparisons and 24 default-bubble gestures.
Recordings from that checkpoint average about 30 frames
per second, but their variable-rate timestamps also include short intermediate
composites. Detailed analysis of the pinned final build found keyboard-only
movement followed by composer and rows 3–7 milliseconds later during tracking;
observed gaps range from about 3 points at slow speeds to 46 points in a fast
fling. The fitted 60 Hz phase does not establish whether a physical display shows
those intermediate composites. These are known limits of the current runtime
evidence, and the shared release clock is not evidence of alignment at every
composite during finger tracking.
The final hosted target imports the app module and uses its bundle loader
without linking another library copy. Its build and all three unit-test
stage logs contain no project duplicate-class or static-library warnings.

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
- `ListHosts.one_host_always`, `checkout_never_trips`,
  `purge_never_frees_hosted`, `sweep_never_drops_hosted`,
  `staged_unkept_always`: a prepared root has at most one live host, staged
  or kept, at every step, a new host never meets an attached renderer, and
  neither cleanup touches a root a view keeps.
- `ListMomentum.run_keeps_velocity`, `follows_moves_by_inset`,
  `run_follows`, `dismissed_never_moved`: keyboard changes never alter a
  flight's velocity; programmatic inset changes move the content with the
  composer at any scroll position until an interactive dismissal, after
  which nothing snaps it.
- `ListReentry.guarded_pass_renders`: no engine callback renders a
  half-applied list, and a deferred render runs once the pass ends.
- `ListFlight.flight_in_band`, `flight_rows_kept`: the flight stays in its
  covered band until the horizon, so rows it will show stay loaded.
- `ListLayers.superpose`: motions on separate timings keep every linear
  relation when each is its own additive layer. `composed_seam`: rows the
  list composes from settled places, moves, height followers and a shared
  layout layer touch at every frame with any shared term. `kink_bound`: a pinned anchor's chord is off
  its boundary only across half the viewport, and by a stated bound.
- `ListReturn.resolution`, `at_most_once`: a cancelled keyboard dismissal
  returns the content exactly once, by the inset the finger took away, in
  every order of notifications, layouts and the release.
  `touch_loses`: a touch while the outcome is awaited loses it (gap at
  `f683c2f`). `resume_resolution`: a drag that resumes the waiting gesture
  returns against the first drag's start.
- `ListElastic.bounds_round`, `slice_bands`, `corners_fit`, `text_inset`,
  `ghost_shared`: a background resized by its bounds or nine-sliced keeps
  its corners, which always fit, under any width and height clocks; its
  text keeps its inset and size, and shared ink stays full through the
  crossfade.
- `ListDecel.engines_agree`, `springs_agree`: deceleration and bounce do not
  depend on the frame rate between edge crossings.
- `ListRubber.adapt_no_jump`, `begin_catches`, `reanchor_idle`: an edge
  change during a drag, or catching overscrolled content, moves nothing
  under the finger, and re-anchoring never drifts it.
- `ListDepartures.inv_run`, `no_cycle`, `weld_block`, `collect_empties`:
  departure blocks never ride in a cycle or ride a missing block, land on
  what they ride, and are all collected once their rows have faded.
- `ListContent.retimes_keep`, `retime_same`, `retime_unstarted`: inner
  content retimed with its row keeps a constant inset through any number of
  retimings, and the Swift's skipped and unstarted cases are that retiming.
- `ListPass.keep_moves_by_shift`, `keep_lands_settled`: an immediate inset
  change during a scroll to a target moves the content by its own shift and
  leaves the rest of the travel to end on its old deadline.
- `ListDeferred.shared_inv`, `once_inv`, `run_all`, `normalize_affine`: an
  accessory update requested during a list pass runs once after it, copies
  the viewport animation installed for that same update, and keeps the
  viewport's progress with its own displacement.
- `ListMount.delta_spec`, `mount_relative`, `mounted_as_moved`:
  `ContinuationField.delta` is the change in a row's offset from its
  witness, and a row mounted during a structural move with that change on
  the pass's clock is where the pass would have put it at every frame.

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
- **Keyboard guide delivery** (the chat's events, `Return.Ev`,
  `Momentum.Ev`): every move of the keyboard layout guide under the finger
  reaches the chat as a layout (`viewDidLayoutSubviews`), and the will-change
  notifications arrive. The first holds only if a view in the chat's
  hierarchy is constrained to the guide, which is wiring the proofs can't
  see: the dispatch theorems describe what happens to the events that come,
  not that they come. `Return.no_samples_no_return`: with no tracked sample
  the bar never follows the finger and no return is made. At `44e5d85` no
  production view depended on the guide (only the opt-in geometry probe's
  constraint did), so on device the bar didn't move during an interactive
  dismissal. Since `843e14a` the chat's `keyboardLayoutInput`
  (ListChatController.swift:11, constrained at :85-97), a transparent,
  non-interactive 1-point view whose top is pinned to the guide's top, is
  that dependent view: it makes UIKit lay the chat out as the guide moves.
  It positions nothing; the bar is still placed by the owned inset. The
  geometry probe observes it and adds no guide constraint of its own, so
  the instrumented and uninstrumented runs schedule the same layouts.
  `UninstrumentedKeyboardInteractionTests` drives the gesture with no probe
  or marker.

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
