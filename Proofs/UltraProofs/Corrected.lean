import UltraProofs.Scheduling
import UltraProofs.Optimality

/-!
# The properties the Swift should have, for the corrected designs

Each section is a finding from the review against the Swift at the pinned
commit (see MAPPING.md), with the corrected design modeled and its property
proved. Findings proved elsewhere: ranges are contiguous runs
(`Ranges.range_contiguous`, finding 3), pixel rounding needs only the
flagged nodes (`Optimality.round_relative_stable`, finding 5), and what
"frame unchanged ⇒ not re-evaluated" needs (`Optimality.deps_of_inputs` and
`Optimality.stale_when_aux_ignored`, finding 8).
-/

namespace UltraProofs.Corrected

open UltraProofs UltraProofs.Scheduling UltraProofs.Pass UltraProofs.Optimality

/-! ## Finding 1: host updates coalesce like mutations

`Renderer.update` enqueues a pass on every call. With the same guard as
`setNeedsPass` (enqueue only when `passScheduled` was clear), host updates
are coalesced too: at most one pass per epoch, whatever mixes of mutations
and updates arrive. -/

inductive FixedStep (t : Tree) : State → State → Prop
  /-- Every step but the unguarded host update. -/
  | base {s s' : State} : Step t s s' → s'.updates = s.updates → FixedStep t s s'
  /-- The guarded host update, counted as a flip when it enqueues. -/
  | update (s : State) :
      FixedStep t s { s with
        scheduled := true
        queued := if s.scheduled then s.queued else s.queued + 1
        epochFlips := if s.scheduled then s.epochFlips else s.epochFlips + 1
        flips := if s.scheduled then s.flips else s.flips + 1 }

theorem FixedStep.inv {t : Tree} {s s' : State} (hI : Inv t s) (h : FixedStep t s s') :
    Inv t s' := by
  cases h with
  | base h _ => exact hI.step h
  | update =>
    refine ⟨?_, ?_, ?_, hI.idle⟩
    · intro n hn
      obtain ⟨a, hm, hw⟩ := hI.needs n hn
      exact ⟨a, hm, hw.mono (fun _ h => h) (fun _ => rfl) (fun _ h => h) rfl⟩
    · intro n hn
      obtain ⟨a, hm, hw⟩ := hI.desc n hn
      exact ⟨a, hm, hw.mono (fun _ h => h) (fun _ => rfl) (fun _ h => h) rfl⟩
    · intro _
      cases e : s.scheduled
      · simp
      · simp [hI.sched e]

/-- With guarded updates, every pass is paid for by one flip, and an epoch
has at most one flip. -/
structure FixedCount (q₀ : Nat) (s : State) : Prop where
  epoch : s.epochFlips ≤ 1
  epoch_sched : s.epochFlips = 1 → s.scheduled = true
  queue : s.queued + s.starts = q₀ + s.flips

theorem FixedCount.step {t : Tree} {q₀ : Nat} {s s' : State} (hC : FixedCount q₀ s)
    (h : FixedStep t s s') : FixedCount q₀ s' := by
  have ⟨he, hes, hq⟩ := hC
  cases h with
  | update =>
    cases hs : s.scheduled
    · have : s.epochFlips = 0 := by
        cases Nat.lt_or_ge s.epochFlips 1 with
        | inl h => omega
        | inr h => have := hes (by omega); simp [hs] at this
      exact ⟨by simp; omega, fun _ => rfl, by simp; omega⟩
    · exact ⟨by simp; omega, fun _ => rfl, by simp; omega⟩
  | base h hu =>
    cases h with
    | hostUpdate => simp at hu
    | mutate => exact ⟨he, hes, hq⟩
    | walkUp => exact ⟨he, hes, hq⟩
    | walkRoot =>
      cases hs : s.scheduled
      · have : s.epochFlips = 0 := by
          cases Nat.lt_or_ge s.epochFlips 1 with
          | inl h => omega
          | inr h => have := hes (by omega); simp [hs] at this
        exact ⟨by simp; omega, fun _ => rfl, by simp; omega⟩
      · exact ⟨by simp; omega, fun _ => rfl, by simp; omega⟩
    | start => exact ⟨by simp, by simp, by simp; omega⟩
    | visitA => exact ⟨he, hes, hq⟩
    | visitB => exact ⟨he, hes, hq⟩
    | finish => exact ⟨he, hes, hq⟩

/-- **Passes ≤ flips, at most one flip per epoch**: host updates no longer add
passes of their own. -/
theorem fixed_passes_le {q₀ : Nat} {s : State} (hC : FixedCount q₀ s) : s.starts ≤ q₀ + s.flips := by
  have := hC.queue; omega

/-! ## Finding 2: a dirty queue makes the sync walk cost the dirty nodes

The Swift sync walk visits every child of every marked ancestor
(`Scheduling.sync_cost`). With a queue of dirty nodes, appended under a lock
by the first mutation of a node since its last sync, a pass syncs exactly
the distinct nodes that changed. -/

structure DQ where
  dirty : Node → Bool
  queue : List Node
  scheduled : Bool
  queued : Nat
  running : Bool
  work : List Node
  synced : Nat

inductive DQStep : DQ → DQ → Prop
  /-- A mutation, under the queue's lock. -/
  | mutate (s : DQ) (n : Node) :
      DQStep s { s with
        dirty := upd s.dirty n true
        queue := if s.dirty n then s.queue else n :: s.queue
        scheduled := true
        queued := if s.scheduled then s.queued else s.queued + 1 }
  /-- A pass starts and takes the queue. -/
  | start (s : DQ) (hr : s.running = false) (hq : 0 < s.queued) :
      DQStep s { s with
        dirty := fun n => if n ∈ s.queue then false else s.dirty n
        queue := [], work := s.queue, scheduled := false, queued := s.queued - 1
        running := true, synced := 0 }
  | sync (s : DQ) (v : Node) (rest : List Node) (h : s.work = v :: rest) :
      DQStep s { s with work := rest, synced := s.synced + 1 }
  | finish (s : DQ) (hr : s.running = true) (h : s.work = []) : DQStep s { s with running := false }

structure DQInv (s : DQ) : Prop where
  dirty_queue : ∀ n, s.dirty n = true ↔ n ∈ s.queue
  nodup : s.queue.Nodup
  queue_sched : s.queue ≠ [] → s.scheduled = true
  sched : s.scheduled = true → 0 < s.queued
  idle : s.running = false → s.work = []

theorem DQInv.step {s s' : DQ} (hI : DQInv s) (h : DQStep s s') : DQInv s' := by
  cases h with
  | mutate n =>
    refine ⟨?_, ?_, fun _ => rfl, ?_, hI.idle⟩
    · intro m
      by_cases hm : m = n
      · subst hm
        cases hd : s.dirty m
        · simp
        · simp [(hI.dirty_queue m).1 hd]
      · cases hd : s.dirty n
        · simp [upd, hm, hI.dirty_queue m]
        · simp [upd, hm, hI.dirty_queue m]
    · cases hd : s.dirty n
      · simp only [Bool.false_eq_true, ite_false]
        refine List.nodup_cons.2 ⟨?_, hI.nodup⟩
        intro hmem; have := (hI.dirty_queue n).2 hmem; simp [hd] at this
      · simpa [hd] using hI.nodup
    · intro _
      cases e : s.scheduled
      · simp
      · simp [hI.sched e]
  | start hr hq =>
    refine ⟨?_, by simp, fun h => absurd rfl h, fun h => by simp at h, fun h => by simp at h⟩
    intro m
    by_cases hm : m ∈ s.queue
    · simp [hm]
    · simp only [hm, ite_false, List.not_mem_nil, iff_false]
      intro hd; exact hm ((hI.dirty_queue m).1 hd)
  | sync v rest hw =>
    refine ⟨hI.dirty_queue, hI.nodup, hI.queue_sched, hI.sched, ?_⟩
    intro hr
    have := hI.idle hr; rw [hw] at this; cases this
  | finish hr hw =>
    exact ⟨hI.dirty_queue, hI.nodup, hI.queue_sched, hI.sched, fun _ => hw⟩

/-- **No lost update**: when no pass is queued, no node is dirty. -/
theorem dq_idle_clean {s : DQ} (hI : DQInv s) (hq : s.queued = 0) :
    ∀ n, s.dirty n = false := by
  intro n
  cases hd : s.dirty n
  · rfl
  · have hmem := (hI.dirty_queue n).1 hd
    have hne : s.queue ≠ [] := by intro e; rw [e] at hmem; cases hmem
    have := hI.sched (hI.queue_sched hne)
    omega

/-- **Cost**: a pass syncs exactly the distinct dirty nodes it took, each once. -/
theorem dq_start_work {s : DQ} (hI : DQInv s) :
    s.queue.Nodup ∧ ∀ n, n ∈ s.queue ↔ s.dirty n = true :=
  ⟨hI.nodup, fun n => (hI.dirty_queue n).symm⟩

/-! ## Finding 4: the mailbox's semaphore should not pile up permits

`CommitMailbox.post` signals on every post, but only `waitForCommit` waits.
Each permit left over makes a later `waitForPost` return at once, so the
main thread's wait loop goes round once per stale permit before it blocks.
Signalling only while a waiter is registered keeps that at zero. -/

/-- Iterations of the wait loop that return without blocking, while the
commit it waits for has not been posted. -/
def spins : Nat → Nat
  | 0 => 0
  | p + 1 => spins p + 1

/-- Permits after `k` posts with nobody waiting: Swift signals each time. -/
def permitsSwift (k : Nat) : Nat := k

/-- With a registered-waiter check, posts with nobody waiting signal nothing. -/
def permitsFixed (_k : Nat) : Nat := 0

theorem spins_eq (p : Nat) : spins p = p := by
  induction p with
  | zero => rfl
  | succ p ih => simp [spins, ih]

/-- The Swift loop spins once per commit posted since the last wait. -/
theorem swift_spins (k : Nat) : spins (permitsSwift k) = k := spins_eq k

/-- The fixed loop doesn't spin. -/
theorem fixed_spins (k : Nat) : spins (permitsFixed k) = 0 := rfl

/-! ## Finding 6: moving a subtree redraws all of it

`Renderer.attach` on a node that is already attached calls `detach`, which
resets its interface state, drops its bitmap and key, and unmounts it. In the
per-node model that is a pass starting from a node that showed nothing. -/

variable {F P K B : Type} [DecidableEq F] [DecidableEq P] [DecidableEq K]

/-- The interface state `detach` leaves. -/
def detached : IState := ⟨false, false, false⟩

/-- **Swift's move**: a moved node in the display range with something to
draw is always drawn again, whether or not its key changed. -/
theorem move_redraws (bmp : K → B) (c : Ctx F P K) (hn : c.new.ist.Valid) (hs : c.synced = true)
    (k : K) :
    let c' := { c with old := { c.old with ist := detached } }
    (nodePass bmp c' (Sh.ofSpec bmp c'.old)).job = some k ↔
      (c.new.ist.display = true ∧ c.new.key = some k) := by
  intro c'
  have ho : c'.old.ist.Valid := by simp [c', detached, IState.Valid]
  have hd : Deps c' := fun _ => .inl hs
  rw [draws_exact bmp c' ho hn hd k]
  simp [c', detached]

/-- **Keeping the shadow on a move** (the fix): the node is drawn only if its
key changed, as for any other node. -/
theorem kept_draws_only_changed (bmp : K → B) (c : Ctx F P K) (ho : c.old.ist.Valid)
    (hn : c.new.ist.Valid) (hd : Deps c) (hdisp : c.old.ist.display = true)
    (hkey : c.old.key = c.new.key) (k : K) :
    (nodePass bmp c (Sh.ofSpec bmp c.old)).job ≠ some k := by
  intro hj
  have := (draws_exact bmp c ho hn hd k).1 hj
  exact this.2.2 ⟨hdisp, hkey ▸ this.2.1⟩

end UltraProofs.Corrected
