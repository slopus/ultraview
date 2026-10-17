/-!
# One live host per prepared root

Models how `NodeRow` rows hand a prepared node tree between row views
(NodeRow.swift). A preparation (`PreparedNodeContent`) owns one root, made
when it is prepared, and remembers its host weakly and the view that last
checked it out. A row view keeps a host it shows and one it is preparing to
show. `checkout` reuses a live host, taking it from the view that had it
(which keeps a snapshot in its place), and makes a new host only when none is
alive. A host is alive while a view keeps it; when the last view lets go it
is deallocated on the main thread (its `deinit` is main-actor isolated) and
detaches its renderer. A detached root's bitmaps are purged later on the
layout queue only if no renderer has attached to it since
(`Renderer.detach`), and the list's preparation store drops a preparation
only while it has no live host (`UltraListView.sweepPreparations`).

Hosts are named by an id and the content (root) they render; views by a
number. Every operation is one main-thread turn followed by the
deallocations it causes (`collect`). That a host lives exactly while a view's
`displayedHost` or `pendingHost` keeps it (the superview goes with the slot,
and the commit and reveal closures hold it weakly) is the model's reading of
the Swift's references, not something proved here.

* `inv_run`: every sequence of `start`, `reveal` and `free` keeps `Inv`.
* `start_reuses`, `start_creates`: a checkout takes the live host from the
  view that had it, and makes a host only when none is alive.
* `start_attaches_unhosted`: `checkout` creates a host, and so a renderer,
  only for a root with no renderer attached, so the precondition at
  Renderer.swift:94 ("a node can be hosted only once at a time") never fails.
* `one_host`, `one_slot`: at every step a root has at most one live host,
  and a live host is kept by exactly one view.
* `hosted_has_renderer`: a root with a live host has a renderer attached, so
  making a second host for it, as a checkout that ignored the live host
  would, trips that precondition.
* `purge_unhosted`, `weak_iff`: a purge, which needs the root to have no
  renderer, and a store sweep, which needs `hasLiveHost` false, never touch a
  root that is hosted. `checkout_never_trips`, `purge_never_frees_hosted`,
  `sweep_never_drops_hosted` and `one_host_always` state these after every
  sequence of operations from no views. The purge's check runs at some later
  step, and the invariant holds at all of them.
-/

namespace UltraProofs.ListHosts

open Classical

structure Host where
  id : Nat
  content : Nat
deriving DecidableEq

/-- The views' shown and pending hosts, each preparation's weak host and
owner, each root's attached renderer (by host id), and the next host id. -/
structure S where
  displayed : Nat → Option Host
  pending : Nat → Option Host
  hostOf : Nat → Option Nat
  owner : Nat → Option Nat
  renderer : Nat → Option Nat
  next : Nat

def S.empty : S := ⟨fun _ => none, fun _ => none, fun _ => none, fun _ => none, fun _ => none, 0⟩

/-- View `v` keeps host `h`. -/
def S.In (s : S) (v : Nat) (h : Host) : Prop := s.displayed v = some h ∨ s.pending v = some h

/-- A host is alive while some view keeps it. -/
def S.Alive (s : S) (h : Host) : Prop := ∃ v, s.In v h

def upd {α : Type} (f : Nat → α) (k : Nat) (a : α) : Nat → α := fun k' => if k' = k then a else f k'

@[simp] theorem upd_same {α : Type} (f : Nat → α) (k : Nat) (a : α) : upd f k a k = a := by simp [upd]
theorem upd_other {α : Type} (f : Nat → α) {k k' : Nat} (a : α) (h : k' ≠ k) : upd f k a k' = f k' := by
  simp [upd, h]

/-- Reading the weak `PreparedNodeContent.host`. -/
noncomputable def S.weak (s : S) (c : Nat) : Option Host :=
  match s.hostOf c with
  | some id => if s.Alive ⟨id, c⟩ then some ⟨id, c⟩ else none
  | none => none

/-- Deallocations: every host no view keeps runs `deinit`, whose
`renderer.detach()` clears the root's renderer if it is that host's. -/
noncomputable def S.collect (s : S) : S :=
  { s with renderer := fun c => match s.renderer c with
      | some id => if s.Alive ⟨id, c⟩ then some id else none
      | none => none }

/-- `NodeRowView.release(_:)`: the view that had `h` lets it go (and shows a
snapshot in its place). -/
def S.release (s : S) (o : Nat) (h : Host) : S :=
  { s with displayed := upd s.displayed o (if s.displayed o = some h then none else s.displayed o),
           pending := upd s.pending o (if s.pending o = some h then none else s.pending o) }

/-- `NodeRowView.start(_:)` with `PreparedNodeContent.checkout(owner:)`: view
`v`, preparing nothing and not showing root `c`, checks out `c`'s host. -/
noncomputable def S.start (s : S) (v c : Nat) : S :=
  if s.pending v = none ∧ (s.displayed v).map (·.content) ≠ some c then
    match s.weak c with
    | some h =>
      let s1 := match s.owner c with
        | some o => if o = v then s else s.release o h
        | none => s
      { s1 with owner := upd s1.owner c (some v), pending := upd s1.pending v (some h) }.collect
    | none =>
      { s with owner := upd s.owner c (some v), pending := upd s.pending v (some ⟨s.next, c⟩),
               hostOf := upd s.hostOf c (some s.next), renderer := upd s.renderer c (some s.next),
               next := s.next + 1 }.collect
  else s

/-- `showPreparedHost(_:)`: the pending host replaces the shown one, which is
let go. -/
noncomputable def S.reveal (s : S) (v : Nat) : S :=
  match s.pending v with
  | some h => { s with displayed := upd s.displayed v (some h), pending := upd s.pending v none }.collect
  | none => s

/-- A row view is deallocated: it lets its hosts go, and weak `owner`
references to it read `nil`. -/
noncomputable def S.free (s : S) (v : Nat) : S :=
  { s with displayed := upd s.displayed v none, pending := upd s.pending v none,
           owner := fun c => if s.owner c = some v then none else s.owner c }.collect

/-- The invariant before deallocations run. -/
structure Pre (s : S) : Prop where
  twoSlots : ∀ v h, ¬(s.displayed v = some h ∧ s.pending v = some h)
  weak : ∀ h, s.Alive h → s.hostOf h.content = some h.id
  owner : ∀ v h, s.In v h → s.owner h.content = some v
  rendOf : ∀ h, s.Alive h → s.renderer h.content = some h.id
  fresh : ∀ h, s.Alive h → h.id < s.next

structure Inv (s : S) : Prop extends Pre s where
  rendAlive : ∀ c id, s.renderer c = some id → s.Alive ⟨id, c⟩

theorem collect_alive (s : S) (h : Host) : s.collect.Alive h ↔ s.Alive h := Iff.rfl

theorem collect_inv {s : S} (h : Pre s) : Inv s.collect := by
  refine ⟨⟨h.twoSlots, h.weak, h.owner, fun x hx => ?_, h.fresh⟩, fun c id hc => ?_⟩
  · simp only [S.collect, h.rendOf x hx]
    split
    · rfl
    · next hn => exact absurd hx hn
  · simp only [S.collect] at hc
    split at hc
    · split at hc
      · cases hc; assumption
      · cases hc
    · cases hc

theorem inv_empty : Inv S.empty :=
  ⟨⟨by simp [S.empty], fun _ ⟨_, h⟩ => by simp [S.In, S.empty] at h,
    fun _ _ h => by simp [S.In, S.empty] at h, fun _ ⟨_, h⟩ => by simp [S.In, S.empty] at h,
    fun _ ⟨_, h⟩ => by simp [S.In, S.empty] at h⟩, fun _ _ h => by simp [S.empty] at h⟩

/-- **A root has at most one live host.** -/
theorem one_host {s : S} (hs : Inv s) {h h' : Host} (ha : s.Alive h) (ha' : s.Alive h')
    (hc : h.content = h'.content) : h = h' := by
  have e := hs.weak h ha
  have e' := hs.weak h' ha'
  rw [hc, e'] at e
  cases h; cases h'; simp_all

/-- **A live host is kept by exactly one view.** -/
theorem one_slot {s : S} (hs : Inv s) {v w : Nat} {h : Host} (hv : s.In v h) (hw : s.In w h) : v = w := by
  have := hs.owner v h hv
  rw [hs.owner w h hw] at this
  cases this; rfl

/-- **The weak host is the live host**: `hasLiveHost` reads true exactly when
the root has a live host. -/
theorem weak_iff {s : S} (hs : Inv s) (c : Nat) (h : Host) : s.weak c = some h ↔ s.Alive h ∧ h.content = c := by
  constructor
  · intro hw
    simp only [S.weak] at hw
    split at hw
    · split at hw
      · cases hw; exact ⟨by assumption, rfl⟩
      · cases hw
    · cases hw
  · rintro ⟨ha, rfl⟩
    simp only [S.weak, hs.weak h ha]
    split
    · rfl
    · next hn => exact absurd ha hn

/-- **A hosted root has a renderer attached**, so a second host for it would
trip Renderer.swift:94. -/
theorem hosted_has_renderer {s : S} (hs : Inv s) {h : Host} (ha : s.Alive h) :
    s.renderer h.content ≠ none := by
  rw [hs.rendOf h ha]; simp

/-- **`checkout` creates a renderer only for an unhosted root**: when the weak
host reads `nil`, no renderer is attached, so the precondition holds. -/
theorem start_attaches_unhosted {s : S} (hs : Inv s) (c : Nat) (hw : s.weak c = none) :
    s.renderer c = none := by
  cases e : s.renderer c with
  | none => rfl
  | some id =>
    have ha := hs.rendAlive c id e
    have := (weak_iff hs c ⟨id, c⟩).mpr ⟨ha, rfl⟩
    rw [hw] at this; cases this

/-- **A purge never frees a hosted root.** It runs only when no renderer is
attached, and then no host of the root is alive. -/
theorem purge_unhosted {s : S} (hs : Inv s) (c : Nat) (hr : s.renderer c = none) :
    ∀ h, s.Alive h → h.content ≠ c := by
  intro h ha e
  have := hs.rendOf h ha
  rw [e, hr] at this; cases this

theorem start_inv {s : S} (hs : Inv s) (v c : Nat) : Inv (s.start v c) := by
  unfold S.start
  split
  · rename_i hg
    obtain ⟨hp, hd⟩ := hg
    cases hwk : s.weak c with
    | none =>
      apply collect_inv
      -- No live host of `c`: the new host is the only one.
      have noC : ∀ x, s.Alive x → x.content ≠ c := fun x hx e => by
        have := (weak_iff hs c x).mpr ⟨hx, e⟩; rw [hwk] at this; cases this
      have inS : ∀ w x, (upd s.pending v (some ⟨s.next, c⟩) w = some x ∨ s.displayed w = some x) →
          (s.In w x ∨ (w = v ∧ x = ⟨s.next, c⟩)) := by
        intro w x hx
        by_cases e : w = v
        · subst e; simp only [upd_same, Option.some.injEq] at hx
          rcases hx with hx | hx
          · exact Or.inr ⟨rfl, hx.symm⟩
          · exact Or.inl (Or.inl hx)
        · rw [upd_other _ _ e] at hx
          exact Or.inl (hx.elim Or.inr Or.inl)
      refine ⟨fun w x ⟨h1, h2⟩ => ?_, fun x ⟨w, hx⟩ => ?_, fun w x hx => ?_, fun x ⟨w, hx⟩ => ?_,
        fun x ⟨w, hx⟩ => ?_⟩
      · by_cases e : w = v
        · subst e; simp only [upd_same, Option.some.injEq] at h2; subst h2
          have h1' : s.displayed w = some ⟨s.next, c⟩ := h1
          exact hd (by simp [h1'])
        · simp only [upd_other _ _ e] at h2; exact hs.twoSlots w x ⟨h1, h2⟩
      · rcases inS w x (hx.elim Or.inr Or.inl) with hx | ⟨_, rfl⟩
        · simp only [upd_other _ _ (noC x ⟨w, hx⟩)]; exact hs.weak x ⟨w, hx⟩
        · simp
      · rcases inS w x (hx.elim Or.inr Or.inl) with hx | ⟨rfl, rfl⟩
        · simp only [upd_other _ _ (noC x ⟨w, hx⟩)]; exact hs.owner w x hx
        · simp
      · rcases inS w x (hx.elim Or.inr Or.inl) with hx | ⟨_, rfl⟩
        · simp only [upd_other _ _ (noC x ⟨w, hx⟩)]; exact hs.rendOf x ⟨w, hx⟩
        · simp
      · rcases inS w x (hx.elim Or.inr Or.inl) with hx | ⟨_, rfl⟩
        · have := hs.fresh x ⟨w, hx⟩; simp only; omega
        · simp
    | some h =>
      obtain ⟨⟨u, hu⟩, hc⟩ := (weak_iff hs c h).mp hwk
      subst hc
      have ho := hs.owner u h hu
      -- `h` is kept only by its owner `u`, which is not `v`.
      have huv : u ≠ v := by
        rintro rfl
        rcases hu with hu | hu
        · exact hd (by simp [hu])
        · rw [hp] at hu; cases hu
      have only : ∀ w, s.In w h → w = u := fun w hw => one_slot hs hw hu
      simp only [ho, huv, ite_false]
      apply collect_inv
      generalize hr : s.release u h = r
      have rd : ∀ w, r.displayed w = if w = u ∧ s.displayed w = some h then none else s.displayed w := by
        intro w; rw [← hr]; simp only [S.release, upd]; by_cases e : w = u <;> simp [e]
      have rp : ∀ w, r.pending w = if w = u ∧ s.pending w = some h then none else s.pending w := by
        intro w; rw [← hr]; simp only [S.release, upd]; by_cases e : w = u <;> simp [e]
      have rs : r.hostOf = s.hostOf ∧ r.owner = s.owner ∧ r.renderer = s.renderer ∧ r.next = s.next := by
        rw [← hr]; exact ⟨rfl, rfl, rfl, rfl⟩
      -- Who keeps what afterwards: `h` only in `v`'s pending slot, everything else as before.
      have inS : ∀ w x, (upd r.pending v (some h) w = some x ∨ r.displayed w = some x) →
          (x ≠ h ∧ s.In w x) ∨ (w = v ∧ x = h) := by
        intro w x hx
        by_cases e : w = v
        · subst e
          simp only [upd_same, Option.some.injEq, rd, huv.symm, false_and, ite_false] at hx
          rcases hx with hx | hx
          · exact Or.inr ⟨rfl, hx.symm⟩
          · left; refine ⟨fun hxh => ?_, Or.inl hx⟩
            subst hxh; exact hd (by simp [hx])
        · rw [upd_other _ _ e, rp, rd] at hx
          left
          by_cases hxh : x = h
          · subst hxh
            exfalso
            rcases hx with hx | hx
            · split at hx
              · cases hx
              · rename_i hn; exact hn ⟨only w (Or.inr hx), hx⟩
            · split at hx
              · cases hx
              · rename_i hn; exact hn ⟨only w (Or.inl hx), hx⟩
          · refine ⟨hxh, ?_⟩
            rcases hx with hx | hx
            · split at hx
              · cases hx
              · exact Or.inr hx
            · split at hx
              · cases hx
              · exact Or.inl hx
      have oc : ∀ x w, x ≠ h → s.In w x → x.content ≠ h.content := fun x w hxh hx e =>
        hxh (one_host hs ⟨w, hx⟩ ⟨u, hu⟩ e)
      refine ⟨fun w x ⟨h1, h2⟩ => ?_, fun x ⟨w, hx⟩ => ?_, fun w x hx => ?_, fun x ⟨w, hx⟩ => ?_,
        fun x ⟨w, hx⟩ => ?_⟩
      · by_cases e : w = v
        · subst e; simp only [upd_same, Option.some.injEq] at h2; subst h2
          simp only [rd, huv.symm, false_and, ite_false] at h1
          exact hd (by simp [h1])
        · simp only [upd_other _ _ e] at h2
          rw [rd] at h1; rw [rp] at h2
          split at h1
          · cases h1
          · split at h2
            · cases h2
            · exact hs.twoSlots w x ⟨h1, h2⟩
      · simp only [rs.1]
        rcases inS w x (hx.elim Or.inr Or.inl) with ⟨_, hx⟩ | ⟨_, hxh⟩
        · exact hs.weak x ⟨w, hx⟩
        · rw [hxh]; exact hs.weak h ⟨u, hu⟩
      · rcases inS w x (hx.elim Or.inr Or.inl) with ⟨hxh, hx⟩ | ⟨rfl, rfl⟩
        · simp only [upd_other _ _ (oc x w hxh hx), rs.2.1]; exact hs.owner w x hx
        · simp
      · simp only [rs.2.2.1]
        rcases inS w x (hx.elim Or.inr Or.inl) with ⟨_, hx⟩ | ⟨_, hxh⟩
        · exact hs.rendOf x ⟨w, hx⟩
        · rw [hxh]; exact hs.rendOf h ⟨u, hu⟩
      · simp only [rs.2.2.2]
        rcases inS w x (hx.elim Or.inr Or.inl) with ⟨_, hx⟩ | ⟨_, hxh⟩
        · exact hs.fresh x ⟨w, hx⟩
        · rw [hxh]; exact hs.fresh h ⟨u, hu⟩
  · exact hs

theorem reveal_inv {s : S} (hs : Inv s) (v : Nat) : Inv (s.reveal v) := by
  unfold S.reveal
  cases hp : s.pending v with
  | none => exact hs
  | some h =>
    apply collect_inv
    have inS : ∀ w x, (upd s.displayed v (some h) w = some x ∨ upd s.pending v none w = some x) →
        s.In w x := by
      intro w x hx
      by_cases e : w = v
      · subst e; simp only [upd_same, Option.some.injEq, reduceCtorEq, or_false] at hx
        subst hx; exact Or.inr hp
      · simp only [upd_other _ _ e] at hx; exact hx
    refine ⟨fun w x ⟨h1, h2⟩ => ?_, fun x ⟨w, hx⟩ => hs.weak x ⟨w, inS w x hx⟩,
      fun w x hx => hs.owner w x (inS w x hx), fun x ⟨w, hx⟩ => hs.rendOf x ⟨w, inS w x hx⟩,
      fun x ⟨w, hx⟩ => hs.fresh x ⟨w, inS w x hx⟩⟩
    by_cases e : w = v
    · subst e; simp at h2
    · simp only [upd_other _ _ e] at h1 h2; exact hs.twoSlots w x ⟨h1, h2⟩

theorem free_inv {s : S} (hs : Inv s) (v : Nat) : Inv (s.free v) := by
  unfold S.free
  apply collect_inv
  have inS : ∀ w x, (upd s.displayed v none w = some x ∨ upd s.pending v none w = some x) →
      w ≠ v ∧ s.In w x := by
    intro w x hx
    by_cases e : w = v
    · subst e; simp at hx
    · simp only [upd_other _ _ e] at hx; exact ⟨e, hx⟩
  refine ⟨fun w x ⟨h1, h2⟩ => ?_, fun x ⟨w, hx⟩ => hs.weak x ⟨w, (inS w x hx).2⟩, fun w x hx => ?_,
    fun x ⟨w, hx⟩ => hs.rendOf x ⟨w, (inS w x hx).2⟩, fun x ⟨w, hx⟩ => hs.fresh x ⟨w, (inS w x hx).2⟩⟩
  · by_cases e : w = v
    · subst e; simp at h1
    · simp only [upd_other _ _ e] at h1 h2; exact hs.twoSlots w x ⟨h1, h2⟩
  · obtain ⟨e, hx⟩ := inS w x hx
    have := hs.owner w x hx
    simp only [this, Option.some.injEq, e, ite_false]

inductive Op
  | start (v c : Nat)
  | reveal (v : Nat)
  | free (v : Nat)

noncomputable def step (s : S) : Op → S
  | .start v c => s.start v c
  | .reveal v => s.reveal v
  | .free v => s.free v

noncomputable def run (s : S) (ops : List Op) : S := ops.foldl step s

/-- **Every sequence of checkouts, reveals and view deallocations keeps the
invariant**, so `one_host`, `one_slot`, `start_attaches_unhosted`,
`purge_unhosted` and `weak_iff` hold at every step. -/
theorem inv_run : ∀ (ops : List Op) {s : S}, Inv s → Inv (run s ops)
  | [], _, h => h
  | op :: ops, s, h => by
    apply inv_run ops
    cases op with
    | start v c => exact start_inv h v c
    | reveal v => exact reveal_inv h v
    | free v => exact free_inv h v

/-- **A checkout takes the live host**: the view starts the very host the
other view had, which by `one_slot` no longer keeps it. -/
theorem start_reuses {s : S} (v c : Nat) {h : Host}
    (hg : s.pending v = none ∧ (s.displayed v).map (·.content) ≠ some c) (hw : s.weak c = some h) :
    (s.start v c).pending v = some h := by
  simp only [S.start, hg, ne_eq, not_false_eq_true, and_self, ite_true, hw]
  split <;> simp [S.collect]

/-- **Without a live host a checkout makes one**, on a root with no renderer. -/
theorem start_creates {s : S} (hs : Inv s) (v c : Nat)
    (hg : s.pending v = none ∧ (s.displayed v).map (·.content) ≠ some c) (hw : s.weak c = none) :
    (s.start v c).pending v = some ⟨s.next, c⟩ ∧ s.renderer c = none := by
  refine ⟨?_, start_attaches_unhosted hs c hw⟩
  simp only [S.start, hg, ne_eq, not_false_eq_true, and_self, ite_true, hw]
  simp [S.collect]

/-! ## At every step, from no views -/

/-- After any sequence of operations from no views, a checkout that makes a
host finds no renderer attached (Renderer.swift:94 holds). -/
theorem checkout_never_trips (ops : List Op) (c : Nat) (hw : (run S.empty ops).weak c = none) :
    (run S.empty ops).renderer c = none :=
  start_attaches_unhosted (inv_run ops inv_empty) c hw

/-- After any sequence of operations, a queued purge that finds no renderer
attached clears a root no live host renders. -/
theorem purge_never_frees_hosted (ops : List Op) (c : Nat) (hr : (run S.empty ops).renderer c = none) :
    ∀ h, (run S.empty ops).Alive h → h.content ≠ c :=
  purge_unhosted (inv_run ops inv_empty) c hr

/-- After any sequence of operations, the store sweep drops a preparation
(`hasLiveHost` false) only when no live host renders its root. -/
theorem sweep_never_drops_hosted (ops : List Op) (c : Nat) (hw : (run S.empty ops).weak c = none) :
    ∀ h, (run S.empty ops).Alive h → h.content ≠ c := fun h ha e =>
  by have := (weak_iff (inv_run ops inv_empty) c h).mpr ⟨ha, e⟩; rw [hw] at this; cases this

/-- After any sequence of operations, every root has at most one live host,
kept by one view. -/
theorem one_host_always (ops : List Op) {h h' : Host} (ha : (run S.empty ops).Alive h)
    (ha' : (run S.empty ops).Alive h') (hc : h.content = h'.content) : h = h' :=
  one_host (inv_run ops inv_empty) ha ha' hc

end UltraProofs.ListHosts
