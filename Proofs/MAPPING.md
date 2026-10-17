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
at `2b33902`" below maps the new writes (`retarget_exact`, `replans_follow`).

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

## Node row hosts at `0592bc8`

`Proofs/UltraProofs/List/Hosts.lean` models how node rows hand a prepared
root between row views (NodeRow.swift), and the two cleanups that must not
touch a hosted root: the renderer's queued purge and the list's preparation
sweep.

| Model (`Proofs/UltraProofs/List/Hosts.lean`) | Swift |
| --- | --- |
| `S.displayed`, `S.pending` | `NodeRowView.displayedHost`, `pendingHost` (NodeRow.swift:92-93) |
| `S.hostOf`, `S.weak` | `PreparedNodeContent.host` (weak) and `hasLiveHost` (NodeRow.swift:23-25) |
| `S.owner` | `PreparedNodeContent.owner` (weak, NodeRow.swift:24) |
| `S.renderer` | the root's `state.renderer` (Renderer.swift:92-96) |
| `S.start` | `NodeRowView.start` with `checkout(owner:)` (NodeRow.swift:143, :27), under `accept`'s and the queued candidate's guard: nothing pending, a different root shown (:140, :183-188) |
| `S.release` | `NodeRowView.release(_:)` (NodeRow.swift:105): the old owner lets the host go and keeps a snapshot |
| `S.reveal` | `showPreparedHost(_:)` (NodeRow.swift:114): the pending host replaces the shown one |
| `S.free` | a row view deallocated: its hosts go, weak `owner`s read `nil` |
| `S.collect` | `NodeHostView.deinit` (NodeHostView.swift:103) calling `Renderer.detach()` (Renderer.swift:101), which clears the renderer if it is still this host's |
| `purge_unhosted`'s hypothesis | the purge's check on the layout queue, `renderer == nil` (Renderer.swift:108) |
| `sweep_never_drops_hosted`'s hypothesis | `hasLiveHost` false in `sweepPreparations` and after a measurement (UltraListView.swift:723, :786) |

- `inv_run`, `one_host_always`: after every sequence of checkouts, reveals
  and view deallocations, a root has at most one live host (`one_host`), kept
  by one view (`one_slot`).
- `start_reuses`, `start_creates`: a checkout takes the live host from the
  view that had it and makes a host only when none is alive.
  `checkout_never_trips`: a host is made only for a root with no renderer, so
  the precondition at Renderer.swift:94 holds. `hosted_has_renderer`: a
  checkout that ignored the live host would trip it.
- `purge_never_frees_hosted`, `sweep_never_drops_hosted`: a purge whose check
  finds no renderer, and a sweep that finds `hasLiveHost` false, act on a
  root no live host renders.

The model reads a host as alive exactly while a row view's `displayedHost` or
`pendingHost` keeps it (the superview goes with the slot, and the commit and
reveal closures capture it weakly), and deallocation as happening in the
turn that lets it go. Not covered: the snapshot's content, the reveal's
deadline and `hasContent` wait (any order of reveals is allowed), the legacy
`NodeRow.prepared` cache's eviction, the window of the purge between its
check and its last write (a host attaching then runs its first pass after the
purge on the same serial queue), and the retention policy
(`retainsPreparation`: ±80 rows, the pinned row, the pending target), which
decides only when a sweep runs.

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

## Pending scroll targets and readiness holds

`Proofs/UltraProofs/List/Readiness.lean` models how `applyChanges` keeps a
scroll target it cannot apply yet, including the readiness hold `75fe3c8`
added for immediate distant jumps. The rows pin `6d94fd0` plus the commit
that adds the zero-viewport fix below.

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

## Placing transformed row views at `2b33902`

`Proofs/UltraProofs/List/Placement.lean` relates the list's content
coordinates (a row's frame top, which the `Pass`, `Window` and `Insets`
models compute) to the layer position UIKit draws from, for row views whose
layer anchor point is the top-left corner and whose transform may flip them
(an inverted list's rows, `scale(1, -1)`). At `746e713` carries and detached
views were moved through the frame setter; `2b33902` moves them through the
layer position. UltraListView.swift lines are at `2b33902`.

| Model (`Proofs/UltraProofs/List/Placement.lean`) | Swift |
| --- | --- |
| `offsetY`, `frameTop` | `ListRowView.placementOffset(size:)` (ListRow.swift:81-84); the frame getter, the transformed bounds' box |
| `place` | `ListRowView.place(in:)` (ListRow.swift:76-80), also for attachment views (UltraListView.swift:1245) |
| `retarget` | `carry.view.layer.position.y += next - oldY` after reading `frame.minY` (UltraListView.swift:524-526) |
| `moves` | `child.layer.position.y += delta` in `shiftDetached` (:919); carousel strips (:1061) |
| `replans` | the carried rows across passes: each pass's endpoint is the view's `frame.minY` (:512), `CrossingPlanner.infer` plans its next top (:515), and `retarget` writes it |
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
transform; their bounds and position are now set separately (:963-964,
:1041, :1066, :1074-1075), and `place false` is the identity on their top.
The `Pass` theorems about carries and departures (`detached_fixed`,
`scroll_carry_fixed`, `inserted_once`) are about frame tops and hold for the
Swift through `retarget_exact` and `moves_exact`.
`Tests/UltraViewUIKitTests/CarryContinuityTests.swift` checks an outgoing
row stays beyond its loaded neighbour through stream revisions during a
Send, for every engine, normal and inverted rows. The setter hypothesis is
the observed behavior, not documented API.

## Swipe actions at `76eab99`

`Proofs/UltraProofs/List/Swipe.lean` models the pure decisions in
SwipeReveal.swift, which last changed at `76eab99`, and how the controller
(UIKit/SwipeActions.swift at `0e5c7b6`) drives the registry. Distances are
rationals.

| Model (`Proofs/UltraProofs/List/Swipe.lean`) | Swift |
| --- | --- |
| `Axis`, `dominant`, `decide` | `GestureAxis`, `AxisLock.decide(dx:dy:slop:)` (SwipeReveal.swift:15-18) |
| `step` with `Op.update`, `Op.force` | `AxisLock.update` (:20-23), `force` (:25-30) |
| `release`, `projection` | `SwipeRelease.decide` (:104-108), `projection` (:101) |
| `threshold_above_half` | `SwipeRevealLayout.fullSwipeThreshold` (:54-58) |
| `begin`, `settle`, `remove` | `SwipeRegistry` (:196-209) |
| `C`, `cstep` | the controller's `registry`, the rows with a reveal, and the rows animating closed: `begin` settles the returned row closed (SwipeActions.swift:104, :483); `settle` (:208-228); a closing animation's `finish`; `remove` in `release`, `settle` and `reconcile` (:193, :209, :387-403) |

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
  and not closing.

`RunOk` is the controller's: `release` settles the pan's candidate, which
its `.began` made active, and a removal in between makes `release` return
early. Gesture delivery, the reveal's rubber band and spring
(`displayed`, `SwipeMotion`) and the buttons' spans are outside the model.

## Content inside an animating row (for the node-row transitions change)

`Proofs/UltraProofs/List/Content.lean` states what the coming node-row
content transitions rely on: inner node frames on the row's own height
timing, with running inner animations moved onto each new row timing from
their presented values. It is not yet mapped to Swift.

- `edge_lerp`, `edge_constant`: on one timing, a child edge minus the row
  edge is `(1 - p) * d0 + p * d1`; equal end differences make it constant.
- `retime_keeps`, `retimes_keep`: restarting both from their presented
  values toward their targets on a new timing, any number of times, keeps a
  constant inset at every frame.
- `alone_drifts`: retiming the row alone, with a 10-point inset bubble left
  on its timing, overlaps the row's edge by 2.5 points at 1 s.

## Departure blocks at `2b33902`

`Proofs/UltraProofs/List/Departures.lean` models `DepartureLedger`
(DepartureGeometry.swift, unchanged since `e0a2c2c`). The list's calls pin
UltraListView.swift at `2b33902`. Block ids and row identities are numbers,
coordinates rationals.

| Model (`Proofs/UltraProofs/List/Departures.lean`) | Swift |
| --- | --- |
| `Edge`, `Witness`, `Block` | `BoundaryEdge`, `DepartureLedger.Witness`, `.Block` (DepartureGeometry.swift:3-25) |
| `insert` | `insert(_:)` (:28); its precondition is the model's guard, and the list's ids come from `serial` (UltraListView.swift:954, 966) |
| `walk`, `link` | `link(_:to:edge:)` and its loop over `seen` (:29-42), with the loop bounded by `fuel` |
| `bound`, `solve` | `targets(rows:)`'s `solve` (:43-60); `solve 0` is the `visiting` guard's value |
| `promote` | `promoteToViewport(_:offset:)` (:63-66) |
| `modify` with `setRoot`, `close`, `shift`, `finish`, `addMember` | `setRoot`, `seal`, `shift(by:)`, `finishMember`, `addMember` (:61-75) |
| `drop` | one removal of `collect()`'s loop (:76-83) |
| `Op`, `run` | the calls in UltraListView.swift: `makeDepartures` (:966, :986-987), `updateGhosts` (:1009-1043), `shiftDetached` (:920), `promoteCarousel` (:1064-1066) and `departAttachment` (:1215, :1224-1225) |

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
  (UltraListView.swift:1039-1043), and
  `ListPass.ghost_follows_witness` gives that the block moves with what it
  rides at every frame when the witness's track shares the timing.
- `collect_empties`: once every member has finished, a stopped `collect()`
  leaves no block, so no wrapper outlives its rows.

Which witness `updateGhosts` picks (the predecessor survivor, a matching
inserted row, the nearest row on the anchor's side) is the list's choice and
not modeled; the theorems hold for every choice. Member fades finishing is a
hypothesis (`finished`).

## Rubber banding and re-anchored drags at `2b33902`

`Proofs/UltraProofs/List/Rubber.lean` models the rubber band and its
inverse (ScrollMath.swift, unchanged since `b82d7b9`), the drag that uses
them, and the re-anchor the list runs when a pass changes the edges during a
drag. Swipe reveals use the same pair (SwipeReveal.swift at `76eab99`).

| Model (`Proofs/UltraProofs/List/Rubber.lean`) | Swift |
| --- | --- |
| `band`, `rubber` | `ScrollMath.rubberBand` (ScrollMath.swift:25-31); `0 < r` stands for `range > ulpOfOne` |
| `unband`, `unrubber` (`cap` is `1 - 1e-6`) | `ScrollMath.inverseRubberBand` (:32-38) |
| `Drag`, `drag` | `ScrollAxis`'s `anchor`, `proposed`, `offset` and `drag(translation:)` (:58-70) |
| `reanchor` | `ScrollAxis.reanchorDrag()` (:79-83), called by `UltraListView.applyChanges` after `setEdges` and `shift(by:)` when `absorbsEdgeChangeIntoOverscroll` (UltraListView.swift:495-497) |
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
- `reanchor_capped`, `capped_jump`: when the shifted offset is farther than
  `range * cap` past the new edge (an edge change larger than the viewport
  under the finger), the next drag sample jumps to `range * cap` past it:
  with a 400-point viewport and an offset 500 past the edge, by just over
  100 points.

The shift before the re-anchor (`ScrollAxis.shift(by:)`, :78) moves offset,
anchor and proposed together, so the model's `Drag` is the state after it.
Gesture delivery (that the next sample repeats the current translation when
the finger has not moved) is outside the model.

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
  `purge_never_frees_hosted`, `sweep_never_drops_hosted`: a prepared root has
  at most one live host at every step, a new host never meets an attached
  renderer, and neither cleanup touches a hosted root.
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
- `ListRubber.reanchor_no_jump`, `reanchor_idle`: an edge change during a
  drag moves nothing under the finger, and re-anchoring never drifts it.
- `ListDepartures.inv_run`, `no_cycle`, `weld_block`, `collect_empties`:
  departure blocks never ride in a cycle or ride a missing block, land on
  what they ride, and are all collected once their rows have faded.
- `ListContent.retimes_keep`: inner content retimed with its row keeps a
  constant inset through any number of retimings.

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
