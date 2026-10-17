import UltraProofs.Basic

/-!
# Scheduling: dirty flags, the marking walk and pass scheduling

Models `UltraNode.setNeedsSync`, `Renderer.setNeedsPass`, `Renderer.update`
and the sync walk at the start of `Renderer.runPass`, as a transition system
whose steps are the individual atomic operations, so every interleaving of
mutating threads with the serial layout queue is covered.

* `needs n` is `needsSync`, `desc n` is `descendantsNeedSync`.
* A mutation sets `needs n` and starts a walk. A walk at `v` exchanges
  `desc (parent v)` to `true`: if it was already set the walk stops, otherwise
  it moves up. At the root it exchanges `scheduled` (`passScheduled`) and, if
  that was clear, enqueues a pass.
* A host update sets `scheduled` and always enqueues a pass.
* A pass clears `scheduled`, then visits nodes from the root: phase A
  exchanges `needs v` to `false` (the node is synced), phase B exchanges
  `desc v` to `false` and, if it was set, queues the children.

The tree is fixed while these steps run (structural edits are themselves
mutations of the parents involved).
-/

namespace UltraProofs.Scheduling

open UltraProofs

structure State where
  needs : Node → Bool
  desc : Node → Bool
  scheduled : Bool
  /-- `runPass` blocks waiting on the layout queue. -/
  queued : Nat
  /-- Walks in flight, each by the node whose parent it marks next. -/
  walkers : List Node
  running : Bool
  /-- Nodes the running pass's sync walk has still to visit. -/
  pending : List Node
  /-- A node whose `needs` was exchanged and whose `desc` is next. -/
  phaseB : Option Node
  -- Ghost state, for counting.
  /-- Nodes visited by the current (or last) pass. -/
  visited : List Node
  /-- Nodes put on the worklist by the current (or last) pass. -/
  pushed : Nat
  /-- Nodes whose `desc` was set when the pass visited them. -/
  expanded : List Node
  /-- `scheduled` went from `false` to `true` since the last pass start. -/
  epochFlips : Nat
  flips : Nat
  starts : Nat
  updates : Nat
  mutations : Nat

inductive Step (t : Tree) : State → State → Prop
  | mutate (s : State) (n : Node) :
      Step t s { s with needs := upd s.needs n true, walkers := n :: s.walkers
                        mutations := s.mutations + 1 }
  | walkUp (s : State) (v p : Node) (hv : v ∈ s.walkers) (hp : t.parent v = some p) :
      Step t s { s with
        desc := upd s.desc p true
        walkers := if s.desc p then s.walkers.erase v else p :: s.walkers.erase v }
  | walkRoot (s : State) (hv : t.root ∈ s.walkers) :
      Step t s { s with
        scheduled := true
        queued := if s.scheduled then s.queued else s.queued + 1
        walkers := s.walkers.erase t.root
        epochFlips := if s.scheduled then s.epochFlips else s.epochFlips + 1
        flips := if s.scheduled then s.flips else s.flips + 1 }
  | hostUpdate (s : State) :
      Step t s { s with scheduled := true, queued := s.queued + 1, updates := s.updates + 1 }
  | start (s : State) (hr : s.running = false) (hq : 0 < s.queued) :
      Step t s { s with
        queued := s.queued - 1, scheduled := false, running := true
        pending := [t.root], phaseB := none, visited := [], pushed := 1, expanded := []
        epochFlips := 0, starts := s.starts + 1 }
  | visitA (s : State) (v : Node) (rest : List Node)
      (hp : s.pending = v :: rest) (hb : s.phaseB = none) :
      Step t s { s with
        needs := upd s.needs v false, pending := rest, phaseB := some v
        visited := v :: s.visited }
  | visitB (s : State) (v : Node) (hb : s.phaseB = some v) :
      Step t s { s with
        desc := upd s.desc v false, phaseB := none
        pending := (if s.desc v then t.children v else []) ++ s.pending
        pushed := s.pushed + (if s.desc v then (t.children v).length else 0)
        expanded := if s.desc v then v :: s.expanded else s.expanded }
  | finish (s : State) (hr : s.running = true) (hp : s.pending = []) (hb : s.phaseB = none) :
      Step t s { s with running := false }

/-! ## Marked chains -/

/-- `Marked t d a n`: walking up from `n` to its ancestor `a`, every node
above `n` has its `desc` flag set. A pass that visits `a` reaches `n`. -/
inductive Marked (t : Tree) (d : Node → Bool) : Node → Node → Prop
  | here (n : Node) : Marked t d n n
  | up {a n p : Node} : t.parent n = some p → d p = true → Marked t d a p → Marked t d a n

namespace Marked

variable {t : Tree}

theorem mono {d d' : Node → Bool} (h : ∀ x, d x = true → d' x = true) {a n : Node} :
    Marked t d a n → Marked t d' a n := by
  intro hm
  induction hm with
  | here => exact .here _
  | up hp hd _ ih => exact .up hp (h _ hd) ih

theorem anc {d : Node → Bool} {a n : Node} (h : Marked t d a n) : Anc t a n := by
  induction h with
  | here => exact .refl _
  | up hp _ _ ih => exact .up hp ih

theorem trans {d : Node → Bool} {a p n : Node} (h₁ : Marked t d a p) (h₂ : Marked t d p n) :
    Marked t d a n := by
  induction h₂ with
  | here => exact h₁
  | up hp hd _ ih => exact .up hp hd ih

/-- A chain that goes above `n` ends with a step from a child of `a`. -/
theorem top {d : Node → Bool} {a n : Node} (h : Marked t d a n) (hne : a ≠ n) :
    ∃ c, t.parent c = some a ∧ d a = true ∧ Marked t d c n := by
  induction h with
  | here => exact absurd rfl hne
  | @up n p hp hd hm ih =>
    by_cases hap : a = p
    · subst hap; exact ⟨n, hp, hd, .here _⟩
    · obtain ⟨c, hc, hda, hcm⟩ := ih hap
      exact ⟨c, hc, hda, .up hp hd hcm⟩

/-- Clearing `desc v` either leaves a chain intact or cuts it at `v`, in
which case the chain continues from a child of `v` and `desc v` was set. -/
theorem clear {d : Node → Bool} {v a n : Node} (h : Marked t d a n) :
    Marked t (upd d v false) a n ∨
      ∃ c, t.parent c = some v ∧ d v = true ∧ Marked t (upd d v false) c n := by
  induction h with
  | here => exact .inl (.here _)
  | @up n p hp hd hm ih =>
    rcases ih with h' | ⟨c, hc, hdv, hcm⟩
    · by_cases hpv : p = v
      · subst hpv; exact .inr ⟨n, hp, hd, .here _⟩
      · exact .inl (.up hp (by simp [upd, hpv, hd]) h')
    · have h1 := t.parent_rank hc
      have h2 := hcm.anc.rank_le
      have hpv : p ≠ v := by intro e; subst e; omega
      exact .inr ⟨c, hc, hdv, .up hp (by simp [upd, hpv, hd]) hcm⟩

end Marked

/-! ## The invariant -/

/-- Something will carry the change at `n` to a pass: a walk in flight at
`a`, a scheduled pass (when `a` is the root), or the running pass, which will
visit `a`. A node in phase B has already had `needs` exchanged, so it only
covers nodes strictly below it for `needs`. -/
def Witness (t : Tree) (s : State) (a n : Node) (forNeeds : Bool) : Prop :=
  a ∈ s.walkers ∨ (a = t.root ∧ s.scheduled = true) ∨ a ∈ s.pending ∨
    (s.phaseB = some a ∧ (forNeeds = true → a ≠ n))

def Covered (t : Tree) (s : State) (n : Node) (forNeeds : Bool) : Prop :=
  ∃ a, Marked t s.desc a n ∧ Witness t s a n forNeeds

structure Inv (t : Tree) (s : State) : Prop where
  needs : ∀ n, s.needs n = true → Covered t s n true
  desc : ∀ n, s.desc n = true → Covered t s n false
  sched : s.scheduled = true → 0 < s.queued
  idle : s.running = false → s.pending = [] ∧ s.phaseB = none

theorem Witness.mono {t : Tree} {s s' : State} {a n : Node} {b : Bool}
    (h : Witness t s a n b)
    (hw : ∀ x, x ∈ s.walkers → x ∈ s'.walkers)
    (hs : s.scheduled = true → s'.scheduled = true)
    (hp : ∀ x, x ∈ s.pending → x ∈ s'.pending)
    (hb : s'.phaseB = s.phaseB) : Witness t s' a n b := by
  rcases h with (h | ⟨h1, h2⟩ | h | ⟨h1, h2⟩)
  · exact .inl (hw _ h)
  · exact .inr (.inl ⟨h1, hs h2⟩)
  · exact .inr (.inr (.inl (hp _ h)))
  · exact .inr (.inr (.inr ⟨hb ▸ h1, h2⟩))

theorem initial_inv (t : Tree) (s : State)
    (hn : ∀ n, s.needs n = false) (hd : ∀ n, s.desc n = false)
    (hs : s.scheduled = false) (hp : s.pending = []) (hb : s.phaseB = none) : Inv t s where
  needs n h := by simp [hn] at h
  desc n h := by simp [hd] at h
  sched h := by simp [hs] at h
  idle _ := ⟨hp, hb⟩

/-! ### Preservation, step by step -/

section steps

variable {t : Tree}

theorem cover_mutate {s : State} {n₀ n : Node} {b : Bool} (h : Covered t s n b) :
    Covered t { s with needs := upd s.needs n₀ true, walkers := n₀ :: s.walkers
                       mutations := s.mutations + 1 } n b := by
  obtain ⟨a, hm, hw⟩ := h
  exact ⟨a, hm, hw.mono (fun x hx => List.mem_cons_of_mem _ hx) id (fun _ h => h) rfl⟩

theorem cover_walkUp {s : State} {v p n : Node} {b : Bool} (hI : Inv t s)
    (hp : t.parent v = some p) (h : Covered t s n b) :
    Covered t { s with
      desc := upd s.desc p true
      walkers := if s.desc p then s.walkers.erase v else p :: s.walkers.erase v } n b := by
  obtain ⟨a, hm, hw⟩ := h
  have hmono : ∀ x, s.desc x = true → upd s.desc p true x = true := by
    intro x hx; by_cases e : x = p <;> simp [upd, e, hx]
  have hm' := hm.mono hmono
  -- every walker other than `v` survives
  have keep : ∀ x, x ∈ s.walkers → x ≠ v →
      x ∈ (if s.desc p then s.walkers.erase v else p :: s.walkers.erase v) := by
    intro x hx hne
    have := (List.mem_erase_of_ne hne).2 hx
    split
    · exact this
    · exact List.mem_cons_of_mem _ this
  rcases hw with hw | hw | hw | hw
  · by_cases hav : a = v
    · subst hav
      rcases Bool.eq_false_or_eq_true (s.desc p) with hdp | hdp
      · -- the walk stops: `p` was already covered
        obtain ⟨c, hcm, hcw⟩ := hI.desc p hdp
        have hcp := hcm.anc.rank_le
        have hpv := t.parent_rank hp
        have hvn := hm.anc.rank_le
        refine ⟨c, Marked.trans (hcm.mono hmono) (Marked.trans (.up hp (by simp) (.here _)) hm'), ?_⟩
        rcases hcw with h1 | h1 | h1 | ⟨h1, _⟩
        · exact .inl (keep _ h1 (by intro e; subst e; omega))
        · exact .inr (.inl h1)
        · exact .inr (.inr (.inl h1))
        · exact .inr (.inr (.inr ⟨h1, fun _ e => by subst e; omega⟩))
      · -- the walk moves up to `p`
        refine ⟨p, Marked.trans (.up hp (by simp) (.here _)) hm', .inl ?_⟩
        show p ∈ (if s.desc p then _ else _)
        simp [hdp]
    · exact ⟨a, hm', .inl (keep _ hw hav)⟩
  · exact ⟨a, hm', .inr (.inl hw)⟩
  · exact ⟨a, hm', .inr (.inr (.inl hw))⟩
  · exact ⟨a, hm', .inr (.inr (.inr hw))⟩

theorem inv_walkUp {s : State} {v p : Node} (hI : Inv t s)
    (hp : t.parent v = some p) :
    Inv t { s with
      desc := upd s.desc p true
      walkers := if s.desc p then s.walkers.erase v else p :: s.walkers.erase v } where
  needs n h := cover_walkUp hI hp (hI.needs n h)
  desc n h := by
    by_cases e : n = p
    · subst e
      rcases Bool.eq_false_or_eq_true (s.desc n) with hdp | hdp
      · exact cover_walkUp hI hp (hI.desc n hdp)
      · refine ⟨n, .here _, .inl ?_⟩
        show n ∈ (if s.desc n then _ else _)
        simp [hdp]
    · simp [upd, e] at h
      exact cover_walkUp hI hp (hI.desc n h)
  sched := hI.sched
  idle := hI.idle

theorem cover_walkRoot {s : State} {n : Node} {b : Bool} (h : Covered t s n b) :
    Covered t { s with
        scheduled := true
        queued := if s.scheduled then s.queued else s.queued + 1
        walkers := s.walkers.erase t.root
        epochFlips := if s.scheduled then s.epochFlips else s.epochFlips + 1
        flips := if s.scheduled then s.flips else s.flips + 1 } n b := by
  obtain ⟨a, hm, hw⟩ := h
  refine ⟨a, hm, ?_⟩
  rcases hw with hw | hw | hw | hw
  · by_cases e : a = t.root
    · exact .inr (.inl ⟨e, rfl⟩)
    · exact .inl ((List.mem_erase_of_ne e).2 hw)
  · exact .inr (.inl ⟨hw.1, rfl⟩)
  · exact .inr (.inr (.inl hw))
  · exact .inr (.inr (.inr hw))

theorem cover_start {s : State} {n : Node} {b : Bool} (hI : Inv t s) (hr : s.running = false)
    (h : Covered t s n b) :
    Covered t { s with
        queued := s.queued - 1, scheduled := false, running := true
        pending := [t.root], phaseB := none, visited := [], pushed := 1, expanded := []
        epochFlips := 0, starts := s.starts + 1 } n b := by
  obtain ⟨a, hm, hw⟩ := h
  obtain ⟨hp, hb⟩ := hI.idle hr
  refine ⟨a, hm, ?_⟩
  rcases hw with hw | ⟨h1, _⟩ | hw | ⟨hw, _⟩
  · exact .inl hw
  · exact .inr (.inr (.inl (by simp [h1])))
  · simp [hp] at hw
  · simp [hb] at hw

theorem cover_visitA {s : State} {v n : Node} {rest : List Node} {b : Bool}
    (hp : s.pending = v :: rest) (hb : s.phaseB = none) (hnv : b = true → n ≠ v)
    (h : Covered t s n b) :
    Covered t { s with
        needs := upd s.needs v false, pending := rest, phaseB := some v
        visited := v :: s.visited } n b := by
  obtain ⟨a, hm, hw⟩ := h
  refine ⟨a, hm, ?_⟩
  rcases hw with hw | hw | hw | ⟨hw, _⟩
  · exact .inl hw
  · exact .inr (.inl hw)
  · rw [hp] at hw
    rcases List.mem_cons.1 hw with e | e
    · subst e; exact .inr (.inr (.inr ⟨rfl, fun hb' e => hnv hb' e.symm⟩))
    · exact .inr (.inr (.inl e))
  · simp [hb] at hw

theorem cover_visitB {s : State} {v n : Node} {b : Bool} (hb : s.phaseB = some v)
    (hnv : b = false → n ≠ v) (h : Covered t s n b) :
    Covered t { s with
        desc := upd s.desc v false, phaseB := none
        pending := (if s.desc v then t.children v else []) ++ s.pending
        pushed := s.pushed + (if s.desc v then (t.children v).length else 0)
        expanded := if s.desc v then v :: s.expanded else s.expanded } n b := by
  obtain ⟨a, hm, hw⟩ := h
  -- a child `c` of `v` with a chain to `n` is on the new worklist
  have viaChild : ∀ c, t.parent c = some v → s.desc v = true →
      Marked t (upd s.desc v false) c n →
      Covered t { s with
        desc := upd s.desc v false, phaseB := none
        pending := (if s.desc v then t.children v else []) ++ s.pending
        pushed := s.pushed + (if s.desc v then (t.children v).length else 0)
        expanded := if s.desc v then v :: s.expanded else s.expanded } n b := by
    intro c hc hdv hcm
    refine ⟨c, hcm, .inr (.inr (.inl ?_))⟩
    simp [hdv, t.mem_children.2 hc]
  rcases hw with hw | hw | hw | ⟨hw, hstrict⟩
  · rcases hm.clear (v := v) with h' | ⟨c, hc, hdv, hcm⟩
    · exact ⟨a, h', .inl hw⟩
    · exact viaChild c hc hdv hcm
  · rcases hm.clear (v := v) with h' | ⟨c, hc, hdv, hcm⟩
    · exact ⟨a, h', .inr (.inl hw)⟩
    · exact viaChild c hc hdv hcm
  · rcases hm.clear (v := v) with h' | ⟨c, hc, hdv, hcm⟩
    · exact ⟨a, h', .inr (.inr (.inl (List.mem_append_right _ hw)))⟩
    · exact viaChild c hc hdv hcm
  · -- the pass is at `a = v`: it reaches `n` through a child of `v`
    have hva : a = v := (Option.some.inj (hb ▸ hw)).symm
    rw [hva] at hm hstrict
    have hvn : v ≠ n := by
      cases b
      · exact Ne.symm (hnv rfl)
      · exact hstrict rfl
    obtain ⟨c, hc, hdv, hcm⟩ := hm.top hvn
    rcases hcm.clear (v := v) with h' | ⟨c', hc', _, hcm'⟩
    · exact viaChild c hc hdv h'
    · exact viaChild c' hc' hdv hcm'

end steps

theorem Inv.step {t : Tree} {s s' : State} (hI : Inv t s) (h : Step t s s') : Inv t s' := by
  cases h with
  | mutate n₀ =>
    refine ⟨?_, ?_, hI.sched, hI.idle⟩
    · intro n hn
      by_cases e : n = n₀
      · subst e; exact ⟨n, .here _, .inl (List.mem_cons_self ..)⟩
      · simp [upd, e] at hn; exact cover_mutate (hI.needs n hn)
    · intro n hn; exact cover_mutate (hI.desc n hn)
  | walkUp v p _ hp => exact inv_walkUp hI hp
  | walkRoot hv =>
    refine ⟨fun n hn => cover_walkRoot (hI.needs n hn), fun n hn => cover_walkRoot (hI.desc n hn),
      ?_, hI.idle⟩
    intro _
    cases e : s.scheduled
    · simp
    · simp [hI.sched e]
  | hostUpdate =>
    refine ⟨?_, ?_, fun _ => Nat.succ_pos _, hI.idle⟩
    · intro n hn
      obtain ⟨a, hm, hw⟩ := hI.needs n hn
      exact ⟨a, hm, hw.mono (fun _ h => h) (fun _ => rfl) (fun _ h => h) rfl⟩
    · intro n hn
      obtain ⟨a, hm, hw⟩ := hI.desc n hn
      exact ⟨a, hm, hw.mono (fun _ h => h) (fun _ => rfl) (fun _ h => h) rfl⟩
  | start hr hq =>
    refine ⟨fun n hn => cover_start hI hr (hI.needs n hn),
      fun n hn => cover_start hI hr (hI.desc n hn), fun h => by simp at h, fun h => by simp at h⟩
  | visitA v rest hp hb =>
    have hrun : s.running = true := by
      cases e : s.running
      · have := (hI.idle e).1; rw [hp] at this; cases this
      · rfl
    refine ⟨?_, ?_, hI.sched, fun h => by simp [hrun] at h⟩
    · intro n hn
      have hnv : n ≠ v := by intro e; subst e; simp at hn
      simp [upd, hnv] at hn
      exact cover_visitA hp hb (fun _ => hnv) (hI.needs n hn)
    · intro n hn
      exact cover_visitA hp hb (fun h => by cases h) (hI.desc n hn)
  | visitB v hb =>
    have hrun : s.running = true := by
      cases e : s.running
      · have := (hI.idle e).2; rw [hb] at this; cases this
      · rfl
    refine ⟨?_, ?_, hI.sched, fun h => by simp [hrun] at h⟩
    · intro n hn
      exact cover_visitB hb (fun h => by cases h) (hI.needs n hn)
    · intro n hn
      have hnv : n ≠ v := by intro e; subst e; simp at hn
      simp [upd, hnv] at hn
      exact cover_visitB hb (fun _ => hnv) (hI.desc n hn)
  | finish hr hp hb =>
    refine ⟨?_, ?_, hI.sched, fun _ => ⟨hp, hb⟩⟩
    · intro n hn
      obtain ⟨a, hm, hw⟩ := hI.needs n hn
      exact ⟨a, hm, hw.mono (fun _ h => h) id (fun _ h => h) rfl⟩
    · intro n hn
      obtain ⟨a, hm, hw⟩ := hI.desc n hn
      exact ⟨a, hm, hw.mono (fun _ h => h) id (fun _ h => h) rfl⟩

/-! ## No lost updates

With no walk in flight, no pass running and none scheduled, every flag is
clear: every mutation was synced by some pass. -/

theorem quiescent_clean {t : Tree} {s : State} (hI : Inv t s) (hw : s.walkers = [])
    (hr : s.running = false) (hs : s.scheduled = false) :
    ∀ n, s.needs n = false ∧ s.desc n = false := by
  obtain ⟨hp, hb⟩ := hI.idle hr
  have none : ∀ a n b, ¬ Witness t s a n b := by
    rintro a n b (h | ⟨_, h⟩ | h | ⟨h, _⟩)
    · simp [hw] at h
    · simp [hs] at h
    · simp [hp] at h
    · simp [hb] at h
  intro n
  constructor
  · cases e : s.needs n
    · rfl
    · obtain ⟨a, _, hw'⟩ := hI.needs n e; exact absurd hw' (none _ _ _)
  · cases e : s.desc n
    · rfl
    · obtain ⟨a, _, hw'⟩ := hI.desc n e; exact absurd hw' (none _ _ _)

/-- Progress: once the walks are done, a pending change always has a pass
running or queued for it. -/
theorem progress {t : Tree} {s : State} (hI : Inv t s) (hw : s.walkers = []) {n : Node}
    (hn : s.needs n = true ∨ s.desc n = true) : s.running = true ∨ 0 < s.queued := by
  cases hr : s.running
  · cases hs : s.scheduled
    · have := quiescent_clean hI hw hr hs n
      rcases hn with h | h <;> simp_all
    · exact .inr (hI.sched hs)
  · exact .inl rfl

/-! ## Liveness: at most one more pass

After the last mutation's walk has finished, the pass that starts next
(after the one running, if any) leaves every flag clear when it ends. So the
system is idle after at most two passes. -/

/-- A run with no client activity: no walk in flight, no host update. -/
inductive QuietPath (t : Tree) : State → State → Prop
  | refl (s : State) : QuietPath t s s
  | step {s₁ s₂ s₃ : State} : QuietPath t s₁ s₂ → Step t s₂ s₃ →
      s₃.walkers = [] → s₃.updates = s₂.updates → QuietPath t s₁ s₃

theorem QuietPath.props {t : Tree} {s s' : State} (h : QuietPath t s s') (hI : Inv t s)
    (hw : s.walkers = []) :
    Inv t s' ∧ s'.walkers = [] ∧ s.starts ≤ s'.starts ∧
      (s.starts < s'.starts → s'.scheduled = false) := by
  induction h with
  | refl => exact ⟨hI, hw, Nat.le_refl _, fun h => absurd h (Nat.lt_irrefl _)⟩
  | step _ hstep hw₃ hu ih =>
    obtain ⟨hI₂, hw₂, hle, hsch⟩ := ih
    refine ⟨hI₂.step hstep, hw₃, ?_⟩
    cases hstep with
    | mutate n => simp at hw₃
    | walkUp v p hv => simp [hw₂] at hv
    | walkRoot hv => simp [hw₂] at hv
    | hostUpdate => simp at hu
    | start => exact ⟨by simp; omega, fun _ => rfl⟩
    | visitA => exact ⟨hle, hsch⟩
    | visitB => exact ⟨hle, hsch⟩
    | finish => exact ⟨hle, hsch⟩

theorem settles {t : Tree} {s s' : State} (hI : Inv t s) (hw : s.walkers = [])
    (h : QuietPath t s s') (hstart : s.starts < s'.starts) (hr : s'.running = false) :
    ∀ n, s'.needs n = false ∧ s'.desc n = false := by
  obtain ⟨hI', hw', _, hsch⟩ := h.props hI hw
  exact quiescent_clean hI' hw' hr (hsch hstart)

/-! ## Each node is synced at most once per pass, and what the walk costs -/

structure PassInv (t : Tree) (s : State) : Prop where
  nodup : (s.pending ++ s.visited).Nodup
  phaseB_visited : ∀ v, s.phaseB = some v → v ∈ s.visited
  parent_done : ∀ x, x ∈ s.pending ++ s.visited →
    x = t.root ∨ ∃ p, t.parent x = some p ∧ p ∈ s.visited ∧ s.phaseB ≠ some p
  count : s.pending.length + s.visited.length = s.pushed
  pushed_eq : s.pushed = 1 + sumBy (fun p => (t.children p).length) s.expanded

theorem passInv_start {t : Tree} (s : State) :
    PassInv t { s with
        queued := s.queued - 1, scheduled := false, running := true
        pending := [t.root], phaseB := none, visited := [], pushed := 1, expanded := []
        epochFlips := 0, starts := s.starts + 1 } where
  nodup := by simp
  phaseB_visited := by simp
  parent_done := by simp
  count := by simp
  pushed_eq := by simp

theorem PassInv.step {t : Tree} {s s' : State} (hP : PassInv t s) (h : Step t s s') :
    PassInv t s' := by
  cases h with
  | mutate => exact ⟨hP.nodup, hP.phaseB_visited, hP.parent_done, hP.count, hP.pushed_eq⟩
  | walkUp => exact ⟨hP.nodup, hP.phaseB_visited, hP.parent_done, hP.count, hP.pushed_eq⟩
  | walkRoot => exact ⟨hP.nodup, hP.phaseB_visited, hP.parent_done, hP.count, hP.pushed_eq⟩
  | hostUpdate => exact ⟨hP.nodup, hP.phaseB_visited, hP.parent_done, hP.count, hP.pushed_eq⟩
  | start => exact passInv_start s
  | finish => exact ⟨hP.nodup, hP.phaseB_visited, hP.parent_done, hP.count, hP.pushed_eq⟩
  | visitA v rest hp hb =>
    have hnd := hP.nodup
    rw [hp] at hnd
    have hvis : v ∉ s.visited := by
      intro hv
      have := (List.nodup_append.1 hnd).2.2 v (List.mem_cons_self ..) v hv
      exact this rfl
    refine ⟨?_, ?_, ?_, ?_, hP.pushed_eq⟩
    · show (rest ++ v :: s.visited).Nodup
      exact (List.perm_middle.nodup_iff).2 hnd
    · intro w hw; cases hw; exact List.mem_cons_self ..
    · intro x hx
      have hx' : x ∈ s.pending ++ s.visited := by
        rw [hp]
        simp only [List.mem_append, List.mem_cons] at hx ⊢
        rcases hx with h | h | h
        · exact .inl (.inr h)
        · exact .inl (.inl h)
        · exact .inr h
      rcases hP.parent_done x hx' with h | ⟨p, hpx, hpv, _⟩
      · exact .inl h
      · refine .inr ⟨p, hpx, List.mem_cons_of_mem _ hpv, ?_⟩
        intro e; cases e; exact hvis hpv
    · have := hP.count; rw [hp] at this; simp at this ⊢; omega
  | visitB v hb =>
    have hvv := hP.phaseB_visited v hb
    -- children of `v` are not on the worklist or visited yet
    have fresh : ∀ c, c ∈ t.children v → c ∉ s.pending ++ s.visited := by
      intro c hc hmem
      have hcp := t.mem_children.1 hc
      rcases hP.parent_done c hmem with h | ⟨p, hpx, _, hne⟩
      · subst h; rw [t.root_parent] at hcp; cases hcp
      · rw [hcp] at hpx; cases hpx; exact hne hb
    refine ⟨?_, ?_, ?_, ?_, ?_⟩
    · show ((if s.desc v then t.children v else []) ++ s.pending ++ s.visited).Nodup
      split
      · rw [List.append_assoc]
        refine List.nodup_append.2 ⟨t.children_nodup v, hP.nodup, ?_⟩
        intro a ha b hb' e; subst e; exact fresh a ha hb'
      · simpa using hP.nodup
    · intro w hw; cases hw
    · intro x hx
      have hx' : x ∈ (if s.desc v then t.children v else []) ∨ x ∈ s.pending ++ s.visited := by
        simp only [List.mem_append] at hx ⊢
        rcases hx with (h | h) | h
        · exact .inl h
        · exact .inr (.inl h)
        · exact .inr (.inr h)
      rcases hx' with hc | hold
      · split at hc
        · exact .inr ⟨v, t.mem_children.1 hc, hvv, by simp⟩
        · simp at hc
      · rcases hP.parent_done x hold with h | ⟨p, hpx, hpv, _⟩
        · exact .inl h
        · exact .inr ⟨p, hpx, hpv, by simp⟩
    · show ((if s.desc v then t.children v else []) ++ s.pending).length + s.visited.length =
        s.pushed + (if s.desc v then (t.children v).length else 0)
      have := hP.count
      split <;> simp <;> omega
    · show s.pushed + (if s.desc v then (t.children v).length else 0) =
        1 + sumBy (fun p => (t.children p).length) (if s.desc v then v :: s.expanded else s.expanded)
      have := hP.pushed_eq
      split <;> simp <;> omega

/-- The node a pass visits next has not been visited in this pass. -/
theorem visit_once {t : Tree} {s : State} {v : Node} {rest : List Node} (hP : PassInv t s)
    (hp : s.pending = v :: rest) : v ∉ s.visited := by
  intro hv
  have hnd := hP.nodup
  rw [hp] at hnd
  exact (List.nodup_append.1 hnd).2.2 v (List.mem_cons_self ..) v hv rfl

/-- The sync walk's cost: when the walk is done it has visited the root plus
every child of every node whose `descendantsNeedSync` was set, all of them,
whether or not they changed. -/
theorem sync_cost {t : Tree} {s : State} (hP : PassInv t s) (hp : s.pending = []) :
    s.visited.length = 1 + sumBy (fun p => (t.children p).length) s.expanded := by
  have := hP.count; rw [hp, hP.pushed_eq] at this; simpa using this

/-! ## Coalescing

`scheduled` is cleared only when a pass starts, so between two pass starts
it goes from `false` to `true` at most once, however many mutations there
are. Every pass is paid for by one such flip or by a host update. -/

structure Count (q₀ : Nat) (s : State) : Prop where
  epoch : s.epochFlips ≤ 1
  epoch_sched : s.epochFlips = 1 → s.scheduled = true
  queue : s.queued + s.starts = q₀ + s.flips + s.updates

theorem Count.step {t : Tree} {q₀ : Nat} {s s' : State} (hC : Count q₀ s) (h : Step t s s') :
    Count q₀ s' := by
  have ⟨he, hes, hq⟩ := hC
  cases h with
  | mutate => exact ⟨he, hes, hq⟩
  | walkUp => exact ⟨he, hes, hq⟩
  | walkRoot =>
    cases hs : s.scheduled
    · have : s.epochFlips = 0 := by
        cases Nat.lt_or_ge s.epochFlips 1 with
        | inl h => omega
        | inr h => have := hes (by omega); simp [hs] at this
      refine ⟨by simp; omega, fun _ => rfl, by simp; omega⟩
    · exact ⟨by simp; omega, fun _ => rfl, by simp; omega⟩
  | hostUpdate => exact ⟨he, fun _ => rfl, by simp; omega⟩
  | start hr hq' => exact ⟨by simp, by simp, by simp; omega⟩
  | visitA => exact ⟨he, hes, hq⟩
  | visitB => exact ⟨he, hes, hq⟩
  | finish => exact ⟨he, hes, hq⟩

/-- Every pass that started was paid for by a flip of `scheduled` or a host
update. -/
theorem passes_le {q₀ : Nat} {s : State} (hC : Count q₀ s) :
    s.starts ≤ q₀ + s.flips + s.updates := by
  have := hC.queue; omega

/-- A run with no pass start. -/
inductive Epoch (t : Tree) : State → State → Prop
  | refl (s : State) : Epoch t s s
  | step {s₁ s₂ s₃ : State} : Epoch t s₁ s₂ → Step t s₂ s₃ → s₃.starts = s₂.starts → Epoch t s₁ s₃

/-- Coalescing: within one epoch (no pass starts) mutations enqueue at most
one pass, whatever their number. -/
theorem epoch_enqueues_at_most_one {t : Tree} {q₀ : Nat} {s s' : State} (hC : Count q₀ s)
    (h : Epoch t s s') : Count q₀ s' ∧ s'.flips ≤ s.flips + 1 ∧
      s'.flips + s.epochFlips = s.flips + s'.epochFlips := by
  induction h with
  | refl => exact ⟨hC, by omega, by omega⟩
  | step _ hstep hst ih =>
    obtain ⟨hC₂, _, heq⟩ := ih
    have hC₃ := hC₂.step hstep
    refine ⟨hC₃, ?_, ?_⟩
    · have := hC₃.epoch
      cases hstep with
      | start => simp at hst
      | walkRoot => split at * <;> simp_all <;> omega
      | _ => simp_all <;> omega
    · cases hstep with
      | start => simp at hst
      | walkRoot => split at * <;> simp_all <;> omega
      | _ => simp_all

end UltraProofs.Scheduling
