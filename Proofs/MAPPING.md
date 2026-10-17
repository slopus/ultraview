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
