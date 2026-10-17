import UltraProofs.Basic

/-!
# The tree walks of a pass: frames and interface states

* `collectFrames` starts at the root and descends only through nodes Yoga
  flagged `hasNewLayout`. Under Yoga's caching contract (a frame changes
  only on a flagged node, and a node is flagged only if its parent is) it
  finds every changed frame, and it looks at exactly the root plus the
  children of flagged nodes.
* `assignState` / `assignInheritedState` / `updateRanges` recompute
  interface states. Whatever order they run in, each assignment computes a
  node's state from its parent's current state and, when the state changes,
  goes on to the node's children (`updateRanges` for a scroll content
  container). We prove that this worklist scheme ends at the top-down
  specification, from any starting point, as long as it starts from every
  node whose own inputs changed.
-/

namespace UltraProofs.Walks

open UltraProofs

/-! ## `collectFrames` -/

/-- The nodes a walk from the root reaches when it descends through the
nodes where `opn` holds. -/
inductive Reached (t : Tree) (opn : Node → Bool) : Node → Prop
  | root : Reached t opn t.root
  | child {c p : Node} : t.parent c = some p → opn p = true → Reached t opn p → Reached t opn c

/-- Yoga's caching contract, as UltraView relies on it: frames change only
on nodes flagged `hasNewLayout`, and Yoga reaches a node only through its
parent. Yoga itself is not verified; this is the hypothesis. -/
structure YogaContract {F : Type} (t : Tree) (frameOld frameNew : Node → F)
    (hasNew : Node → Bool) : Prop where
  changed : ∀ n, frameOld n ≠ frameNew n → hasNew n = true
  parent_closed : ∀ n p, hasNew n = true → t.parent n = some p → hasNew p = true

theorem reached_of_flagged {t : Tree} {hasNew : Node → Bool}
    (hc : ∀ n p, hasNew n = true → t.parent n = some p → hasNew p = true) :
    ∀ n, hasNew n = true → Reached t hasNew n := by
  intro n
  induction h : t.rank n using Nat.strongRecOn generalizing n with
  | _ r ih =>
    intro hn
    cases hp : t.parent n with
    | none => rw [t.parent_none hp]; exact .root
    | some p =>
      have := t.parent_rank hp
      exact .child hp (hc n p hn hp) (ih (t.rank p) (by omega) p rfl (hc n p hn hp))

/-- **`collectFrames` is complete**: every node whose frame changed is
reached and flagged, so its new frame is read and it is queued. -/
theorem collectFrames_complete {F : Type} {t : Tree} {fo fn : Node → F} {hasNew : Node → Bool}
    (hy : YogaContract t fo fn hasNew) {n : Node} (h : fo n ≠ fn n) :
    Reached t hasNew n ∧ hasNew n = true :=
  ⟨reached_of_flagged hy.parent_closed n (hy.changed n h), hy.changed n h⟩

/-- **What `collectFrames` looks at**: the root and the children of flagged
nodes, nothing else. -/
theorem collectFrames_visits {t : Tree} {hasNew : Node → Bool}
    (hc : ∀ n p, hasNew n = true → t.parent n = some p → hasNew p = true) (n : Node) :
    Reached t hasNew n ↔ n = t.root ∨ ∃ p, t.parent n = some p ∧ hasNew p = true := by
  constructor
  · intro h
    cases h with
    | root => exact .inl rfl
    | child hp ho _ => exact .inr ⟨_, hp, ho⟩
  · rintro (h | ⟨p, hp, ho⟩)
    · subst h; exact .root
    · exact .child hp ho (reached_of_flagged hc p ho)

/-! ## Interface states -/

/-- `InterfaceState` as three flags (`preload`, `display`, `visible`). -/
abbrev St := Bool × Bool × Bool

def inter (a b : St) : St := (a.1 && b.1, a.2.1 && b.2.1, a.2.2 && b.2.2)

/-- What decides interface states: the root's state (`.all` in a window,
`[]` out of one), which nodes are scroll content containers, and for each
child of a content container the state its range position gives
(`RangeTuning.state`). -/
structure IfaceInputs where
  rootState : St
  content : Node → Bool
  range : Node → St

/-- A node's state from its parent's: inherited, or for a child of a scroll
content container its range state intersected with the container's. -/
def localSt (t : Tree) (I : IfaceInputs) (cur : Node → St) (n : Node) : St :=
  match t.parent n with
  | none => I.rootState
  | some p => if I.content p then inter (I.range n) (cur p) else cur p

set_option linter.unusedVariables false in
/-- The specification: interface states computed top-down from scratch. -/
def spec (t : Tree) (I : IfaceInputs) (n : Node) : St :=
  match h : t.parent n with
  | none => I.rootState
  | some p => if I.content p then inter (I.range n) (spec t I p) else spec t I p
termination_by t.rank n
decreasing_by all_goals exact t.parent_rank h

theorem spec_local (t : Tree) (I : IfaceInputs) (n : Node) :
    spec t I n = localSt t I (spec t I) n := by
  rw [spec]
  unfold localSt
  split <;> simp_all

/-- Any assignment that satisfies the local rule everywhere is the spec. -/
theorem eq_spec_of_local {t : Tree} {I : IfaceInputs} {cur : Node → St}
    (h : ∀ n, cur n = localSt t I cur n) : ∀ n, cur n = spec t I n := by
  intro n
  induction hr : t.rank n using Nat.strongRecOn generalizing n with
  | _ r ih =>
    rw [h n, spec_local]
    unfold localSt
    cases hp : t.parent n with
    | none => rfl
    | some p =>
      have := t.parent_rank hp
      dsimp only
      rw [ih (t.rank p) (by omega) p rfl]

/-- The worklist form of `assignState`: `work` holds the nodes still to be
(re)assigned. -/
structure Iter where
  cur : Node → St
  work : List Node

/-- Assign `n` from its parent's current state; when its state changes, its
children are due (`assignState` recursing, or `updateRanges` for a content
container). -/
inductive IStep (t : Tree) (I : IfaceInputs) : Iter → Iter → Prop
  | assign (s : Iter) (n : Node) (hn : n ∈ s.work) :
      IStep t I s
        { cur := upd s.cur n (localSt t I s.cur n)
          work := s.work.erase n ++
            (if localSt t I s.cur n ≠ s.cur n then t.children n else []) }

/-- Every node either satisfies the local rule or is due. -/
def Fix (t : Tree) (I : IfaceInputs) (s : Iter) : Prop :=
  ∀ n, s.cur n = localSt t I s.cur n ∨ n ∈ s.work

theorem localSt_upd (t : Tree) (I : IfaceInputs) (cur : Node → St) (n m : Node) (v : St)
    (hm : t.parent m ≠ some n) : localSt t I (upd cur n v) m = localSt t I cur m := by
  unfold localSt
  cases hp : t.parent m with
  | none => rfl
  | some p =>
    have : p ≠ n := by intro e; subst e; exact hm hp
    simp [upd, this]

theorem Fix.step {t : Tree} {I : IfaceInputs} {s s' : Iter} (hf : Fix t I s) (h : IStep t I s s') :
    Fix t I s' := by
  cases h with
  | assign n hn =>
    intro m
    have hpn : t.parent n ≠ some n := by
      intro e; have := t.parent_rank e; omega
    by_cases hmn : m = n
    · subst hmn
      left
      simp only [upd_same]
      rw [localSt_upd t I _ _ _ _ hpn]
    · by_cases hpar : t.parent m = some n
      · by_cases hch : localSt t I s.cur n ≠ s.cur n
        · right
          simp only [List.mem_append]
          right
          simp [hch, t.mem_children.2 hpar]
        · have heq : localSt t I s.cur n = s.cur n := by
            by_cases e : localSt t I s.cur n = s.cur n
            · exact e
            · exact absurd e hch
          have hid : upd s.cur n (localSt t I s.cur n) = s.cur := by
            funext x; by_cases e : x = n <;> simp [upd, e, heq]
          rw [hid]
          rcases hf m with h1 | h1
          · exact .inl h1
          · right; simp only [List.mem_append]; left; exact (List.mem_erase_of_ne hmn).2 h1
      · rcases hf m with h1 | h1
        · left
          show upd s.cur n _ m = localSt t I (upd s.cur n _) m
          rw [localSt_upd t I _ _ _ _ hpar, upd_other _ _ hmn]
          exact h1
        · right; simp only [List.mem_append]; left; exact (List.mem_erase_of_ne hmn).2 h1

inductive ISteps (t : Tree) (I : IfaceInputs) : Iter → Iter → Prop
  | refl (s : Iter) : ISteps t I s s
  | step {s₁ s₂ s₃ : Iter} : ISteps t I s₁ s₂ → IStep t I s₂ s₃ → ISteps t I s₁ s₃

theorem ISteps.fix {t : Tree} {I : IfaceInputs} {s₁ s₂ : Iter} (h : ISteps t I s₁ s₂)
    (hf : Fix t I s₁) : Fix t I s₂ := by
  induction h with
  | refl => exact hf
  | step _ hs ih => exact ih.step hs

/-- **Interface states are right**: start from the previous states (the spec
for the previous inputs) with every node whose own inputs changed on the
worklist; run assignments in any order until nothing is due. The result is
the spec for the new inputs. -/
theorem assign_correct {t : Tree} {I₀ I : IfaceInputs} (roots : List Node)
    (hroots : ∀ n, localSt t I (spec t I₀) n ≠ localSt t I₀ (spec t I₀) n → n ∈ roots)
    {s : Iter} (hrun : ISteps t I ⟨spec t I₀, roots⟩ s) (hdone : s.work = []) :
    ∀ n, s.cur n = spec t I n := by
  have hinit : Fix t I ⟨spec t I₀, roots⟩ := by
    intro n
    by_cases h : localSt t I (spec t I₀) n = localSt t I₀ (spec t I₀) n
    · left; show spec t I₀ n = _; rw [h, ← spec_local]
    · right; exact hroots n h
  have hfix : Fix t I s := hrun.fix hinit
  apply eq_spec_of_local
  intro n
  rcases hfix n with h | h
  · exact h
  · rw [hdone] at h; cases h

/-- The nodes whose own inputs changed: the root, when the window state
changed; a child of a content container, when its range state or the
container status changed. (Swift's `updateRanges` starts from every child of
the container instead; see `Ranges.lean`.) -/
theorem roots_needed (t : Tree) (I₀ I : IfaceInputs) (cur : Node → St) (n : Node)
    (h : localSt t I cur n ≠ localSt t I₀ cur n) :
    (t.parent n = none ∧ I.rootState ≠ I₀.rootState) ∨
      ∃ p, t.parent n = some p ∧ (I.content p ≠ I₀.content p ∨ I.range n ≠ I₀.range n) := by
  unfold localSt at h
  cases hp : t.parent n with
  | none => left; simp [hp] at h; exact ⟨rfl, h⟩
  | some p =>
    right
    refine ⟨p, rfl, ?_⟩
    simp only [hp] at h
    by_cases hc : I.content p = I₀.content p
    · right; intro hr; rw [hc, hr] at h; exact h rfl
    · left; exact hc

/-- A state never exceeds its parent's, so a mounted node's parent is
mounted (`KidsOk` relies on it). -/
theorem spec_le_parent (t : Tree) (I : IfaceInputs) {c p : Node} (hp : t.parent c = some p)
    (h : (spec t I c).1 = true) : (spec t I p).1 = true := by
  rw [spec_local] at h
  unfold localSt at h
  simp only [hp] at h
  split at h
  · simp [inter] at h; exact h.2
  · exact h

end UltraProofs.Walks
