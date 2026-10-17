import UltraProofs.Pass
import UltraProofs.Walks

/-!
# A whole pass, and a run of passes

The commit of a pass is the per-node entries of `Pass.nodePass`. Applying it
to what the main thread shows gives what the new specs say, for every node
at once. Chaining passes through the mailbox, the main thread ends up showing
the last pass's specs: a fresh, full render of the tree that pass synced.
-/

namespace UltraProofs.Global

open UltraProofs UltraProofs.Commits UltraProofs.Pass

variable {F P K B : Type} [DecidableEq F] [DecidableEq P] [DecidableEq K]

/-- The commit a pass builds. -/
def passCommit (bmp : K → B) (ctx : Node → Ctx F P K) (gen req : Nat) : Commit F P B where
  generation := gen
  request := req
  entries n := (nodePass bmp (ctx n) (Sh.ofSpec bmp (ctx n).old)).entry

/-- What each node shows after the pass. -/
def shownAfter (bmp : K → B) (ctx : Node → Ctx F P K) (n : Node) : Spec F P K :=
  { (ctx n).new with key := drawnAfter (ctx n) (nodePass bmp (ctx n) (Sh.ofSpec bmp (ctx n).old)).job }

/-- Hypotheses a pass satisfies for each node (see `Pass.Deps`, `Pass.KidsOk`). -/
structure PassOk (ctx : Node → Ctx F P K) (kidsOld : Node → List Node) : Prop where
  old_valid : ∀ n, (ctx n).old.ist.Valid
  new_valid : ∀ n, (ctx n).new.ist.Valid
  deps : ∀ n, Deps (ctx n)
  kids : ∀ n, KidsOk (ctx n) (kidsOld n)

/-- **Pass soundness.** The commit turns the main thread's views, which match
the shadows the pass started from, into views matching what every node shows
after the pass; and its updates only target existing views, so it can be
merged in the mailbox. -/
theorem pass_sound [Inhabited F] [Inhabited P] (bmp : K → B) (ctx : Node → Ctx F P K)
    (kidsOld : Node → List Node) (gen req : Nat) (h : PassOk ctx kidsOld) :
    (passCommit bmp ctx gen req).apply (fun n => (ctx n).old.view bmp (kidsOld n)) =
      (fun n => (shownAfter bmp ctx n).view bmp (ctx n).kids) ∧
    (∀ n, (nodePass bmp (ctx n) (Sh.ofSpec bmp (ctx n).old)).sh =
      Sh.ofSpec bmp (shownAfter bmp ctx n)) ∧
    UpdatesTargetViews (passCommit bmp ctx gen req) (fun n => (ctx n).old.view bmp (kidsOld n)) := by
  refine ⟨?_, ?_, ?_⟩
  · funext n
    exact (nodePass_shown bmp (ctx n) (kidsOld n) (h.old_valid n) (h.new_valid n) (h.deps n)
      (h.kids n)).2
  · intro n
    exact (nodePass_shown bmp (ctx n) (kidsOld n) (h.old_valid n) (h.new_valid n) (h.deps n)
      (h.kids n)).1
  · intro n e he hk
    have := (nodePass_entries bmp (ctx n) (h.old_valid n) (h.new_valid n)).1 e he hk
    simp [Spec.view, this]

/-- Without cancelled drawings, every node shows its new spec. -/
theorem shownAfter_eq (bmp : K → B) (ctx : Node → Ctx F P K) (n : Node)
    (hc : (ctx n).cancelled = false) : shownAfter bmp ctx n = (ctx n).new := by
  simp [shownAfter, drawnAfter, hc]

/-! ## Child lists

`KidsOk` follows from how `childrenDidChange` is called: on every mount or
unmount of a child (`transition`) and whenever the child list itself
changes (`reconcileChildren`), given that a mounted node's parent is mounted
(`Walks.spec_le_parent`). -/

omit [DecidableEq F] [DecidableEq P] [DecidableEq K] in
theorem kidsOk_of (c : Ctx F P K) (kidsOldAll kidsNewAll : List Node)
    (mountedOld mountedNew : Node → Bool) (hkids : c.kids = kidsNewAll.filter mountedNew)
    (hold : ∀ x ∈ kidsOldAll, mountedOld x = true → c.old.ist.preload = true)
    (hcc : c.childrenChanged = false → kidsOldAll = kidsNewAll ∧
      ∀ x ∈ kidsNewAll, mountedOld x = mountedNew x) :
    KidsOk c (kidsOldAll.filter mountedOld) := by
  intro hc _
  obtain ⟨hl, hm⟩ := hcc hc
  subst hl
  have hf : kidsOldAll.filter mountedNew = kidsOldAll.filter mountedOld := by
    apply List.filter_congr
    intro x hx; rw [hm x hx]
  constructor
  · intro _; rw [hkids, hf]
  · intro hop
    rw [hkids, hf]
    apply List.filter_eq_nil_iff.2
    intro x hx hmx
    have := hold x hx hmx
    rw [hop] at this; cases this

/-! ## A run of passes -/

/-- Passes in sequence: each starts from what the previous one left shown. -/
inductive Run [Inhabited F] [Inhabited P] (bmp : K → B) :
    List (Commit F P B) → (Node → Spec F P K) → (Node → List Node) → Prop
  /-- Before the first pass nothing is mounted. -/
  | init (s₀ : Node → Spec F P K) (k₀ : Node → List Node)
      (h₀ : ∀ n, (s₀ n).ist.preload = false) : Run bmp [] s₀ k₀
  | pass {cs : List (Commit F P B)} {shown : Node → Spec F P K} {kids : Node → List Node}
      (ctx : Node → Ctx F P K) (gen req : Nat) :
      Run bmp cs shown kids → (∀ n, (ctx n).old = shown n) → PassOk ctx kids →
      Run bmp (cs ++ [passCommit bmp ctx gen req]) (shownAfter bmp ctx) (fun n => (ctx n).kids)

/-- **A run is sound**: applying the posted commits in order to an empty main
thread gives exactly the views of what the last pass left shown, and every
commit only updates views that exist when it is applied. -/
theorem run_sound [Inhabited F] [Inhabited P] (bmp : K → B) {cs : List (Commit F P B)}
    {shown : Node → Spec F P K} {kids : Node → List Node} (h : Run bmp cs shown kids) :
    fold cs (fun _ => none) = (fun n => (shown n).view bmp (kids n)) ∧
      ∀ pre c, pre ++ [c] <+: cs → UpdatesTargetViews c (fold pre (fun _ => none)) := by
  induction h with
  | init s₀ k₀ h₀ =>
    refine ⟨?_, fun pre c h => ?_⟩
    · funext n; simp [fold, Spec.view, h₀ n]
    · have := h.length_le; simp at this
  | @pass cs shown kids ctx gen req _ hold hok ih =>
    obtain ⟨hv, hwf⟩ := ih
    have hctx : (fun n => (ctx n).old.view bmp (kids n)) = fun n => (shown n).view bmp (kids n) := by
      funext n; rw [hold n]
    obtain ⟨happ, _, hupd⟩ := pass_sound bmp ctx kids gen req hok
    refine ⟨?_, ?_⟩
    · rw [fold_append, hv, ← hctx, happ]
    · intro pre c hpre
      rcases List.prefix_concat_iff.1 hpre with heq | hp
      · have : pre = cs ∧ c = passCommit bmp ctx gen req := by simpa using heq
        obtain ⟨rfl, rfl⟩ := this
        rw [hv, ← hctx]; exact hupd
      · exact hwf pre c hp

end UltraProofs.Global
