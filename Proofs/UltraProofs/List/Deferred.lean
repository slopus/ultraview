/-!
# Accessory updates deferred past a list pass

The chat's composer bar copies the list's viewport animation so the two move
on one progress (`ListPass.lockstep_iff`). The copy reads whatever viewport
animation is installed when the bar's update runs. A call to `applyChanges`
made during a list pass is queued and runs after it, so a bar that updated
first and then called the list copied the animation the previous pass left.
`UltraListView.performAfterCurrentPass` queues the whole update instead: the
list installs its animation and the bar copies it in the same run.

* `shared_inv`: with the whole update queued, every update the bar applies
  copies the viewport animation the list installed for that same update.
* `old_stale`: updating the bar first and queueing only the list's part
  (the code before) gives the bar the previous animation.
* `applies_idle`: an update is applied only outside a pass.
* `once_inv`: every requested update is applied, waiting in the queue, or
  dispatched to the main queue, exactly once.
* `run_all`: once the pass has ended, running the dispatched block applies
  every queued update in the order it was requested.
* `overtake_sample`: an update requested outside a pass after the pass ended
  but before the dispatched block runs is applied before the queued ones.
* `normalize_affine`: when the template's keyframes are any viewport track's
  values on a sampled progress `p` (from 0 to 1), rescaling them to the bar's
  displacement gives the bar `d * (1 - p)`, the same progress, never the
  viewport's own values.
-/

namespace UltraProofs.ListDeferred

/-- One applied update: the generation of the viewport animation the list
installed for it, and the one the bar copied. -/
structure Entry where
  req : Nat
  list : Nat
  bar : Nat
deriving DecidableEq

/-- The list's pass flag, its deferred operations, the block dispatched to
the main queue with earlier ones, the installed viewport animation's
generation, the applied updates and every request made. -/
structure S where
  passing : Bool
  queue : List Nat
  batch : List Nat
  gen : Nat
  log : List Entry
  issued : List Nat
deriving DecidableEq

inductive Ev
  /-- A list pass begins (`passing = true`). -/
  | begin
  /-- The running pass installs a viewport animation of its own. -/
  | install
  /-- The pass ends: `passing = false`, and the deferred operations go to the
  main queue as one block after any earlier one. -/
  | finish
  /-- The chat asks to update the bar and the list's inset. -/
  | request (r : Nat)
  /-- The main queue runs the next dispatched operation, outside any pass. -/
  | run

/-- The update itself: the list's inset-only change installs a new viewport
animation, then the bar copies the one installed. -/
def apply (s : S) (r : Nat) : S :=
  { s with gen := s.gen + 1, log := s.log ++ [⟨r, s.gen + 1, s.gen + 1⟩] }

/-- `performAfterCurrentPass`: queued whole during a pass, run at once outside. -/
def perform (s : S) (r : Nat) : S :=
  if s.passing then { s with queue := s.queue ++ [r] } else apply s r

def step (s : S) : Ev → S
  | .begin => if s.passing then s else { s with passing := true }
  | .install => if s.passing then { s with gen := s.gen + 1 } else s
  | .finish => if s.passing then { s with passing := false, batch := s.batch ++ s.queue, queue := [] } else s
  | .request r => perform { s with issued := s.issued ++ [r] } r
  | .run => match s.batch with
    | [] => s
    | r :: rest => if s.passing then s else perform { s with batch := rest } r

def run (s : S) : List Ev → S
  | [] => s
  | e :: es => run (step s e) es

/-! ## The bar copies its own update's animation -/

def Shared (s : S) : Prop := ∀ e ∈ s.log, e.list = e.bar

theorem apply_shared {s : S} (h : Shared s) (r : Nat) : Shared (apply s r) := by
  intro e he
  simp only [apply, List.mem_append, List.mem_singleton] at he
  rcases he with he | he
  · exact h e he
  · subst he; rfl

theorem perform_shared {s : S} (h : Shared s) (r : Nat) : Shared (perform s r) := by
  unfold perform
  split
  · exact h
  · exact apply_shared h r

theorem step_shared {s : S} (h : Shared s) (e : Ev) : Shared (step s e) := by
  cases e with
  | begin => simp only [step]; split <;> exact h
  | install => simp only [step]; split <;> exact h
  | finish => simp only [step]; split <;> exact h
  | request r => exact perform_shared (s := { s with issued := s.issued ++ [r] }) h r
  | run =>
    simp only [step]
    split
    · exact h
    · rename_i r rest _
      split
      · exact h
      · exact perform_shared (s := { s with batch := rest }) h r

/-- **Every applied update's bar copies the animation the list installed for
it**, in every interleaving of passes, requests and main-queue turns. -/
theorem shared_inv (s : S) (h : Shared s) : ∀ es, Shared (run s es)
  | [] => h
  | e :: es => shared_inv (step s e) (step_shared h e) es

/-- An update is applied only outside a pass. -/
theorem applies_idle (s : S) (e : Ev) (h : (step s e).log ≠ s.log) : s.passing = false := by
  cases e with
  | begin => simp only [step] at h; split at h <;> exact absurd rfl h
  | install => simp only [step] at h; split at h <;> exact absurd rfl h
  | finish => simp only [step] at h; split at h <;> exact absurd rfl h
  | request r =>
    simp only [step, perform] at h
    split at h
    · exact absurd rfl h
    · rename_i hp; simpa using hp
  | run =>
    simp only [step] at h
    split at h
    · exact absurd rfl h
    · split at h
      · exact absurd rfl h
      · rename_i hp; simpa using hp

/-! ## The code before: the bar first, the list's part queued -/

/-- Before `c5743ae`: the bar copied the installed animation at once, and the
list's part waited with what the bar had copied. -/
structure O where
  passing : Bool
  queue : List (Nat × Nat)
  gen : Nat
  log : List Entry

def O.request (s : O) (r : Nat) : O :=
  if s.passing then { s with queue := s.queue ++ [(r, s.gen)] }
  else { s with gen := s.gen + 1, log := s.log ++ [⟨r, s.gen + 1, s.gen + 1⟩] }

def O.flush (s : O) : O :=
  s.queue.foldl (fun t q => { t with gen := t.gen + 1, log := t.log ++ [⟨q.1, t.gen + 1, q.2⟩] })
    { s with passing := false, queue := [] }

/-- **The bar took the previous pass's animation.** -/
theorem old_stale (g r : Nat) (log : List Entry) :
    (O.flush (O.request ⟨true, [], g, log⟩ r)).log = log ++ [⟨r, g + 1, g⟩] := by
  simp [O.request, O.flush]

/-! ## Exactly once -/

/-- Every request is applied, queued or dispatched, once. -/
def Once (s : S) : Prop := (s.log.map Entry.req ++ s.batch ++ s.queue).Perm s.issued

theorem perm_move {α : Type} (a b c : List α) (x : α) :
    (a ++ [x] ++ b ++ c).Perm (a ++ (x :: b) ++ c) := by
  simp only [List.append_assoc, List.singleton_append]
  exact List.Perm.refl _

theorem apply_once_of {s : S} {r : Nat} :
    ((apply s r).log.map Entry.req) = s.log.map Entry.req ++ [r] := by
  simp [apply]

theorem step_once {s : S} (h : Once s) (e : Ev) : Once (step s e) := by
  unfold Once at h ⊢
  cases e with
  | begin => simp only [step]; split <;> exact h
  | install => simp only [step]; split <;> exact h
  | finish =>
    simp only [step]; split
    · simpa [List.append_assoc] using h
    · exact h
  | request r =>
    have h' := List.Perm.append_right [r] h
    simp only [step, perform]
    split
    · simp only [List.append_assoc] at h' ⊢
      exact h'
    · simp only [apply, List.map_append, List.map_cons, List.map_nil, List.append_assoc] at h' ⊢
      refine List.Perm.trans ?_ h'
      refine List.Perm.append_left _ ?_
      rw [← List.append_assoc s.batch]; exact List.perm_append_comm
  | run =>
    simp only [step]
    split
    · exact h
    · rename_i r rest hb
      split
      · exact h
      · rw [hb] at h
        rename_i hp
        simp only [Bool.not_eq_true] at hp
        simp only [perform, hp, Bool.false_eq_true, ite_false, apply, List.map_append, List.map_cons, List.map_nil]
        exact (perm_move _ _ _ r).trans h

theorem once_inv (s : S) (h : Once s) : ∀ es, Once (run s es)
  | [] => h
  | e :: es => once_inv (step s e) (step_once h e) es

/-! ## Draining in order -/

def runs : Nat → List Ev
  | 0 => []
  | n + 1 => .run :: runs n

/-- **After the pass, the dispatched block applies every queued update in
order.** -/
theorem run_all (q iss : List Nat) : ∀ (b : List Nat) (g : Nat) (log : List Entry),
    (run ⟨false, q, b, g, log, iss⟩ (runs b.length)).log.map Entry.req = log.map Entry.req ++ b ∧
      (run ⟨false, q, b, g, log, iss⟩ (runs b.length)).batch = [] ∧
      (run ⟨false, q, b, g, log, iss⟩ (runs b.length)).passing = false
  | [], g, log => by simp [runs, run]
  | r :: rest, g, log => by
    have ih := run_all q iss rest (g + 1) (log ++ [⟨r, g + 1, g + 1⟩])
    simp only [List.length_cons, runs, run, step, perform, apply, Bool.false_eq_true, ite_false] at ih ⊢
    refine ⟨?_, ih.2⟩
    rw [ih.1]; simp

/-- **A later request overtakes the queued one.** One update is queued during
a pass; after the pass ends and before the main queue runs its block, a
second request outside a pass applies at once, so the first is applied
last. -/
theorem overtake_sample :
    (run ⟨false, [], [], 0, [], []⟩ [.begin, .request 1, .finish, .request 2, .run]).log.map Entry.req =
      [2, 1] := by
  decide +kernel

/-! ## Rescaling copied keyframes -/

/-- `values.map { displacement * ($0 - last) / (first - last) }`. -/
def normalize (d first last v : Rat) : Rat := d * (v - last) / (first - last)

/-- **The bar keeps the viewport's progress.** A viewport track from `a` to
`a + b` (any `b ≠ 0`) on samples `p` with `p₀ = 0` and `pₙ = 1` has keyframes
`a + b p`; rescaled to the bar's displacement they are `d (1 - p)`. -/
theorem normalize_affine (a b d p : Rat) (hb : b ≠ 0) :
    normalize d (a + b * 0) (a + b * 1) (a + b * p) = d * (1 - p) := by
  unfold normalize
  have e1 : a + b * p - (a + b * 1) = (p - 1) * b := by grind
  have e2 : a + b * 0 - (a + b * 1) = -b := by grind
  rw [e1, e2]
  have hb' : -b ≠ 0 := by grind
  rw [show d * ((p - 1) * b) = (d * (1 - p)) * (-b) by grind]
  exact Rat.mul_div_cancel hb'

/-- The same for every keyframe. -/
theorem normalize_all (a b d : Rat) (hb : b ≠ 0) (ps : List Rat) :
    ps.map (fun p => normalize d (a + b * 0) (a + b * 1) (a + b * p)) = ps.map (fun p => d * (1 - p)) :=
  List.map_congr_left (fun p _ => normalize_affine a b d p hb)

end UltraProofs.ListDeferred
