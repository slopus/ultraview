/-!
# Preparing mutations: one in progress, one newest

Models `PreparationQueue` (PreparationQueue.swift). `UltraListView` submits
every mutation whose rows need measuring first and applies whatever
`takeReady` returns. The queue keeps the entry in progress (`inFlight`) and
the newest successor (`latest`); a newer submission replaces `latest` only,
merging its value in, and a ready `latest` overtakes `inFlight`, merging that
in. Values are modeled as the list of what was merged into them (the
submissions' and `updateNewest`'s blocks); waiting sets as lists of
measurement keys. The Swift's merge (`mergePreparedMutations`) keeps the
newest items and carries an older target and the blocks forward, so
modeling it as concatenation tracks every submission's contribution, not
which fields win.

* `inv_run`: every sequence of `submit`, `complete`, `replaceWaiting`,
  `updateNewest`, `takeReady` and `removeAll` keeps the invariant `Inv`.
* `applied_increasing` (no stale apply): applied generations strictly
  increase, so once a newer mutation has applied an older one never does.
* `conserves`: nothing submitted is lost or applied twice: what has been
  applied, followed by what is queued, is exactly what was submitted, in
  order (since the last `removeAll`, which drops the queue on purpose).
* `newest_applies` (progress): once every key the queued entries wait for has
  been measured, `takeReady` applies the newest submission and empties the
  queue.
* `busy_producer` (no starvation): submissions never touch the entry in
  progress, so once the keys it waited for are measured something applies,
  however many mutations arrived meanwhile. A drain (`drainPreparedMutations`)
  first replaces each entry's waiting keys with the ones it still lacks; the
  theorem needs those keys measured, which is the measurement scheduler's
  side and a hypothesis here.
* `alternating_schedule`: a submission every step whose measurement ends the
  step after. A single newest-wins slot never applies anything
  (`slot_starves`); the queue applies the previous submission at every step.
-/

namespace UltraProofs.ListPreparation

/-- `PreparationQueue.Entry`. -/
structure Entry where
  gen : Nat
  value : List Nat
  waiting : List Nat
deriving DecidableEq

/-- `PreparationQueue`. -/
structure Q where
  inFlight : Option Entry
  latest : Option Entry
  gen : Nat
deriving DecidableEq

def Q.empty : Q := ⟨none, none, 0⟩

/-- `submit(_:waiting:merge:)`, merging by concatenation. -/
def Q.submit (q : Q) (v w : List Nat) : Q :=
  let e : Entry := ⟨q.gen + 1, ((q.latest.map (·.value)).getD []) ++ v, w⟩
  match q.inFlight with
  | none => { q with inFlight := some e, gen := q.gen + 1 }
  | some _ => { q with latest := some e, gen := q.gen + 1 }

def Entry.complete (k : Nat) (e : Entry) : Entry := { e with waiting := e.waiting.filter (· != k) }

/-- `complete(_:)`. -/
def Q.complete (q : Q) (k : Nat) : Q :=
  { q with inFlight := q.inFlight.map (Entry.complete k), latest := q.latest.map (Entry.complete k) }

def Entry.replace (g : Nat) (w : List Nat) (e : Entry) : Entry :=
  if e.gen = g then { e with waiting := w } else e

/-- `replaceWaiting(generation:with:)`. -/
def Q.replaceWaiting (q : Q) (g : Nat) (w : List Nat) : Q :=
  { q with inFlight := q.inFlight.map (Entry.replace g w), latest := q.latest.map (Entry.replace g w) }

def Entry.add (b : Nat) (e : Entry) : Entry := { e with value := e.value ++ [b] }

/-- `updateNewest(_:)`, appending a block. -/
def Q.updateNewest (q : Q) (b : Nat) : Q :=
  match q.latest with
  | some l => { q with latest := some (l.add b) }
  | none => { q with inFlight := q.inFlight.map (Entry.add b) }

/-- The second half of `takeReady`: the entry in progress, if ready. -/
def Q.takeFirst (q : Q) : Q × Option Entry :=
  match q.inFlight with
  | some e => if e.waiting = [] then ({ q with inFlight := q.latest, latest := none }, some e) else (q, none)
  | none => (q, none)

/-- `takeReady(merge:)`. -/
def Q.takeReady (q : Q) : Q × Option Entry :=
  match q.latest with
  | some l =>
    if l.waiting = [] then
      ({ q with inFlight := none, latest := none },
        some { l with value := ((q.inFlight.map (·.value)).getD []) ++ l.value })
    else q.takeFirst
  | none => q.takeFirst

inductive Op
  | submit (v w : List Nat)
  | complete (k : Nat)
  | replace (g : Nat) (w : List Nat)
  | update (b : Nat)
  | take
  | clear

/-- The queue, the entries applied so far in order, and everything the queue
has accepted: submissions, and blocks added while it was not empty (an empty
queue's caller animates a block at once). `removeAll`, which the list calls
when it is given no items, drops what is queued, so it forgets it. -/
abbrev State := Q × List Entry × List Nat

def values (applied : List Entry) : List Nat := (applied.map (·.value)).flatten

def step (s : State) : Op → State
  | .submit v w => (s.1.submit v w, s.2.1, s.2.2 ++ v)
  | .complete k => (s.1.complete k, s.2)
  | .replace g w => (s.1.replaceWaiting g w, s.2)
  | .update b => (s.1.updateNewest b, s.2.1, match s.1.inFlight with | none => s.2.2 | some _ => s.2.2 ++ [b])
  | .take => ((s.1.takeReady).1, s.2.1 ++ (s.1.takeReady).2.toList, s.2.2)
  | .clear => ({ s.1 with inFlight := none, latest := none }, s.2.1, values s.2.1)

def run (s : State) (ops : List Op) : State := ops.foldl step s

def queued (q : Q) : List Entry := q.inFlight.toList ++ q.latest.toList

/-- The invariant, by the queue's shape: applied generations increase; the
entry in progress is older than its successor, the newest carries the
counter, everything applied is older than everything queued; and what has
been applied followed by what is queued is what was accepted. -/
def Inv (s : State) : Prop :=
  s.2.1.Pairwise (fun a b => a.gen < b.gen) ∧
  match s.1.inFlight, s.1.latest with
  | none, none => (∀ a ∈ s.2.1, a.gen ≤ s.1.gen) ∧ values s.2.1 = s.2.2
  | some e, none => e.gen = s.1.gen ∧ (∀ a ∈ s.2.1, a.gen < e.gen) ∧ values s.2.1 ++ e.value = s.2.2
  | some e, some l => e.gen < l.gen ∧ l.gen = s.1.gen ∧ (∀ a ∈ s.2.1, a.gen < e.gen) ∧
      values s.2.1 ++ e.value ++ l.value = s.2.2
  | none, some _ => False

@[simp] theorem complete_gen (k : Nat) (e : Entry) : (e.complete k).gen = e.gen := rfl
@[simp] theorem complete_value (k : Nat) (e : Entry) : (e.complete k).value = e.value := rfl
@[simp] theorem replace_gen (g : Nat) (w : List Nat) (e : Entry) : (e.replace g w).gen = e.gen := by
  unfold Entry.replace; split <;> rfl
@[simp] theorem replace_value (g : Nat) (w : List Nat) (e : Entry) : (e.replace g w).value = e.value := by
  unfold Entry.replace; split <;> rfl
@[simp] theorem add_gen (b : Nat) (e : Entry) : (e.add b).gen = e.gen := rfl
@[simp] theorem add_value (b : Nat) (e : Entry) : (e.add b).value = e.value ++ [b] := rfl
@[simp] theorem values_append (a b : List Entry) : values (a ++ b) = values a ++ values b := by
  simp [values]
@[simp] theorem values_single (e : Entry) : values [e] = e.value := by simp [values]

theorem pairwise_snoc {applied : List Entry} {x : Entry} (h : applied.Pairwise (fun a b => a.gen < b.gen))
    (hx : ∀ a ∈ applied, a.gen < x.gen) : (applied ++ [x]).Pairwise (fun a b => a.gen < b.gen) := by
  rw [List.pairwise_append]; exact ⟨h, by simp, fun a ha b hb => by simp at hb; subst hb; exact hx a ha⟩

theorem inv_empty : Inv (Q.empty, [], []) := by simp [Inv, Q.empty, values]

theorem inv_step {s : State} (h : Inv s) (op : Op) : Inv (step s op) := by
  obtain ⟨⟨i, l, g⟩, applied, log⟩ := s
  obtain ⟨sorted, h⟩ := h
  dsimp only at sorted h
  cases i with
  | none =>
    cases l with
    | some _ => exact absurd h (by simp)
    | none =>
      dsimp only at h
      obtain ⟨le, cv⟩ := h
      cases op with
      | submit v w =>
        refine ⟨sorted, ?_⟩
        dsimp only [step, Q.submit, Option.map, Option.getD]
        exact ⟨rfl, fun a ha => Nat.lt_succ_of_le (le a ha), by rw [← cv]; simp⟩
      | complete k => exact ⟨sorted, le, cv⟩
      | replace _ _ => exact ⟨sorted, le, cv⟩
      | update b => exact ⟨sorted, le, cv⟩
      | take => exact ⟨by simpa [step, Q.takeReady, Q.takeFirst] using sorted,
          by simpa [step, Q.takeReady, Q.takeFirst] using le,
          by simpa [step, Q.takeReady, Q.takeFirst] using cv⟩
      | clear => exact ⟨sorted, le, rfl⟩
  | some e =>
    cases l with
    | none =>
      dsimp only at h
      obtain ⟨eg, lt, cv⟩ := h
      cases op with
      | submit v w =>
        refine ⟨sorted, ?_⟩
        dsimp only [step, Q.submit, Option.map, Option.getD]
        exact ⟨by omega, rfl, lt, by rw [← cv]; simp⟩
      | complete k => exact ⟨sorted, eg, lt, cv⟩
      | replace g' w =>
        refine ⟨sorted, ?_⟩
        dsimp only [step, Q.replaceWaiting, Option.map]
        simp only [replace_gen, replace_value]
        exact ⟨eg, lt, cv⟩
      | update b =>
        refine ⟨sorted, ?_⟩
        dsimp only [step, Q.updateNewest, Option.map]
        exact ⟨eg, lt, by rw [← cv]; simp⟩
      | take =>
        by_cases hw : e.waiting = []
        · simp only [step, Q.takeReady, Q.takeFirst, hw, eq_self, ite_true, Option.toList]
          dsimp only [Inv]
          refine ⟨pairwise_snoc sorted lt, ?_, by simpa using cv⟩
          intro a ha
          rcases List.mem_append.mp ha with ha | ha
          · have := lt a ha; omega
          · simp at ha; subst ha; omega
        · simp only [step, Q.takeReady, Q.takeFirst, hw, ite_false, Option.toList, List.append_nil]
          exact ⟨sorted, eg, lt, cv⟩
      | clear => exact ⟨sorted, fun a ha => by have := lt a ha; dsimp only [step]; omega, rfl⟩
    | some l =>
      dsimp only at h
      obtain ⟨el, lg, lt, cv⟩ := h
      cases op with
      | submit v w =>
        refine ⟨sorted, ?_⟩
        dsimp only [step, Q.submit, Option.map, Option.getD]
        exact ⟨by omega, rfl, lt, by rw [← cv]; simp⟩
      | complete k => exact ⟨sorted, el, lg, lt, cv⟩
      | replace g' w =>
        refine ⟨sorted, ?_⟩
        dsimp only [step, Q.replaceWaiting, Option.map]
        simp only [replace_gen, replace_value]
        exact ⟨el, lg, lt, cv⟩
      | update b =>
        refine ⟨sorted, ?_⟩
        dsimp only [step, Q.updateNewest]
        exact ⟨el, lg, lt, by rw [← cv]; simp⟩
      | take =>
        by_cases hl : l.waiting = []
        · simp only [step, Q.takeReady, hl, eq_self, ite_true, Option.toList, Option.map, Option.getD]
          dsimp only [Inv]
          refine ⟨pairwise_snoc sorted (fun a ha => by have := lt a ha; dsimp only; omega), ?_, ?_⟩
          · intro a ha
            rcases List.mem_append.mp ha with ha | ha
            · have := lt a ha; omega
            · simp at ha; subst ha; dsimp only; omega
          · rw [← cv]; simp
        · by_cases he : e.waiting = []
          · simp only [step, Q.takeReady, hl, ite_false, Q.takeFirst, he, eq_self, ite_true, Option.toList]
            dsimp only [Inv]
            refine ⟨pairwise_snoc sorted lt, lg, ?_, by rw [← cv]; simp⟩
            intro a ha
            rcases List.mem_append.mp ha with ha | ha
            · have := lt a ha; omega
            · simp at ha; subst ha; exact el
          · simp only [step, Q.takeReady, hl, ite_false, Q.takeFirst, he, Option.toList, List.append_nil]
            exact ⟨sorted, el, lg, lt, cv⟩
      | clear => exact ⟨sorted, fun a ha => by have := lt a ha; dsimp only [step]; omega, rfl⟩

theorem inv_run : ∀ (ops : List Op) {s : State}, Inv s → Inv (run s ops)
  | [], _, h => h
  | op :: ops, _, h => inv_run ops (inv_step h op)

/-- **No stale apply.** From an empty queue, whatever the operations, the
applied generations strictly increase: once a newer mutation has applied, an
older one never does. -/
theorem applied_increasing (ops : List Op) :
    (run (Q.empty, [], []) ops).2.1.Pairwise (fun a b => a.gen < b.gen) :=
  (inv_run ops inv_empty).1

theorem inv_conserve {s : State} (h : Inv s) :
    values s.2.1 ++ (queued s.1).flatMap (·.value) = s.2.2 := by
  obtain ⟨⟨i, l, g⟩, applied, log⟩ := s
  obtain ⟨_, h⟩ := h
  dsimp only at h ⊢
  cases i with
  | none =>
    cases l with
    | none => dsimp only at h; simpa [queued] using h.2
    | some _ => exact absurd h (by simp)
  | some e =>
    cases l with
    | none => dsimp only at h; simpa [queued] using h.2.2
    | some l => dsimp only at h; simpa [queued] using h.2.2.2

/-- **Nothing is lost or applied twice.** What has been applied, followed by
what is still queued, is everything the queue accepted, in order. -/
theorem conserves (ops : List Op) :
    values (run (Q.empty, [], []) ops).2.1 ++ (queued (run (Q.empty, [], []) ops).1).flatMap (·.value) =
      (run (Q.empty, [], []) ops).2.2 :=
  inv_conserve (inv_run ops inv_empty)

/-- **The newest submission applies once its measurements are in.** With
nothing waiting, `takeReady` applies an entry carrying the newest generation
and leaves the queue empty. -/
theorem newest_applies {s : State} (h : Inv s) (hne : s.1.inFlight ≠ none)
    (hw : ∀ e ∈ queued s.1, e.waiting = []) :
    ∃ e, s.1.takeReady.2 = some e ∧ e.gen = s.1.gen ∧ queued s.1.takeReady.1 = [] := by
  obtain ⟨⟨i, l, g⟩, applied, log⟩ := s
  obtain ⟨_, h⟩ := h
  dsimp only at h hne hw ⊢
  cases i with
  | none => exact absurd rfl hne
  | some e =>
    cases l with
    | none =>
      dsimp only at h
      have := hw e (by simp [queued])
      exact ⟨e, by simp [Q.takeReady, Q.takeFirst, this], h.1, by simp [Q.takeReady, Q.takeFirst, this, queued]⟩
    | some l =>
      dsimp only at h
      have := hw l (by simp [queued])
      exact ⟨{ l with value := e.value ++ l.value }, by simp [Q.takeReady, this], h.2.1,
        by simp [Q.takeReady, this, queued]⟩

/-- An operation that is not `takeReady` or `replaceWaiting`: what the
mutation producer and the measurements do between two drains. -/
def Op.Busy : Op → Prop
  | .submit .. | .complete _ | .update _ => True
  | _ => False

/-- The keys an operation measures. -/
def Op.done : Op → List Nat
  | .complete k => [k]
  | _ => []

theorem busy_inFlight : ∀ (ops : List Op), (∀ op ∈ ops, op.Busy) → ∀ (s : State) (e : Entry),
    s.1.inFlight = some e →
    ∃ e', (run s ops).1.inFlight = some e' ∧ e'.gen = e.gen ∧
      e'.waiting = e.waiting.filter (· ∉ ops.flatMap Op.done)
  | [], _, _, e, h => ⟨e, h, rfl, (List.filter_eq_self.mpr (by simp)).symm⟩
  | op :: ops, hb, s, e, h => by
    have hb' : ∀ op ∈ ops, op.Busy := fun o ho => hb o (List.mem_cons_of_mem _ ho)
    cases op with
    | submit v w =>
      obtain ⟨e', h1, h2, h3⟩ := busy_inFlight ops hb' (step s (.submit v w)) e
        (by simp [step, Q.submit, h])
      exact ⟨e', h1, h2, by simpa [Op.done] using h3⟩
    | complete k =>
      obtain ⟨e', h1, h2, h3⟩ := busy_inFlight ops hb' (step s (.complete k)) (e.complete k)
        (by simp [step, Q.complete, h])
      refine ⟨e', h1, h2, ?_⟩
      rw [h3]; simp only [Entry.complete, List.filter_filter, Op.done, List.flatMap_cons]
      congr 1; funext x; simp; grind
    | update b =>
      have : (step s (.update b)).1.inFlight = some e ∨ (step s (.update b)).1.inFlight = some (e.add b) := by
        simp only [step, Q.updateNewest]; rcases hl : s.1.latest with _ | l <;> simp [h]
      rcases this with h' | h'
      · obtain ⟨e', h1, h2, h3⟩ := busy_inFlight ops hb' _ e h'
        exact ⟨e', h1, h2, by simpa [Op.done] using h3⟩
      · obtain ⟨e', h1, h2, h3⟩ := busy_inFlight ops hb' _ (e.add b) h'
        exact ⟨e', h1, h2, by simpa [Op.done, Entry.add] using h3⟩
    | replace _ _ => exact absurd (hb _ (List.mem_cons_self ..)) (by simp [Op.Busy])
    | take => exact absurd (hb _ (List.mem_cons_self ..)) (by simp [Op.Busy])
    | clear => exact absurd (hb _ (List.mem_cons_self ..)) (by simp [Op.Busy])

/-- **A busy producer cannot starve the queue.** Submissions never replace
the entry in progress, so whatever mutations arrive meanwhile, once every key
it waited for has been measured `takeReady` applies something. -/
theorem busy_producer (ops : List Op) (hb : ∀ op ∈ ops, op.Busy) (s : State) (e : Entry)
    (h : s.1.inFlight = some e) (hd : ∀ k ∈ e.waiting, k ∈ ops.flatMap Op.done) :
    ((run s ops).1.takeReady).2 ≠ none := by
  obtain ⟨e', h1, _, h3⟩ := busy_inFlight ops hb s e h
  have hw : e'.waiting = [] := by
    rw [h3, List.filter_eq_nil_iff]; intro k hk; simpa using hd k hk
  unfold Q.takeReady
  split
  · split
    · simp
    · simp [Q.takeFirst, h1, hw]
  · simp [Q.takeFirst, h1, hw]

/-! ## Newest wins starves -/

/-- One slot that every submission replaces. -/
def slotStep (s : Option Entry × List Entry) : Op → Option Entry × List Entry
  | .submit v w => (some ⟨0, v, w⟩, s.2)
  | .complete k => (s.1.map (Entry.complete k), s.2)
  | .take => match s.1 with
    | some e => if e.waiting = [] then (none, s.2 ++ [e]) else s
    | none => s
  | _ => s

/-- Step `i` of the schedule: submission `i`, waiting for key `i + 1`; the
measurement of key `i` (the previous submission's) finishes; then a drain. -/
def stepOps (i : Nat) : List Op := [.submit [i] [i + 1], .complete i, .take]

def schedule (n : Nat) : List Op := (List.range n).flatMap stepOps

theorem schedule_succ (n : Nat) : schedule (n + 1) = schedule n ++ stepOps n := by
  simp [schedule, List.range_succ, List.flatMap_append]

theorem slot_after (n : Nat) : (schedule (n + 1)).foldl slotStep (none, []) =
    (some ⟨0, [n], [n + 1]⟩, []) := by
  induction n with
  | zero => simp [schedule, stepOps, slotStep, Entry.complete]
  | succ n ih =>
    rw [schedule_succ (n + 1), List.foldl_append, ih]
    simp [stepOps, slotStep, Entry.complete]

/-- **Newest wins starves.** Submitting every step while each measurement
ends a step later, a single slot that every submission replaces applies
nothing, however long it runs. -/
theorem slot_starves (n : Nat) : ((schedule n).foldl slotStep (none, [])).2 = [] := by
  cases n with
  | zero => rfl
  | succ n => rw [slot_after]

theorem queue_after (n : Nat) : run (Q.empty, [], []) (schedule (n + 1)) =
    (⟨some ⟨n + 1, [n], [n + 1]⟩, none, n + 1⟩, (List.range n).map (fun j => ⟨j + 1, [j], []⟩),
      (List.range (n + 1)).flatMap fun j => [j]) := by
  induction n with
  | zero => simp [run, schedule, stepOps, step, Q.submit, Q.complete, Q.empty, Entry.complete,
      Q.takeReady, Q.takeFirst]
  | succ n ih =>
    simp only [run] at ih ⊢
    rw [schedule_succ (n + 1), List.foldl_append, ih]
    simp [stepOps, step, Q.submit, Q.complete, Entry.complete, Q.takeReady, Q.takeFirst,
      List.range_succ]

/-- **The queue keeps up.** Under the same schedule, after `n + 1` steps the
queue has applied submissions `0` to `n - 1` in order, one a step, and has
the latest one in progress, while the single slot has applied nothing. -/
theorem alternating_schedule (n : Nat) :
    (run (Q.empty, [], []) (schedule (n + 1))).2.1.map (·.value) = (List.range n).map (fun j => [j]) ∧
      ((schedule (n + 1)).foldl slotStep (none, [])).2 = [] := by
  rw [queue_after, slot_after]; simp

end UltraProofs.ListPreparation
