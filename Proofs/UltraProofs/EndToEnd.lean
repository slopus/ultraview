import UltraProofs.Global
import UltraProofs.Scheduling

/-!
# End to end: at quiescence the screen is a fresh render of the tree

Putting the pieces together:

* `Scheduling.quiescent_clean`: when no walk, pass or queued pass remains,
  no node has `needsSync` set.
* The setters' contract (`UltraNode.style`, `UltraTextNode.updateContent`,
  child edits, `reportContentOffset`): a node's live state differs from the
  snapshot the last pass took only while its `needsSync` is set, because
  every setter changes the state first and sets the flag after.
* `Global.run_sound`: applying the posted commits in order gives the views of
  what the last pass left shown, and `Commits.views_after_take` says the
  mailbox delivers exactly that.
* The last pass had no cancelled drawing: a cancellation comes from a
  mutation during the pass, which sets `needsSync` after the pass synced the
  node and so schedules another pass.

So the main thread shows exactly what a fresh full render of the current
tree would.
-/

namespace UltraProofs.EndToEnd

open UltraProofs UltraProofs.Commits UltraProofs.Pass UltraProofs.Global

variable {F P K B S : Type} [DecidableEq F] [DecidableEq P] [DecidableEq K]

/-- **Commit soundness, end to end.** `render` is the full, from-scratch
pipeline function: Yoga frames, interface states, props and keys of every
node, from all the nodes' states (pure, by Yoga's determinism). -/
theorem quiescent_shows_fresh_render [Inhabited F] [Inhabited P]
    (t : Tree) (bmp : K → B) (render : (Node → S) → Node → Spec F P K)
    (kidsOf : (Node → S) → Node → List Node)
    {sch : Scheduling.State} (hI : Scheduling.Inv t sch) (hw : sch.walkers = [])
    (hr : sch.running = false) (hs : sch.scheduled = false)
    (live snap : Node → S) (hfresh : ∀ n, sch.needs n = false → snap n = live n)
    {cs : List (Commit F P B)} {shown : Node → Spec F P K} {kids : Node → List Node}
    (hrun : Run bmp cs shown kids)
    (hlast : ∀ n, shown n = render snap n) (hkids : ∀ n, kids n = kidsOf snap n) :
    fold cs (fun _ => none) = fun n => (render live n).view bmp (kidsOf live n) := by
  have hclean := Scheduling.quiescent_clean hI hw hr hs
  have hsnap : snap = live := funext fun n => hfresh n (hclean n).1
  rw [(run_sound bmp hrun).1]
  funext n
  rw [hlast n, hkids n, hsnap]

/-- The last pass renders its snapshot when its contexts carry the spec of
that snapshot and no drawing was cancelled. -/
theorem last_pass_renders (bmp : K → B) (render : (Node → S) → Node → Spec F P K)
    (snap : Node → S) (ctx : Node → Ctx F P K) (hnew : ∀ n, (ctx n).new = render snap n)
    (hc : ∀ n, (ctx n).cancelled = false) : ∀ n, shownAfter bmp ctx n = render snap n := by
  intro n
  rw [shownAfter_eq bmp ctx n (hc n), hnew n]

end UltraProofs.EndToEnd
