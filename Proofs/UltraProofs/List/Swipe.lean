/-!
# Swipe actions

Models the three decisions behind row swipe actions (SwipeReveal.swift) and
how the swipe controller uses the registry (UIKit/SwipeActions.swift).
Distances and velocities are rationals; the Swift's `Double` arithmetic and
the gesture recognizers' delivery of samples are outside the model.

* `lock_keeps`, `lock_run_keeps`: once a lock has an axis, every later
  `update` and `force` returns it, for any translation.
* `run_none_iff`: from no axis, `update`s return nil exactly while every
  sample so far stayed within the slop disc.
* `run_first`: the decision is the dominant axis of the first sample past
  the slop; `dominant_tie`: a tie goes vertical. `decide_symm_x`,
  `decide_symm_y`: mirroring a translation does not change the decision.
* `release_monotone`: more reveal and more opening velocity never give a
  lower outcome. `release_full_iff`: a full swipe exactly when a threshold is
  present and the reveal reaches it. `release_open_at_rest`: at zero
  velocity a row opens exactly when the reveal is at least half the open
  width and short of the threshold. `threshold_above_half`: the layout's
  threshold is always past half the open width.
* `begin_active`, `begin_closes`, `settle_keeps_open`, `settle_keeps_other`,
  `remove_keeps_other`: the registry's contract.
* `inv_run`, `one_open`: when the caller closes the row `begin` returns (as
  the controller does) and settles open only the active row, every row with
  a nonzero reveal is the active row or one animating closed, after any
  sequence of begins, settles, finished closings and removals; so at most
  one row is revealed and not closing.
-/

namespace UltraProofs.ListSwipe

/-! ## The axis lock -/

inductive Axis
  | horizontal
  | vertical
deriving DecidableEq

def absR (x : Rat) : Rat := max x (-x)

/-- The dominant axis; a tie goes vertical. -/
def dominant (dx dy : Rat) : Axis := if absR dx > absR dy then .horizontal else .vertical

/-- Within the slop disc. -/
def Within (slop dx dy : Rat) : Prop := dx * dx + dy * dy ≤ slop * slop

instance (slop dx dy : Rat) : Decidable (Within slop dx dy) := by unfold Within; infer_instance

/-- `AxisLock.decide(dx:dy:slop:)`. -/
def decide (slop dx dy : Rat) : Option Axis :=
  if dx * dx + dy * dy > slop * slop then some (dominant dx dy) else none

/-- `update` and `force`. -/
inductive Op
  | update (dx dy : Rat)
  | force (dx dy : Rat)

/-- The lock's axis after an operation, which is also what it returns. -/
def step (slop : Rat) (a : Option Axis) : Op → Option Axis
  | .update dx dy => match a with
    | some x => some x
    | none => decide slop dx dy
  | .force dx dy => match a with
    | some x => some x
    | none => some (dominant dx dy)

def run (slop : Rat) (a : Option Axis) (ops : List Op) : Option Axis := ops.foldl (step slop) a

/-- **Decided once**: a decided lock returns its axis for every later
operation. -/
theorem lock_keeps (slop : Rat) (x : Axis) (op : Op) : step slop (some x) op = some x := by
  cases op <;> rfl

theorem lock_run_keeps (slop : Rat) (x : Axis) : ∀ ops : List Op, run slop (some x) ops = some x
  | [] => rfl
  | op :: ops => by simp only [run, List.foldl_cons, lock_keeps]; exact lock_run_keeps slop x ops

theorem decide_none_iff (slop dx dy : Rat) : decide slop dx dy = none ↔ Within slop dx dy := by
  unfold decide Within
  by_cases h : dx * dx + dy * dy > slop * slop
  · simp only [h, ite_true, reduceCtorEq, false_iff]; exact Rat.not_le.mpr h
  · simp only [h, ite_false, true_iff]; exact Rat.not_lt.mp h

def updates (samples : List (Rat × Rat)) : List Op := samples.map fun p => .update p.1 p.2

/-- **Undecided exactly while every sample stays within the slop.** -/
theorem run_none_iff (slop : Rat) : ∀ samples : List (Rat × Rat),
    run slop none (updates samples) = none ↔ ∀ p ∈ samples, Within slop p.1 p.2
  | [] => by simp [run, updates]
  | p :: ps => by
    simp only [updates, List.map_cons, run, List.foldl_cons, step, List.mem_cons, forall_eq_or_imp]
    cases hd : decide slop p.1 p.2 with
    | none =>
      have := (decide_none_iff slop p.1 p.2).mp hd
      simp only [this, true_and]; exact run_none_iff slop ps
    | some x =>
      have hn : ¬Within slop p.1 p.2 := fun h => by rw [(decide_none_iff slop p.1 p.2).mpr h] at hd; cases hd
      simp only [hn, false_and, iff_false]
      have := lock_run_keeps slop x (ps.map fun p => .update p.1 p.2)
      simp only [run] at this; rw [this]; simp

/-- **The first sample past the slop decides**, by its dominant axis. -/
theorem run_first (slop : Rat) (pre post : List (Rat × Rat)) (q : Rat × Rat)
    (hpre : ∀ p ∈ pre, Within slop p.1 p.2) (hq : ¬Within slop q.1 q.2) :
    run slop none (updates (pre ++ q :: post)) = some (dominant q.1 q.2) := by
  have h1 : run slop none (updates pre) = none := (run_none_iff slop pre).mpr hpre
  have hd : decide slop q.1 q.2 = some (dominant q.1 q.2) := by
    unfold decide; simp only [Within] at hq
    simp [Rat.not_le.mp hq]
  simp only [updates, List.map_append, List.map_cons, run, List.foldl_append, List.foldl_cons] at h1 ⊢
  rw [h1]; simp only [step, hd]
  exact lock_run_keeps slop _ _

theorem dominant_tie (dx dy : Rat) (h : absR dx = absR dy) : dominant dx dy = .vertical := by
  simp [dominant, h]

theorem absR_neg (x : Rat) : absR (-x) = absR x := by
  simp only [absR]; grind

theorem decide_symm_x (slop dx dy : Rat) : decide slop (-dx) dy = decide slop dx dy := by
  simp only [decide, dominant, absR_neg, show -dx * -dx = dx * dx by grind]

theorem decide_symm_y (slop dx dy : Rat) : decide slop dx (-dy) = decide slop dx dy := by
  simp only [decide, dominant, absR_neg, show -dy * -dy = dy * dy by grind]

/-! ## The release -/

inductive Outcome
  | closed
  | opened
  | full
deriving DecidableEq

/-- `SwipeOutcome.rawValue`. -/
def Outcome.rank : Outcome → Nat
  | .closed => 0
  | .opened => 1
  | .full => 2

/-- `SwipeRelease.projection`, 0.12 s. -/
def projection : Rat := 3 / 25

/-- `SwipeRelease.decide(reveal:velocity:openWidth:fullSwipeThreshold:)`. -/
def release (r v w : Rat) (t : Option Rat) : Outcome :=
  if 0 < w then
    match t with
    | some t => if t ≤ r then .full else if w / 2 ≤ r + v * projection then .opened else .closed
    | none => if w / 2 ≤ r + v * projection then .opened else .closed
  else .closed

/-- **The release is monotone** in the reveal and the velocity. -/
theorem release_monotone (w : Rat) (t : Option Rat) {r₁ r₂ v₁ v₂ : Rat} (hr : r₁ ≤ r₂) (hv : v₁ ≤ v₂) :
    (release r₁ v₁ w t).rank ≤ (release r₂ v₂ w t).rank := by
  have hp : v₁ * projection ≤ v₂ * projection := by
    rw [Rat.mul_comm v₁, Rat.mul_comm v₂]
    exact Rat.mul_le_mul_of_nonneg_left hv (by unfold projection; decide +kernel)
  unfold release
  split
  · cases t with
    | some t =>
      simp only
      by_cases h1 : t ≤ r₁
      · simp [h1, show t ≤ r₂ by grind, Outcome.rank]
      · simp only [h1, ite_false]
        by_cases h2 : t ≤ r₂
        · simp only [h2, ite_true]; split <;> simp [Outcome.rank]
        · simp only [h2, ite_false]
          by_cases h3 : w / 2 ≤ r₁ + v₁ * projection
          · simp [h3, show w / 2 ≤ r₂ + v₂ * projection by grind, Outcome.rank]
          · simp only [h3, ite_false]; split <;> simp [Outcome.rank]
    | none =>
      simp only
      by_cases h3 : w / 2 ≤ r₁ + v₁ * projection
      · simp [h3, show w / 2 ≤ r₂ + v₂ * projection by grind, Outcome.rank]
      · simp only [h3, ite_false]; split <;> simp [Outcome.rank]
  · simp [Outcome.rank]

/-- **A full swipe exactly when the reveal reaches a present threshold.** -/
theorem release_full_iff (r v w : Rat) (t : Option Rat) (hw : 0 < w) :
    release r v w t = .full ↔ ∃ t', t = some t' ∧ t' ≤ r := by
  unfold release
  simp only [hw, ite_true]
  cases t with
  | some t =>
    simp only [Option.some.injEq, exists_eq_left']
    by_cases h : t ≤ r
    · simp [h]
    · simp only [h, ite_false, iff_false]; split <;> simp
  | none => simp only [reduceCtorEq, false_and, exists_false, iff_false]; split <;> simp

/-- **At rest, a row opens exactly from half the open width to the
threshold.** -/
theorem release_open_at_rest (r w : Rat) (t : Option Rat) (hw : 0 < w) :
    release r 0 w t = .opened ↔ w / 2 ≤ r ∧ ∀ t', t = some t' → r < t' := by
  unfold release
  simp only [hw, ite_true, Rat.zero_mul, Rat.add_zero]
  cases t with
  | some t =>
    simp only [Option.some.injEq, forall_eq']
    by_cases h : t ≤ r
    · simp only [h, ite_true, reduceCtorEq, false_iff, not_and]
      intro _ h'; exact absurd h (Rat.not_le.mpr h')
    · have h' : r < t := Rat.not_le.mp h
      simp only [h, ite_false, h', and_true]
      split <;> simp_all
  | none =>
    simp only [reduceCtorEq, false_implies, implies_true, and_true]
    split <;> simp_all

/-- `SwipeRevealLayout.fullSwipeThreshold`, when present: past half the
open width whenever the widths are non-negative. -/
theorem threshold_above_half (w rowWidth : Rat) (hw : 0 ≤ w) :
    w / 2 < max (w + 48) (rowWidth * (55 / 100)) := by
  grind

/-! ## One revealed row -/

variable {I : Type} [DecidableEq I]

/-- `SwipeRegistry.begin`: the row to close, and the new active row. -/
def begin (a : Option I) (x : I) : Option I × Option I :=
  (if a = some x then none else a, some x)

/-- `SwipeRegistry.settle`. -/
def settle (a : Option I) (x : I) (o : Outcome) : Option I :=
  if a = some x ∧ o = .closed then none else a

/-- `SwipeRegistry.remove`. -/
def remove (a : Option I) (x : I) : Option I := if a = some x then none else a

theorem begin_active (a : Option I) (x : I) : (begin a x).2 = some x := rfl

/-- **`begin` returns the previous row** when there is one and it is another. -/
theorem begin_closes (a : Option I) (x : I) :
    (begin a x).1 = (match a with | some y => if y = x then none else some y | none => none) := by
  cases a with
  | none => simp [begin]
  | some y => by_cases h : y = x <;> simp [begin, h]

theorem settle_keeps_open (a : Option I) (x : I) (o : Outcome) (ho : o ≠ .closed) : settle a x o = a := by
  simp [settle, ho]

theorem settle_keeps_other (a : Option I) (y : I) (o : Outcome) (h : a ≠ some y) : settle a y o = a := by
  simp [settle, h]

theorem remove_keeps_other (a : Option I) (y : I) (h : a ≠ some y) : remove a y = a := by
  simp [remove, h]

/-- The controller: the registry, the rows with a nonzero reveal, and the
rows animating closed. -/
structure C (I : Type) where
  active : Option I
  revealed : I → Bool
  closing : I → Bool

def updF {α : Type} (f : I → α) (x : I) (v : α) : I → α := fun y => if y = x then v else f y

inductive Ev (I : Type)
  /-- A drag on `x` starts revealing it: `registry.begin`, and the returned
  row is settled closed (SwipeActions.swift `begin`). -/
  | begin (x : I)
  /-- A release or a tap settles `x` with an outcome: closed animates it
  shut, open or full animates it open. -/
  | settle (x : I) (o : Outcome)
  /-- A closing animation finished: the reveal is zero. -/
  | finish (x : I)
  /-- The row left the list or its view went away. -/
  | remove (x : I)

def cstep (c : C I) : Ev I → C I
  | .begin x =>
    let closing' := match (begin c.active x).1 with
      | some y => updF c.closing y true
      | none => c.closing
    { active := (begin c.active x).2, revealed := updF c.revealed x true, closing := updF closing' x false }
  | .settle x o =>
    { c with active := settle c.active x o,
             closing := updF c.closing x (if o = .closed then true else false) }
  | .finish x => { c with revealed := updF c.revealed x false, closing := updF c.closing x false }
  | .remove x =>
    { active := remove c.active x, revealed := updF c.revealed x false, closing := updF c.closing x false }

def crun (c : C I) (evs : List (Ev I)) : C I := evs.foldl cstep c

/-- Every revealed row is the active one or animating closed. -/
def Inv (c : C I) : Prop := ∀ y, c.revealed y = true → c.active = some y ∨ c.closing y = true

/-- Opening settles go to the active row: the controller settles open only
from a release, of the row the pan's `begin` made active (a removal during
the pan makes the release return early). -/
def Ev.Ok (c : C I) : Ev I → Prop
  | .settle x o => o ≠ .closed → c.active = some x
  | _ => True

theorem cstep_inv {c : C I} (h : Inv c) (e : Ev I) (hok : e.Ok c) : Inv (cstep c e) := by
  intro y hy
  cases e with
  | begin x =>
    simp only [cstep, updF] at hy ⊢
    by_cases hyx : y = x
    · left; simp [begin, hyx]
    · simp only [hyx, ite_false] at hy ⊢
      right
      cases ha : c.active with
      | none =>
        rcases h y hy with ha' | hc
        · rw [ha] at ha'; cases ha'
        · simp [begin, hc]
      | some z =>
        by_cases hzx : z = x
        · rcases h y hy with ha' | hc
          · rw [ha] at ha'; exact absurd ((Option.some.inj ha').symm.trans hzx) hyx
          · simp [begin, hzx, hc]
        · simp only [begin, Option.some.injEq, hzx, ite_false, updF]
          by_cases hyz : y = z
          · simp [hyz]
          · rcases h y hy with ha' | hc
            · rw [ha] at ha'; exact absurd (Option.some.inj ha').symm hyz
            · simp [hyz, hc]
  | settle x o =>
    simp only [cstep, updF] at hy ⊢
    by_cases hyx : y = x
    · subst hyx
      by_cases ho : o = .closed
      · right; simp [ho]
      · left; rw [settle_keeps_open _ _ _ ho]; exact hok ho
    · simp only [hyx, ite_false]
      rcases h y hy with ha | hc
      · left; rw [settle_keeps_other _ _ _ (by rw [ha]; intro e; exact hyx (Option.some.inj e)), ha]
      · right; exact hc
  | finish x =>
    simp only [cstep, updF] at hy ⊢
    by_cases hyx : y = x
    · simp [hyx] at hy
    · simp only [hyx, ite_false] at hy ⊢; exact h y hy
  | remove x =>
    simp only [cstep, updF] at hy ⊢
    by_cases hyx : y = x
    · simp [hyx] at hy
    · simp only [hyx, ite_false] at hy ⊢
      rcases h y hy with ha | hc
      · left; rw [remove_keeps_other _ _ (by rw [ha]; intro e; exact hyx (Option.some.inj e)), ha]
      · right; exact hc

/-- Every opening settle in a run goes to the row active when it happens. -/
def RunOk : C I → List (Ev I) → Prop
  | _, [] => True
  | c, e :: evs => e.Ok c ∧ RunOk (cstep c e) evs

/-- **Over any sequence of swipe events** whose opening settles go to the
active row, every revealed row is the active one or animating closed. -/
theorem inv_run : ∀ (evs : List (Ev I)) {c : C I}, Inv c → RunOk c evs → Inv (crun c evs)
  | [], _, h, _ => h
  | e :: evs, _, h, ⟨hok, hr⟩ => inv_run evs (cstep_inv h e hok) hr

omit [DecidableEq I] in
/-- **At most one row is revealed and not closing.** -/
theorem one_open {c : C I} (h : Inv c) {x y : I} (hx : c.revealed x = true) (hcx : c.closing x = false)
    (hy : c.revealed y = true) (hcy : c.closing y = false) : x = y := by
  rcases h x hx with ax | cx
  · rcases h y hy with ay | cy
    · rw [ax] at ay; exact Option.some.inj ay
    · rw [hcy] at cy; cases cy
  · rw [hcx] at cx; cases cx

end UltraProofs.ListSwipe
