/-!
# One live host per prepared root

Models how `NodeRow` rows hand a prepared node tree between row views
(NodeRow.swift). A preparation (`PreparedNodeContent`) owns one root, made
when it is prepared, and remembers its host weakly and the view that last
checked it out. A row view keeps a host it shows and one it is preparing to
show. `checkout` reuses a live host, taking it from the view that had it
(which keeps a snapshot in its place), and otherwise uses the host the
preparation drew ahead (`staged`), or makes one. A host is alive while a
view keeps it or the preparation stages it; when the last owner lets go it
is deallocated on the main thread (its `deinit` is main-actor isolated) and
detaches its renderer. A detached root's bitmaps are purged later on the
layout queue only if no renderer has attached to it since
(`Renderer.detach`), and the list's preparation store drops a preparation
only while it has no live host (`UltraListView.sweepPreparations`), freeing
a staged host with it.

Hosts are named by an id and the content (root) they render; views by a
number. Every operation is one main-thread turn followed by the
deallocations it causes (`collect`). That a host lives exactly while a view's
`displayedHost` or `pendingHost`, or the preparation's `staged`, keeps it
(the superview goes with the slot, and the commit and reveal closures hold
it weakly) is the model's reading of the Swift's references, not something
proved here.

* `inv_run`: every sequence of `stage`, `start`, `reveal`, `free` and `drop`
  keeps `Inv`.
* `start_reuses`, `start_uses_staged`, `start_creates`: a checkout takes the
  live host from the view that had it, else the staged host, and makes a
  host only when there is neither.
* `start_attaches_unhosted`: `checkout` creates a host, and so a renderer,
  only for a root with no renderer attached, so the precondition at
  Renderer.swift:94 ("a node can be hosted only once at a time") never fails.
  `stage` draws ahead only for a fresh root.
* `one_host`, `one_slot`: at every step a root has at most one live host,
  staged or kept, and a kept host is kept by exactly one view.
  `staged_unkept`: a staged host exists only while no view keeps a host of
  its root, and no view keeps the staged host itself.
* `hosted_has_renderer`: a root with a live host has a renderer attached, so
  making a second host for it, as a checkout that ignored the live or staged
  host would, trips that precondition.
* `purge_unhosted`, `weak_iff`: a purge, which needs the root to have no
  renderer, never touches a root with a live host, and the store sweep
  (`hasLiveHost` false) never drops a root a view keeps. `drop_detaches`: a
  dropped preparation's staged host goes and its root's renderer with it.
  `checkout_never_trips`, `purge_never_frees_hosted`,
  `sweep_never_drops_hosted` and `one_host_always` state these after every
  sequence of operations from no views.
-/

namespace UltraProofs.ListHosts

open Classical

structure Host where
  id : Nat
  content : Nat
deriving DecidableEq

/-- The views' shown and pending hosts, each preparation's weak host, owner
and staged host, each root's attached renderer (by host id), and the next
host id. -/
structure S where
  displayed : Nat → Option Host
  pending : Nat → Option Host
  hostOf : Nat → Option Nat
  owner : Nat → Option Nat
  renderer : Nat → Option Nat
  staged : Nat → Option Nat
  next : Nat

def S.empty : S :=
  ⟨fun _ => none, fun _ => none, fun _ => none, fun _ => none, fun _ => none, fun _ => none, 0⟩

/-- View `v` keeps host `h`. -/
def S.In (s : S) (v : Nat) (h : Host) : Prop := s.displayed v = some h ∨ s.pending v = some h

/-- Some view keeps `h`. -/
def S.Kept (s : S) (h : Host) : Prop := ∃ v, s.In v h

/-- The preparation of `h`'s root stages `h`. -/
def S.Staged (s : S) (h : Host) : Prop := s.staged h.content = some h.id

/-- A host is alive while a view keeps it or its preparation stages it. -/
def S.Alive (s : S) (h : Host) : Prop := s.Kept h ∨ s.Staged h

def upd {α : Type} (f : Nat → α) (k : Nat) (a : α) : Nat → α := fun k' => if k' = k then a else f k'

theorem if_t {α : Type} {p : Prop} [Decidable p] (h : p) (a b : α) : (if p then a else b) = a := by simp [h]
theorem if_f {α : Type} {p : Prop} [Decidable p] (h : ¬p) (a b : α) : (if p then a else b) = b := by simp [h]

@[simp] theorem upd_same {α : Type} (f : Nat → α) (k : Nat) (a : α) : upd f k a k = a := by simp [upd]
theorem upd_other {α : Type} (f : Nat → α) {k k' : Nat} (a : α) (h : k' ≠ k) : upd f k a k' = f k' := by
  simp [upd, h]

/-- Reading the weak `PreparedNodeContent.host`: the host a checkout made
current, while a view keeps it. -/
noncomputable def S.weak (s : S) (c : Nat) : Option Host :=
  match s.hostOf c with
  | some id => if s.Kept ⟨id, c⟩ then some ⟨id, c⟩ else none
  | none => none

/-- Deallocations: every host no view keeps and no preparation stages runs
`deinit`, whose `renderer.detach()` clears the root's renderer if it is that
host's. -/
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
`v`, preparing nothing and not showing root `c`, checks out `c`'s host: the
live one, else the staged one, else a new one. The staged slot is cleared. -/
noncomputable def S.start (s : S) (v c : Nat) : S :=
  if s.pending v = none ∧ (s.displayed v).map (·.content) ≠ some c then
    match s.weak c with
    | some h =>
      let s1 := match s.owner c with
        | some o => if o = v then s else s.release o h
        | none => s
      { s1 with owner := upd s1.owner c (some v), pending := upd s1.pending v (some h),
                staged := upd s1.staged c none }.collect
    | none =>
      match s.staged c with
      | some id =>
        { s with owner := upd s.owner c (some v), pending := upd s.pending v (some ⟨id, c⟩),
                 hostOf := upd s.hostOf c (some id), staged := upd s.staged c none }.collect
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

/-- `NodeRow.prepare` drawing ahead: a host for a fresh root (one with no
renderer; `prepare` makes the root), kept only by the preparation. -/
noncomputable def S.stage (s : S) (c : Nat) : S :=
  if s.renderer c = none then
    { s with staged := upd s.staged c (some s.next), renderer := upd s.renderer c (some s.next),
             next := s.next + 1 }
  else s

/-- The store sweep drops a preparation whose `hasLiveHost` reads false; its
staged host goes with it. -/
noncomputable def S.drop (s : S) (c : Nat) : S :=
  if s.weak c = none then { s with staged := upd s.staged c none }.collect else s

/-- The invariant before deallocations run. -/
structure Pre (s : S) : Prop where
  twoSlots : ∀ v h, ¬(s.displayed v = some h ∧ s.pending v = some h)
  weak : ∀ h, s.Kept h → s.hostOf h.content = some h.id
  owner : ∀ v h, s.In v h → s.owner h.content = some v
  rendOf : ∀ h, s.Alive h → s.renderer h.content = some h.id
  fresh : ∀ h, s.Alive h → h.id < s.next
  stagedFree : ∀ c id v, s.staged c = some id → ¬s.In v ⟨id, c⟩

structure Inv (s : S) : Prop extends Pre s where
  rendAlive : ∀ c id, s.renderer c = some id → s.Alive ⟨id, c⟩

theorem collect_inv {s : S} (h : Pre s) : Inv s.collect := by
  refine ⟨⟨h.twoSlots, h.weak, h.owner, fun x hx => ?_, h.fresh, h.stagedFree⟩, fun c id hc => ?_⟩
  · show (match s.renderer x.content with
      | some id => if s.Alive ⟨id, x.content⟩ then some id else none
      | none => none) = some x.id
    rw [h.rendOf x hx]
    simp only
    rw [if_t (by cases x; exact hx)]
  · simp only [S.collect] at hc
    split at hc
    · split at hc
      · cases hc; assumption
      · cases hc
    · cases hc

theorem inv_empty : Inv S.empty := by
  refine ⟨⟨by simp [S.empty], ?_, ?_, ?_, ?_, ?_⟩, ?_⟩
  · intro _ ⟨_, h⟩; simp [S.In, S.empty] at h
  · intro _ _ h; simp [S.In, S.empty] at h
  · intro _ h; rcases h with ⟨_, h⟩ | h <;> simp [S.In, S.Staged, S.empty] at h
  · intro _ h; rcases h with ⟨_, h⟩ | h <;> simp [S.In, S.Staged, S.empty] at h
  · intro _ _ _ h; simp [S.empty] at h
  · intro _ _ h; simp [S.empty] at h

/-- **A root has at most one live host**, staged or kept. -/
theorem one_host {s : S} (hs : Inv s) {h h' : Host} (ha : s.Alive h) (ha' : s.Alive h')
    (hc : h.content = h'.content) : h = h' := by
  have e := hs.rendOf h ha
  have e' := hs.rendOf h' ha'
  rw [hc, e'] at e
  cases h; cases h'; simp_all

/-- **A kept host is kept by exactly one view.** -/
theorem one_slot {s : S} (hs : Inv s) {v w : Nat} {h : Host} (hv : s.In v h) (hw : s.In w h) : v = w := by
  have := hs.owner v h hv
  rw [hs.owner w h hw] at this
  cases this; rfl

/-- **The weak host is the kept host**: `hasLiveHost` reads true exactly when
a view keeps a host of the root. -/
theorem weak_iff {s : S} (hs : Inv s) (c : Nat) (h : Host) : s.weak c = some h ↔ s.Kept h ∧ h.content = c := by
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
    rw [if_t ha]

/-- **A staged host waits alone**: no view keeps a host of its root, nor the
staged host itself. -/
theorem staged_unkept {s : S} (hs : Inv s) {c id : Nat} (hst : s.staged c = some id) :
    ∀ h, s.Kept h → h.content ≠ c := by
  intro h hk e
  have := one_host hs (Or.inl hk) (Or.inr hst : s.Alive ⟨id, c⟩) e
  obtain ⟨v, hv⟩ := hk
  exact hs.stagedFree c id v hst (this ▸ hv)

/-- **A hosted root has a renderer attached**, so a second host for it would
trip Renderer.swift:94. -/
theorem hosted_has_renderer {s : S} (hs : Inv s) {h : Host} (ha : s.Alive h) :
    s.renderer h.content ≠ none := by
  rw [hs.rendOf h ha]; simp

/-- **`checkout` creates a renderer only for an unhosted root**: when the weak
host reads `nil` and nothing is staged, no renderer is attached. -/
theorem start_attaches_unhosted {s : S} (hs : Inv s) (c : Nat) (hw : s.weak c = none)
    (hst : s.staged c = none) : s.renderer c = none := by
  cases e : s.renderer c with
  | none => rfl
  | some id =>
    rcases hs.rendAlive c id e with hk | hsg
    · have := (weak_iff hs c ⟨id, c⟩).mpr ⟨hk, rfl⟩
      rw [hw] at this; cases this
    · simp only [S.Staged] at hsg; rw [hst] at hsg; cases hsg

/-- **A purge never frees a hosted root.** It runs only when no renderer is
attached, and then no host of the root is alive. -/
theorem purge_unhosted {s : S} (hs : Inv s) (c : Nat) (hr : s.renderer c = none) :
    ∀ h, s.Alive h → h.content ≠ c := by
  intro h ha e
  have := hs.rendOf h ha
  rw [e, hr] at this; cases this

/-! ## Each operation keeps the invariant -/

/-- What every operation's proof needs: the hosts alive afterwards were
alive before, or are one new host of a root with no live host. -/
theorem pre_of {s s' : S} (hs : Inv s) (hstep : s'.next = s.next ∨ s'.next = s.next + 1)
    (alive : ∀ x, s'.Alive x → s.Alive x ∨ (x.id = s.next ∧ s'.next = s.next + 1))
    (rend : ∀ x, s'.Alive x → s.Alive x → s'.renderer x.content = s.renderer x.content)
    (rendNew : ∀ x, s'.Alive x → x.id = s.next → s'.next = s.next + 1 → s'.renderer x.content = some x.id)
    (twoSlots : ∀ v h, ¬(s'.displayed v = some h ∧ s'.pending v = some h))
    (weak : ∀ h, s'.Kept h → s'.hostOf h.content = some h.id)
    (owner : ∀ v h, s'.In v h → s'.owner h.content = some v)
    (stagedFree : ∀ c id v, s'.staged c = some id → ¬s'.In v ⟨id, c⟩) : Pre s' := by
  refine ⟨twoSlots, weak, owner, fun x hx => ?_, fun x hx => ?_, stagedFree⟩
  · rcases alive x hx with ha | ⟨hid, hn⟩
    · rw [rend x hx ha]; exact hs.rendOf x ha
    · exact rendNew x hx hid hn
  · rcases alive x hx with ha | ⟨hid, hn⟩
    · have := hs.fresh x ha; omega
    · omega

theorem start_inv {s : S} (hs : Inv s) (v c : Nat) : Inv (s.start v c) := by
  unfold S.start
  split
  · rename_i hg
    obtain ⟨hp, hd⟩ := hg
    cases hwk : s.weak c with
    | none =>
      -- No view keeps a host of `c`.
      have noC : ∀ x, s.Kept x → x.content ≠ c := fun x hx e => by
        have := (weak_iff hs c x).mpr ⟨hx, e⟩; rw [hwk] at this; cases this
      cases hst : s.staged c with
      | some id =>
        apply collect_inv
        generalize hS : ({ s with
            owner := upd s.owner c (some v), pending := upd s.pending v (some ⟨id, c⟩),
            hostOf := upd s.hostOf c (some id), staged := upd s.staged c none } : S) = s'
        have inS : ∀ w x, s'.In w x → s.In w x ∨ (w = v ∧ x = ⟨id, c⟩) := by
          intro w x hx; rw [← hS] at hx
          by_cases e : w = v
          · subst e; simp only [S.In, upd_same, Option.some.injEq] at hx
            rcases hx with hx | hx
            · exact Or.inl (Or.inl hx)
            · exact Or.inr ⟨rfl, hx.symm⟩
          · simp only [S.In, upd_other _ _ e] at hx; exact Or.inl hx
        have stS : ∀ x, s'.Staged x → s.Staged x ∧ x.content ≠ c := by
          intro x hx; rw [← hS] at hx; simp only [S.Staged] at hx
          by_cases e : x.content = c
          · rw [e] at hx; simp at hx
          · rw [upd_other _ _ e] at hx; exact ⟨hx, e⟩
        have staged_alive : s.Alive ⟨id, c⟩ := Or.inr hst
        refine pre_of hs (Or.inl (by rw [← hS])) (fun x hx => ?_) (fun x _ _ => by rw [← hS])
          (fun x hx hid hn => by rw [← hS] at hn; simp at hn) (fun w x ⟨h1, h2⟩ => ?_) (fun x ⟨w, hx⟩ => ?_)
          (fun w x hx => ?_) (fun c' id' w hc' hin => ?_)
        · rcases hx with ⟨w, hw⟩ | hx
          · rcases inS w x hw with h | ⟨_, rfl⟩
            · exact Or.inl (Or.inl ⟨w, h⟩)
            · exact Or.inl staged_alive
          · exact Or.inl (Or.inr (stS x hx).1)
        · rw [← hS] at h1 h2
          by_cases e : w = v
          · subst e; simp only [upd_same, Option.some.injEq] at h2; subst h2
            exact hs.stagedFree c id w hst (Or.inl h1)
          · simp only [upd_other _ _ e] at h2; exact hs.twoSlots w x ⟨h1, h2⟩
        · rcases inS w x hx with h | ⟨_, rfl⟩
          · rw [← hS]; simp only [upd_other _ _ (noC x ⟨w, h⟩)]; exact hs.weak x ⟨w, h⟩
          · rw [← hS]; simp
        · rcases inS w x hx with h | ⟨rfl, rfl⟩
          · rw [← hS]; simp only [upd_other _ _ (noC x ⟨w, h⟩)]; exact hs.owner w x h
          · rw [← hS]; simp
        · have hc'' := stS ⟨id', c'⟩ hc'
          rcases inS w _ hin with h | ⟨_, he⟩
          · exact hs.stagedFree c' id' w hc''.1 h
          · cases he; exact hc''.2 rfl
      | none =>
        apply collect_inv
        have hr0 := start_attaches_unhosted hs c hwk hst
        have noA : ∀ x, s.Alive x → x.content ≠ c := purge_unhosted hs c hr0
        generalize hS : ({ s with
            owner := upd s.owner c (some v), pending := upd s.pending v (some ⟨s.next, c⟩),
            hostOf := upd s.hostOf c (some s.next), renderer := upd s.renderer c (some s.next),
            next := s.next + 1 } : S) = s'
        have inS : ∀ w x, s'.In w x → s.In w x ∨ (w = v ∧ x = ⟨s.next, c⟩) := by
          intro w x hx; rw [← hS] at hx
          by_cases e : w = v
          · subst e; simp only [S.In, upd_same, Option.some.injEq] at hx
            rcases hx with hx | hx
            · exact Or.inl (Or.inl hx)
            · exact Or.inr ⟨rfl, hx.symm⟩
          · simp only [S.In, upd_other _ _ e] at hx; exact Or.inl hx
        have stS : ∀ x, s'.Staged x → s.Staged x := fun x hx => by rw [← hS] at hx; exact hx
        refine pre_of hs (Or.inr (by rw [← hS])) (fun x hx => ?_) (fun x _ ha => ?_)
          (fun x hx hid _ => ?_) (fun w x ⟨h1, h2⟩ => ?_) (fun x ⟨w, hx⟩ => ?_)
          (fun w x hx => ?_) (fun c' id' w hc' hin => ?_)
        · rcases hx with ⟨w, hw⟩ | hx
          · rcases inS w x hw with h | ⟨_, rfl⟩
            · exact Or.inl (Or.inl ⟨w, h⟩)
            · exact Or.inr ⟨rfl, by rw [← hS]⟩
          · exact Or.inl (Or.inr (stS x hx))
        · rw [← hS]; simp only [upd_other _ _ (noA x ha)]
        · rcases hx with ⟨w, hw⟩ | hx
          · rcases inS w x hw with h | ⟨_, rfl⟩
            · have := hs.fresh x (Or.inl ⟨w, h⟩); omega
            · rw [← hS]; simp
          · have := hs.fresh x (Or.inr (stS x hx)); omega
        · rw [← hS] at h1 h2
          by_cases e : w = v
          · subst e; simp only [upd_same, Option.some.injEq] at h2; subst h2
            simp at h1; exact hd (by simp [h1])
          · simp only [upd_other _ _ e] at h2; exact hs.twoSlots w x ⟨h1, h2⟩
        · rcases inS w x hx with h | ⟨_, rfl⟩
          · rw [← hS]; simp only [upd_other _ _ (noA x (Or.inl ⟨w, h⟩))]; exact hs.weak x ⟨w, h⟩
          · rw [← hS]; simp
        · rcases inS w x hx with h | ⟨rfl, rfl⟩
          · rw [← hS]; simp only [upd_other _ _ (noA x (Or.inl ⟨w, h⟩))]; exact hs.owner w x h
          · rw [← hS]; simp
        · have hc'' := stS ⟨id', c'⟩ hc'
          rcases inS w _ hin with h | ⟨_, he⟩
          · exact hs.stagedFree c' id' w hc'' h
          · exact noA _ (Or.inr hc'') (congrArg Host.content he)
    | some h =>
      obtain ⟨⟨u, hu⟩, hc⟩ := (weak_iff hs c h).mp hwk
      subst hc
      have ho := hs.owner u h hu
      have hst : s.staged h.content = none := by
        cases e : s.staged h.content with
        | none => rfl
        | some id => exact absurd rfl (staged_unkept hs e h ⟨u, hu⟩)
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
      have rs : r.hostOf = s.hostOf ∧ r.owner = s.owner ∧ r.renderer = s.renderer ∧ r.next = s.next ∧
          r.staged = s.staged := by
        rw [← hr]; exact ⟨rfl, rfl, rfl, rfl, rfl⟩
      have stEq : upd r.staged h.content none = s.staged := by
        rw [rs.2.2.2.2]; funext k; by_cases e : k = h.content
        · subst e; simp [hst]
        · simp [upd_other _ _ e]
      generalize hS : ({ r with
          owner := upd r.owner h.content (some v), pending := upd r.pending v (some h),
          staged := upd r.staged h.content none } : S) = s'
      -- Who keeps what afterwards: `h` only in `v`'s pending slot, everything else as before.
      have inS : ∀ w x, s'.In w x → (x ≠ h ∧ s.In w x) ∨ (w = v ∧ x = h) := by
        intro w x hx
        rw [← hS] at hx
        simp only [S.In] at hx
        by_cases e : w = v
        · subst e
          simp only [upd_same, Option.some.injEq, rd, huv.symm, false_and, ite_false] at hx
          rcases hx with hx | hx
          · left; refine ⟨fun hxh => ?_, Or.inl hx⟩
            subst hxh; exact hd (by simp [hx])
          · exact Or.inr ⟨rfl, hx.symm⟩
        · rw [upd_other _ _ e, rp, rd] at hx
          left
          by_cases hxh : x = h
          · subst hxh
            exfalso
            rcases hx with hx | hx
            · split at hx
              · cases hx
              · rename_i hn; exact hn ⟨only w (Or.inl hx), hx⟩
            · split at hx
              · cases hx
              · rename_i hn; exact hn ⟨only w (Or.inr hx), hx⟩
          · refine ⟨hxh, ?_⟩
            rcases hx with hx | hx
            · split at hx
              · cases hx
              · exact Or.inl hx
            · split at hx
              · cases hx
              · exact Or.inr hx
      have stS : ∀ x, s'.Staged x → s.Staged x := fun x hx => by
        rw [← hS] at hx; simp only [S.Staged, stEq] at hx; exact hx
      have oc : ∀ x w, x ≠ h → s.In w x → x.content ≠ h.content := fun x w hxh hx e =>
        hxh (one_host hs (Or.inl ⟨w, hx⟩) (Or.inl ⟨u, hu⟩) e)
      refine pre_of hs (Or.inl (by rw [← hS, rs.2.2.2.1])) (fun x hx => ?_) (fun x _ _ => by rw [← hS, rs.2.2.1])
        (fun x hx hid hn => by rw [← hS] at hn; simp [rs.2.2.2.1] at hn) (fun w x ⟨h1, h2⟩ => ?_)
        (fun x ⟨w, hx⟩ => ?_) (fun w x hx => ?_) (fun c' id' w hc' hin => ?_)
      · rcases hx with ⟨w, hw⟩ | hx
        · rcases inS w x hw with ⟨_, h⟩ | ⟨_, rfl⟩
          · exact Or.inl (Or.inl ⟨w, h⟩)
          · exact Or.inl (Or.inl ⟨u, hu⟩)
        · exact Or.inl (Or.inr (stS x hx))
      · rw [← hS] at h1 h2
        by_cases e : w = v
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
      · rw [← hS]; simp only [rs.1]
        rcases inS w x hx with ⟨_, hx⟩ | ⟨_, hxh⟩
        · exact hs.weak x ⟨w, hx⟩
        · rw [hxh]; exact hs.weak h ⟨u, hu⟩
      · rcases inS w x hx with ⟨hxh, hx⟩ | ⟨rfl, rfl⟩
        · rw [← hS]; simp only [upd_other _ _ (oc x w hxh hx), rs.2.1]; exact hs.owner w x hx
        · rw [← hS]; simp
      · have hc'' := stS ⟨id', c'⟩ hc'
        rcases inS w _ hin with ⟨_, h'⟩ | ⟨_, he⟩
        · exact hs.stagedFree c' id' w hc'' h'
        · subst he; simp only [S.Staged] at hc''; rw [hst] at hc''; cases hc''
  · exact hs

theorem reveal_inv {s : S} (hs : Inv s) (v : Nat) : Inv (s.reveal v) := by
  unfold S.reveal
  cases hp : s.pending v with
  | none => exact hs
  | some h =>
    apply collect_inv
    generalize hS : ({ s with displayed := upd s.displayed v (some h), pending := upd s.pending v none } : S) = s'
    have inS : ∀ w x, s'.In w x → s.In w x := by
      intro w x hx
      rw [← hS] at hx
      by_cases e : w = v
      · subst e; simp only [S.In, upd_same, Option.some.injEq, reduceCtorEq, or_false] at hx
        subst hx; exact Or.inr hp
      · simp only [S.In, upd_other _ _ e] at hx; exact hx
    have stS : ∀ x, s'.Staged x → s.Staged x := fun x hx => by rw [← hS] at hx; exact hx
    refine pre_of hs (Or.inl (by rw [← hS])) (fun x hx => ?_) (fun x _ _ => by rw [← hS])
      (fun x hx hid hn => by rw [← hS] at hn; simp at hn) (fun w x ⟨h1, h2⟩ => ?_)
      (fun x ⟨w, hx⟩ => by rw [← hS]; exact hs.weak x ⟨w, inS w x hx⟩)
      (fun w x hx => by rw [← hS]; exact hs.owner w x (inS w x hx))
      (fun c' id' w hc' hin => hs.stagedFree c' id' w (stS ⟨id', c'⟩ hc') (inS w _ hin))
    · rcases hx with ⟨w, hw⟩ | hx
      · exact Or.inl (Or.inl ⟨w, inS w x hw⟩)
      · exact Or.inl (Or.inr (stS x hx))
    · rw [← hS] at h1 h2
      by_cases e : w = v
      · subst e; simp at h2
      · simp only [upd_other _ _ e] at h1 h2; exact hs.twoSlots w x ⟨h1, h2⟩

theorem free_inv {s : S} (hs : Inv s) (v : Nat) : Inv (s.free v) := by
  unfold S.free
  apply collect_inv
  generalize hS : ({ s with
      displayed := upd s.displayed v none, pending := upd s.pending v none,
      owner := fun c => if s.owner c = some v then none else s.owner c } : S) = s'
  have inS : ∀ w x, s'.In w x → w ≠ v ∧ s.In w x := by
    intro w x hx
    rw [← hS] at hx
    by_cases e : w = v
    · subst e; simp [S.In] at hx
    · simp only [S.In, upd_other _ _ e] at hx; exact ⟨e, hx⟩
  have stS : ∀ x, s'.Staged x → s.Staged x := fun x hx => by rw [← hS] at hx; exact hx
  refine pre_of hs (Or.inl (by rw [← hS])) (fun x hx => ?_) (fun x _ _ => by rw [← hS])
    (fun x hx hid hn => by rw [← hS] at hn; simp at hn) (fun w x ⟨h1, h2⟩ => ?_)
    (fun x ⟨w, hx⟩ => by rw [← hS]; exact hs.weak x ⟨w, (inS w x hx).2⟩) (fun w x hx => ?_)
    (fun c' id' w hc' hin => hs.stagedFree c' id' w (stS ⟨id', c'⟩ hc') (inS w _ hin).2)
  · rcases hx with ⟨w, hw⟩ | hx
    · exact Or.inl (Or.inl ⟨w, (inS w x hw).2⟩)
    · exact Or.inl (Or.inr (stS x hx))
  · rw [← hS] at h1 h2
    by_cases e : w = v
    · subst e; simp at h1
    · simp only [upd_other _ _ e] at h1 h2; exact hs.twoSlots w x ⟨h1, h2⟩
  · obtain ⟨e, hx⟩ := inS w x hx
    have := hs.owner w x hx
    rw [← hS]; simp only [this, Option.some.injEq, e, ite_false]

theorem stage_inv {s : S} (hs : Inv s) (c : Nat) : Inv (s.stage c) := by
  unfold S.stage
  split
  · rename_i hr0
    have noA : ∀ x, s.Alive x → x.content ≠ c := purge_unhosted hs c hr0
    generalize hS : ({ s with
        staged := upd s.staged c (some s.next), renderer := upd s.renderer c (some s.next),
        next := s.next + 1 } : S) = s'
    have inS : ∀ w x, s'.In w x → s.In w x := fun w x hx => by rw [← hS] at hx; exact hx
    have stS : ∀ x, s'.Staged x → s.Staged x ∨ x = ⟨s.next, c⟩ := by
      intro x hx; rw [← hS] at hx; simp only [S.Staged] at hx
      by_cases e : x.content = c
      · rw [e] at hx; simp only [upd_same, Option.some.injEq] at hx
        right; cases x; simp_all
      · rw [upd_other _ _ e] at hx; exact Or.inl hx
    have pre : Pre s' := by
      refine pre_of hs (Or.inr (by rw [← hS])) (fun x hx => ?_) (fun x _ ha => ?_)
        (fun x hx hid _ => ?_) (fun w x ⟨h1, h2⟩ => ?_)
        (fun x ⟨w, hx⟩ => by rw [← hS]; exact hs.weak x ⟨w, inS w x hx⟩)
        (fun w x hx => by rw [← hS]; exact hs.owner w x (inS w x hx)) (fun c' id' w hc' hin => ?_)
      · rcases hx with ⟨w, hw⟩ | hx
        · exact Or.inl (Or.inl ⟨w, inS w x hw⟩)
        · rcases stS x hx with h | rfl
          · exact Or.inl (Or.inr h)
          · exact Or.inr ⟨rfl, by rw [← hS]⟩
      · rw [← hS]; simp only [upd_other _ _ (noA x ha)]
      · rcases hx with ⟨w, hw⟩ | hx
        · have := hs.fresh x (Or.inl ⟨w, inS w x hw⟩); omega
        · rcases stS x hx with h | rfl
          · have := hs.fresh x (Or.inr h); omega
          · rw [← hS]; simp
      · rw [← hS] at h1 h2; exact hs.twoSlots w x ⟨h1, h2⟩
      · rcases stS ⟨id', c'⟩ hc' with h | he
        · exact hs.stagedFree c' id' w h (inS w _ hin)
        · cases he; exact noA ⟨s.next, c⟩ (Or.inl ⟨w, inS w _ hin⟩) rfl
    refine ⟨pre, fun c' id hc => ?_⟩
    rw [← hS] at hc ⊢
    by_cases e : c' = c
    · subst e; simp only [upd_same, Option.some.injEq] at hc; subst hc
      exact Or.inr (by simp [S.Staged])
    · simp only [upd_other _ _ e] at hc
      rcases hs.rendAlive c' id hc with ⟨w, hw⟩ | hx
      · exact Or.inl ⟨w, hw⟩
      · right; simp only [S.Staged] at hx ⊢; rw [upd_other _ _ e]; exact hx
  · exact hs

theorem drop_inv {s : S} (hs : Inv s) (c : Nat) : Inv (s.drop c) := by
  unfold S.drop
  split
  · apply collect_inv
    generalize hS : ({ s with staged := upd s.staged c none } : S) = s'
    have inS : ∀ w x, s'.In w x → s.In w x := fun w x hx => by rw [← hS] at hx; exact hx
    have stS : ∀ x, s'.Staged x → s.Staged x := by
      intro x hx; rw [← hS] at hx; simp only [S.Staged] at hx
      by_cases e : x.content = c
      · rw [e] at hx; simp at hx
      · rw [upd_other _ _ e] at hx; exact hx
    exact pre_of hs (Or.inl (by rw [← hS]))
      (fun x hx => by
        rcases hx with ⟨w, hw⟩ | hx
        · exact Or.inl (Or.inl ⟨w, inS w x hw⟩)
        · exact Or.inl (Or.inr (stS x hx)))
      (fun x _ _ => by rw [← hS]) (fun x hx hid hn => by rw [← hS] at hn; simp at hn)
      (fun w x ⟨h1, h2⟩ => by rw [← hS] at h1 h2; exact hs.twoSlots w x ⟨h1, h2⟩)
      (fun x ⟨w, hx⟩ => by rw [← hS]; exact hs.weak x ⟨w, inS w x hx⟩)
      (fun w x hx => by rw [← hS]; exact hs.owner w x (inS w x hx))
      (fun c' id' w hc' hin => hs.stagedFree c' id' w (stS ⟨id', c'⟩ hc') (inS w _ hin))
  · exact hs

inductive Op
  | stage (c : Nat)
  | start (v c : Nat)
  | reveal (v : Nat)
  | free (v : Nat)
  | drop (c : Nat)

noncomputable def step (s : S) : Op → S
  | .stage c => s.stage c
  | .start v c => s.start v c
  | .reveal v => s.reveal v
  | .free v => s.free v
  | .drop c => s.drop c

noncomputable def run (s : S) (ops : List Op) : S := ops.foldl step s

/-- **Every sequence of stagings, checkouts, reveals, view deallocations and
store drops keeps the invariant**, so `one_host`, `one_slot`,
`staged_unkept`, `start_attaches_unhosted`, `purge_unhosted` and `weak_iff`
hold at every step. -/
theorem inv_run : ∀ (ops : List Op) {s : S}, Inv s → Inv (run s ops)
  | [], _, h => h
  | op :: ops, s, h => by
    apply inv_run ops
    cases op with
    | stage c => exact stage_inv h c
    | start v c => exact start_inv h v c
    | reveal v => exact reveal_inv h v
    | free v => exact free_inv h v
    | drop c => exact drop_inv h c

/-- **A checkout takes the live host**: the view starts the very host the
other view had, which by `one_slot` no longer keeps it. -/
theorem start_reuses {s : S} (v c : Nat) {h : Host}
    (hg : s.pending v = none ∧ (s.displayed v).map (·.content) ≠ some c) (hw : s.weak c = some h) :
    (s.start v c).pending v = some h := by
  simp only [S.start, hg, ne_eq, not_false_eq_true, and_self, ite_true, hw]
  split <;> simp [S.collect]

/-- **Without a live host a checkout uses the staged one**, which already
has its renderer: no new renderer attaches. -/
theorem start_uses_staged {s : S} (v c id : Nat)
    (hg : s.pending v = none ∧ (s.displayed v).map (·.content) ≠ some c) (hw : s.weak c = none)
    (hst : s.staged c = some id) :
    (s.start v c).pending v = some ⟨id, c⟩ ∧ (s.start v c).staged c = none ∧ (s.start v c).next = s.next := by
  simp only [S.start, hg, ne_eq, not_false_eq_true, and_self, ite_true, hw, hst]
  simp [S.collect]

/-- **With neither a live nor a staged host a checkout makes one**, on a root
with no renderer. -/
theorem start_creates {s : S} (hs : Inv s) (v c : Nat)
    (hg : s.pending v = none ∧ (s.displayed v).map (·.content) ≠ some c) (hw : s.weak c = none)
    (hst : s.staged c = none) :
    (s.start v c).pending v = some ⟨s.next, c⟩ ∧ s.renderer c = none := by
  refine ⟨?_, start_attaches_unhosted hs c hw hst⟩
  simp only [S.start, hg, ne_eq, not_false_eq_true, and_self, ite_true, hw, hst]
  simp [S.collect]

/-- **A dropped preparation takes its staged host and the root's renderer
with it**, so the root's bitmaps can be purged. -/
theorem drop_detaches {s : S} (hs : Inv s) (c : Nat) (hw : s.weak c = none) :
    (s.drop c).staged c = none ∧ (s.drop c).renderer c = none := by
  have noK : ∀ x, s.Kept x → x.content ≠ c := fun x hx e => by
    have := (weak_iff hs c x).mpr ⟨hx, e⟩; rw [hw] at this; cases this
  simp only [S.drop, hw, ite_true]
  refine ⟨by simp [S.collect], ?_⟩
  simp only [S.collect]
  split
  · rename_i id _
    rw [if_f]
    rintro (⟨w, hk⟩ | hsg)
    · exact noK ⟨id, c⟩ ⟨w, hk⟩ rfl
    · simp [S.Staged] at hsg
  · rfl

/-! ## At every step, from no views -/

/-- After any sequence of operations from no views, a checkout that makes a
host finds no renderer attached (Renderer.swift:94 holds). -/
theorem checkout_never_trips (ops : List Op) (c : Nat) (hw : (run S.empty ops).weak c = none)
    (hst : (run S.empty ops).staged c = none) : (run S.empty ops).renderer c = none :=
  start_attaches_unhosted (inv_run ops inv_empty) c hw hst

/-- After any sequence of operations, a queued purge that finds no renderer
attached clears a root no live host renders. -/
theorem purge_never_frees_hosted (ops : List Op) (c : Nat) (hr : (run S.empty ops).renderer c = none) :
    ∀ h, (run S.empty ops).Alive h → h.content ≠ c :=
  purge_unhosted (inv_run ops inv_empty) c hr

/-- After any sequence of operations, the store sweep drops a preparation
(`hasLiveHost` false) only when no view keeps a host of its root. -/
theorem sweep_never_drops_hosted (ops : List Op) (c : Nat) (hw : (run S.empty ops).weak c = none) :
    ∀ h, (run S.empty ops).Kept h → h.content ≠ c := fun h ha e =>
  by have := (weak_iff (inv_run ops inv_empty) c h).mpr ⟨ha, e⟩; rw [hw] at this; cases this

/-- After any sequence of operations, every root has at most one live host,
staged or kept. -/
theorem one_host_always (ops : List Op) {h h' : Host} (ha : (run S.empty ops).Alive h)
    (ha' : (run S.empty ops).Alive h') (hc : h.content = h'.content) : h = h' :=
  one_host (inv_run ops inv_empty) ha ha' hc

/-- After any sequence of operations, a staged host waits alone. -/
theorem staged_unkept_always (ops : List Op) {c id : Nat} (hst : (run S.empty ops).staged c = some id) :
    ∀ h, (run S.empty ops).Kept h → h.content ≠ c :=
  staged_unkept (inv_run ops inv_empty) hst

end UltraProofs.ListHosts
