/-!
# Distant jumps wait for ready content

Models how `UltraListView.applyChanges` keeps a requested scroll target until
it can apply (UltraListView.swift). A call's target is `scrollTo ??
pendingTarget`, and the call ends one of four ways:

* `apply`: the pass runs. It clears `pendingTarget` and `pendingScroll`, and
  `clearPendingDisplayViews` starts a new hold generation.
* `hold`: an immediate jump whose destination shares no row with the screen
  finds a visible row without a height or not display-ready. It keeps the
  old window, records the target in `pendingTarget` and in the
  `pendingScroll` closure, starts a new generation and installs readiness
  observers that capture it.
* `empty`: the anchor has no height yet. It records the target, and the
  closure when the call has its own `scrollTo`.
* `zero`: the items are there but the viewport has no width or height. It
  records the target in `pendingTarget` and starts a new generation.

`pendingScroll` runs from two places: a readiness observer whose generation
is current and whose check passes, and the dirty flush after a measurement
or a content change (`markDirty`). Which way a call ends is an input; so is
each observer's check.

* `applies_latest`, `run_applies_latest`: with the zero-viewport guard
  recording the closure as the other branches do (`fix`), every target that
  applies is the most recently requested one, after any sequence of calls,
  flushes and observers.
* `zero_reverts` (a gap in the Swift at `060cb79`): the zero-viewport guard
  updates `pendingTarget` but not `pendingScroll`. A jump to row 50 holds,
  the width goes to zero, row 80 is requested, and a dirty flush runs the
  old closure: row 50 becomes the pending target again and applies when the
  width returns. `zero_fixed`: with the fix, row 80 applies.
* `stale_noop`, `gen_le_run`, `later_gen_lt`: an observer from an earlier
  hold sees a newer generation after any later call that applies, holds or
  meets a zero viewport, and does nothing.
* `resume_applies`: an observer of the current hold whose check passes
  applies the pending target when the resumed call applies.

A hold changes nothing shown, so the old window stays until a later call
applies. Mutations with new items go through the preparation queue
(`ListPreparation`) and are outside this model.
-/

namespace UltraProofs.ListReadiness

/-- How a call ends. -/
inductive Out
  | apply
  | hold
  | empty
  | zero

/-- The targets applied, `pendingTarget`, the target `pendingScroll`
re-requests, the hold generation, and every target requested, newest last. -/
structure S where
  shown : List Nat
  pending : Option Nat
  retry : Option Nat
  gen : Nat
  requested : List Nat

def S.empty : S := ⟨[], none, none, 0, []⟩

/-- `a ?? b`. -/
def pick : Option Nat → Option Nat → Option Nat
  | some t, _ => some t
  | none, b => b

/-- `applyChanges(scrollTo: sc)` ending in `o`. With `fix`, the
zero-viewport guard records the closure for its own `scrollTo`, as the
empty-window guard does. -/
def call (fix : Bool) (s : S) (sc : Option Nat) : Out → S
  | .apply => match pick sc s.pending with
    | some t => { s with shown := s.shown ++ [t], pending := none, retry := none, gen := s.gen + 1 }
    | none => { s with pending := none, retry := none, gen := s.gen + 1 }
  | .hold => match pick sc s.pending with
    | some t => { s with pending := some t, retry := some t, gen := s.gen + 1 }
    | none => { s with gen := s.gen + 1 }
  | .empty => { s with pending := pick sc s.pending, retry := pick sc s.retry }
  | .zero => { s with pending := pick sc s.pending, retry := if fix then pick sc s.retry else s.retry,
                      gen := s.gen + 1 }

inductive Ev
  /-- A client call, `scrollTo: sc`. -/
  | call (sc : Option Nat) (o : Out)
  /-- The dirty flush: `pendingScroll` if set, else a pass without a target. -/
  | flush (o : Out)
  /-- A readiness observer from generation `g`, with its check. -/
  | observe (g : Nat) (ready : Bool) (o : Out)

def step (fix : Bool) (s : S) : Ev → S
  | .call sc o => call fix { s with requested := s.requested ++ sc.toList } sc o
  | .flush o => match s.retry with
    | some t => call fix { s with retry := none } (some t) o
    | none => call fix s none o
  | .observe g ready o =>
    if g = s.gen ∧ ready = true then
      match s.retry with
      | some t => call fix { s with retry := none } (some t) o
      | none => s
    else s

def run (fix : Bool) (s : S) (evs : List Ev) : S := evs.foldl (step fix) s

/-! ## Only the newest target applies -/

/-- The pending target and the closure's target are the newest request. -/
def Inv (s : S) : Prop :=
  (∀ t, s.pending = some t → s.requested.getLast? = some t) ∧
  (∀ t, s.retry = some t → s.requested.getLast? = some t)

/-- What a step does to `shown`: nothing, or it applies the newest request. -/
def Applies (s s' : S) : Prop :=
  s'.shown = s.shown ∨ ∃ t, s'.shown = s.shown ++ [t] ∧ s'.requested.getLast? = some t

theorem call_requested (fix : Bool) (s : S) (sc : Option Nat) (o : Out) :
    (call fix s sc o).requested = s.requested := by
  cases o <;> simp only [call] <;> (try split) <;> rfl

/-- A call with its own target leaves only that target pending, and applies
only that one. -/
theorem call_some (s : S) (u : Nat) (o : Out) :
    (∀ t, (call true s (some u) o).pending = some t → t = u) ∧
    (∀ t, (call true s (some u) o).retry = some t → t = u) ∧
    ((call true s (some u) o).shown = s.shown ∨ (call true s (some u) o).shown = s.shown ++ [u]) := by
  cases o <;> simp [call, pick]

/-- A call without a target keeps the invariant and applies only the pending
target. -/
theorem call_none {s : S} (h : Inv s) (o : Out) : Inv (call true s none o) ∧ Applies s (call true s none o) := by
  cases o with
  | apply =>
    simp only [call, pick]
    cases hp : s.pending with
    | some t => exact ⟨⟨by simp, by simp⟩, Or.inr ⟨t, rfl, h.1 t hp⟩⟩
    | none => exact ⟨⟨by simp, by simp⟩, Or.inl rfl⟩
  | hold =>
    simp only [call, pick]
    cases hp : s.pending with
    | some t =>
      exact ⟨⟨fun x hx => by simp at hx; subst hx; exact h.1 _ hp,
        fun x hx => by simp at hx; subst hx; exact h.1 _ hp⟩, Or.inl rfl⟩
    | none => exact ⟨⟨fun x hx => by simp at hx, h.2⟩, Or.inl rfl⟩
  | empty => exact ⟨h, Or.inl rfl⟩
  | zero => exact ⟨by simpa [call, pick, Inv] using h, Or.inl rfl⟩

/-- A call for `u` when `u` is the newest request. -/
theorem call_newest (s : S) (u : Nat) (hu : s.requested.getLast? = some u) (o : Out) :
    Inv (call true s (some u) o) ∧ Applies s (call true s (some u) o) := by
  obtain ⟨hp, hr, hs⟩ := call_some s u o
  rw [Inv, Applies, call_requested]
  refine ⟨⟨fun t ht => by rw [hp t ht]; exact hu, fun t ht => by rw [hr t ht]; exact hu⟩, ?_⟩
  rcases hs with hs | hs
  · exact Or.inl hs
  · exact Or.inr ⟨u, hs, hu⟩

/-- **Only the newest request applies** (with the fix), at every step. -/
theorem applies_latest {s : S} (h : Inv s) (e : Ev) : Inv (step true s e) ∧ Applies s (step true s e) := by
  cases e with
  | call sc o =>
    cases sc with
    | some u =>
      have := call_newest { s with requested := s.requested ++ [u] } u (by simp) o
      exact this
    | none =>
      have hs : { s with requested := s.requested ++ (none : Option Nat).toList } = s := by simp
      simp only [step, hs]
      exact call_none h o
  | flush o =>
    simp only [step]
    cases hr : s.retry with
    | some t => exact call_newest { s with retry := none } t (h.2 t hr) o
    | none => exact call_none h o
  | observe g ready o =>
    simp only [step]
    split
    · cases hr : s.retry with
      | some t => exact call_newest { s with retry := none } t (h.2 t hr) o
      | none => exact ⟨h, Or.inl rfl⟩
    · exact ⟨h, Or.inl rfl⟩

theorem inv_empty : Inv S.empty := ⟨by simp [S.empty], by simp [S.empty]⟩

theorem run_inv : ∀ (evs : List Ev) {s : S}, Inv s → Inv (run true s evs)
  | [], _, h => h
  | e :: evs, _, h => run_inv evs (applies_latest h e).1

/-- **After any sequence of calls, flushes and observers from no target**,
the next step applies nothing or the newest request. -/
theorem run_applies_latest (pre : List Ev) (e : Ev) :
    Applies (run true S.empty pre) (step true (run true S.empty pre) e) :=
  (applies_latest (run_inv pre inv_empty) e).2

/-! ## The Swift's zero-viewport guard -/

/-- Hold a jump to row 50; the width goes to zero (a layout pass with no
target); row 80 is requested; a dirty flush; the width returns. -/
def zeroScenario : List Ev :=
  [.call (some 50) .hold, .call none .zero, .call (some 80) .zero, .flush .zero, .call none .apply]

/-- **The zero-viewport guard brings back an older target (Swift at
`060cb79`).** Row 80 is the newest request, but row 50 applies. -/
theorem zero_reverts :
    (run false S.empty zeroScenario).shown = [50] ∧
    (run false S.empty zeroScenario).requested.getLast? = some 80 := by
  decide +kernel

/-- **With the fix, row 80 applies.** -/
theorem zero_fixed : (run true S.empty zeroScenario).shown = [80] := by decide +kernel

/-! ## Stale observers -/

/-- **An observer from another generation does nothing.** -/
theorem stale_noop (fix : Bool) (s : S) (g : Nat) (ready : Bool) (o : Out) (hg : g ≠ s.gen) :
    step fix s (.observe g ready o) = s := by
  simp [step, hg]

theorem call_gen (fix : Bool) (s : S) (sc : Option Nat) (o : Out) :
    s.gen ≤ (call fix s sc o).gen ∧ (o ≠ .empty → s.gen < (call fix s sc o).gen) := by
  cases o <;> simp only [call] <;> (try split) <;> simp

theorem gen_le (fix : Bool) (s : S) (e : Ev) : s.gen ≤ (step fix s e).gen := by
  cases e with
  | call sc o => exact (call_gen fix { s with requested := s.requested ++ sc.toList } sc o).1
  | flush o =>
    simp only [step]; split
    · next t _ => exact (call_gen fix { s with retry := none } (some t) o).1
    · exact (call_gen fix s none o).1
  | observe g ready o =>
    simp only [step]; split
    · split
      · next t _ => exact (call_gen fix { s with retry := none } (some t) o).1
      · exact Nat.le_refl _
    · exact Nat.le_refl _

theorem gen_le_run (fix : Bool) : ∀ (evs : List Ev) (s : S), s.gen ≤ (run fix s evs).gen
  | [], _ => Nat.le_refl _
  | e :: evs, s => Nat.le_trans (gen_le fix s e) (gen_le_run fix evs _)

/-- **A later call that applies, holds or meets a zero viewport retires every
earlier observer**: the generation it captured stays below the current one
from then on, so by `stale_noop` it does nothing. -/
theorem later_gen_lt (fix : Bool) (s : S) (sc : Option Nat) (o : Out) (ho : o ≠ .empty)
    (evs : List Ev) : s.gen < (run fix (step fix s (.call sc o)) evs).gen :=
  Nat.lt_of_lt_of_le (by simpa [step] using (call_gen fix { s with requested := s.requested ++ sc.toList } sc o).2 ho)
    (gen_le_run fix evs _)

/-- **The current hold resumes**: its observer, with its check passing,
applies the pending target when the resumed call applies. -/
theorem resume_applies (fix : Bool) (s : S) (t : Nat) (hr : s.retry = some t) :
    (step fix s (.observe s.gen true .apply)).shown = s.shown ++ [t] ∧
      (step fix s (.observe s.gen true .apply)).pending = none := by
  simp [step, hr, call, pick]

end UltraProofs.ListReadiness
