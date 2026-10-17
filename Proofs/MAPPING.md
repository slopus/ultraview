# Proofs: model to code

Machine-checked Lean 4 proofs that UltraView's pipeline is correct and does
no more work than it has to, plus the places where the Swift does more.
`scripts/proofs.sh` builds them and fails on any `sorry`, `admit`, new
`axiom`, or a theorem depending on an axiom other than Lean's `propext`,
`Classical.choice` and `Quot.sound`.

The model follows the **algorithms and invariants**, not the Swift line by
line: the same flags, caches, comparisons and keys, in the same order. The
table pins each model definition to the Swift **as of commit `22e6866`**.
When the Swift changes, re-check the rows whose files changed.

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
- `Optimality.must_read`, `must_send`: any correct algorithm must read every
  node whose change matters and send an entry for every changed view.
  `Optimality.entry_only_if_changed`: the pipeline sends no others.
- `Text.builds_le_distinct`: at most one text layout per distinct width.
- `Power.idle_only_client`, `idle_clean`: when idle only a client can cause
  a step, and nothing is owed. `Power.apply_local`: the main thread touches
  only nodes in the commit.

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
