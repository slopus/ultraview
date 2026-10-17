import UltraProofs.Basic

/-!
# Commits, merging and the mailbox

Models `Commit`, `CommitEntry.merge`, `Commit.merge`, `CommitMailbox` and
the main thread's `CommitApplier.apply` / `NodeHostView.apply`.

The main thread's views are a map from nodes to view records. Applying an
entry touches only its own node: `unmount` removes the view, `mount` creates
it from the entry (frame, props, contents, child order), `update` changes
the fields the entry carries on an existing view and does nothing without
one. Child order is data on the parent's record.

A pipeline mount always carries a frame and props (`Renderer.evaluate`
queues every node it mounts), so `mount` builds the whole record from the
entry. Swift reuses a view that a merged unmount-then-mount left in place
and keeps its old `mountedChildren` when the entry has no child list; those
children have no views at that point (their own unmount entries removed
them), so the difference is not observable. MAPPING.md records this.
-/

namespace UltraProofs.Commits

open UltraProofs

structure View (F P B : Type) where
  frame : F
  props : P
  contents : Option B
  children : List Node

inductive Kind
  | mount
  | update
  | unmount
  deriving DecidableEq

inductive Change (B : Type)
  | set (b : B)
  | clear

structure Entry (F P B : Type) where
  kind : Kind
  frame : Option F := none
  props : Option P := none
  contents : Option (Change B) := none
  children : Option (List Node) := none

variable {F P B : Type}

/-- `CommitEntry.merge`: a newer mount or unmount replaces the entry; a newer
update overlays the fields it carries. -/
def Entry.merge (old new : Entry F P B) : Entry F P B :=
  match new.kind with
  | .update =>
    { kind := if old.kind = .unmount then .update else old.kind
      frame := pick new.frame old.frame
      props := pick new.props old.props
      contents := pick new.contents old.contents
      children := pick new.children old.children }
  | _ => new

def applyContents : Option (Change B) → Option B → Option B
  | none, c => c
  | some (.set b), _ => some b
  | some .clear, _ => none

/-- `UltraNode.apply(_:)` together with `ensureView`/`unmountView`. -/
def Entry.apply [Inhabited F] [Inhabited P] (e : Entry F P B) (v : Option (View F P B)) :
    Option (View F P B) :=
  match e.kind with
  | .unmount => none
  | .mount =>
    some { frame := e.frame.getD default, props := e.props.getD default
           contents := applyContents e.contents none, children := e.children.getD [] }
  | .update =>
    v.map fun r =>
      { frame := e.frame.getD r.frame, props := e.props.getD r.props
        contents := applyContents e.contents r.contents, children := e.children.getD r.children }

abbrev ViewState (F P B : Type) := Node → Option (View F P B)

structure Commit (F P B : Type) where
  generation : Nat
  request : Nat
  entries : Node → Option (Entry F P B)

def applyOpt [Inhabited F] [Inhabited P] : Option (Entry F P B) → Option (View F P B) →
    Option (View F P B)
  | none, v => v
  | some e, v => e.apply v

/-- `CommitApplier.apply`. -/
def Commit.apply [Inhabited F] [Inhabited P] (c : Commit F P B) (v : ViewState F P B) :
    ViewState F P B :=
  fun n => applyOpt (c.entries n) (v n)

def mergeOpt : Option (Entry F P B) → Option (Entry F P B) → Option (Entry F P B)
  | e, none => e
  | none, some e => some e
  | some a, some b => some (a.merge b)

/-- `Commit.merge`. -/
def Commit.merge (old new : Commit F P B) : Commit F P B where
  generation := new.generation
  request := max old.request new.request
  entries n := mergeOpt (old.entries n) (new.entries n)

/-- A pipeline commit sends `update` entries only for nodes that have a view
(nodes it mounts in the same pass get a `mount` entry instead). -/
def UpdatesTargetViews (c : Commit F P B) (v : ViewState F P B) : Prop :=
  ∀ n e, c.entries n = some e → e.kind = .update → (v n).isSome

theorem applyContents_pick (n o : Option (Change B)) (c : Option B) :
    applyContents (pick n o) c = applyContents n (applyContents o c) := by
  cases n with
  | none => rfl
  | some x => cases x <;> rfl

theorem Entry.apply_merge [Inhabited F] [Inhabited P] (a b : Entry F P B) (v : Option (View F P B))
    (hwf : b.kind = .update → (a.apply v).isSome) :
    (a.merge b).apply v = b.apply (a.apply v) := by
  cases hb : b.kind with
  | mount => simp [Entry.merge, Entry.apply, hb]
  | unmount => simp [Entry.merge, Entry.apply, hb]
  | update =>
    have hs := hwf hb
    cases ha : a.kind with
    | unmount => simp [Entry.apply, ha] at hs
    | mount =>
      simp [Entry.merge, Entry.apply, hb, ha, getD_pick, applyContents_pick]
    | update =>
      cases v with
      | none => simp [Entry.apply, ha] at hs
      | some r =>
        simp [Entry.merge, Entry.apply, hb, ha, getD_pick, applyContents_pick]

/-- **Merging is sound**: applying a merged commit equals applying the two
commits in order, so the mailbox can fold a newer commit into an unapplied
older one without changing what the main thread ends up showing. -/
theorem Commit.apply_merge [Inhabited F] [Inhabited P] (c₁ c₂ : Commit F P B) (v : ViewState F P B)
    (hwf : UpdatesTargetViews c₂ (c₁.apply v)) :
    (c₁.merge c₂).apply v = c₂.apply (c₁.apply v) := by
  funext n
  simp only [Commit.apply, Commit.merge]
  cases h₁ : c₁.entries n with
  | none =>
    cases h₂ : c₂.entries n <;> simp [mergeOpt, applyOpt]
  | some a =>
    cases h₂ : c₂.entries n with
    | none => simp [mergeOpt, applyOpt]
    | some b =>
      simp only [mergeOpt, applyOpt]
      apply Entry.apply_merge
      intro hk
      have := hwf n b h₂ hk
      simpa [Commit.apply, h₁, applyOpt] using this

/-! ## The mailbox and generations

The layout queue posts commits in pass order, with strictly increasing
generations. The main thread takes whatever is pending, possibly several
merged commits, and applies it if its generation is newer than the last one
it applied (`NodeHostView.apply`). -/

/-- The view state after applying `cs` in order. -/
def fold [Inhabited F] [Inhabited P] (cs : List (Commit F P B)) (v₀ : ViewState F P B) :
    ViewState F P B :=
  cs.foldl (fun v c => c.apply v) v₀

theorem fold_append [Inhabited F] [Inhabited P] (cs : List (Commit F P B)) (c : Commit F P B)
    (v₀ : ViewState F P B) : fold (cs ++ [c]) v₀ = c.apply (fold cs v₀) := by
  simp [fold, List.foldl_append]

structure Sys (F P B : Type) where
  /-- Commits posted so far, oldest first. -/
  posted : List (Commit F P B)
  /-- Generation of the newest posted commit. -/
  lastPosted : Nat
  pending : Option (Commit F P B)
  /-- The main thread's views. -/
  views : ViewState F P B
  /-- `NodeHostView.lastAppliedGeneration`. -/
  lastApplied : Nat

def Sys.post (s : Sys F P B) (c : Commit F P B) : Sys F P B :=
  { s with
    posted := s.posted ++ [c]
    lastPosted := c.generation
    pending := some (match s.pending with | none => c | some p => p.merge c) }

/-- `take()` followed by `apply(_:)` with its generation guard. -/
def Sys.takeApply [Inhabited F] [Inhabited P] (s : Sys F P B) : Sys F P B :=
  match s.pending with
  | none => s
  | some c =>
    if s.lastApplied < c.generation then
      { s with pending := none, views := c.apply s.views, lastApplied := c.generation }
    else { s with pending := none }

theorem Sys.takeApply_pending [Inhabited F] [Inhabited P] (s : Sys F P B) :
    s.takeApply.pending = none := by
  unfold Sys.takeApply; split
  · assumption
  · split <;> rfl

theorem Sys.takeApply_posted [Inhabited F] [Inhabited P] (s : Sys F P B) :
    s.takeApply.posted = s.posted := by
  unfold Sys.takeApply; split
  · rfl
  · split <;> rfl

inductive Reach [Inhabited F] [Inhabited P] (v₀ : ViewState F P B) : Sys F P B → Prop
  | init : Reach v₀ ⟨[], 0, none, v₀, 0⟩
  /-- The layout queue posts a commit: newer than everything posted, and
  sending updates only for nodes that have views once everything posted so
  far is applied. -/
  | post {s : Sys F P B} (c : Commit F P B) : Reach v₀ s → s.lastPosted < c.generation →
      UpdatesTargetViews c (fold s.posted v₀) → Reach v₀ (s.post c)
  | take {s : Sys F P B} : Reach v₀ s → Reach v₀ s.takeApply

structure MailInv [Inhabited F] [Inhabited P] (v₀ : ViewState F P B) (s : Sys F P B) : Prop where
  views : (match s.pending with | none => s.views | some p => p.apply s.views) = fold s.posted v₀
  applied_le : s.lastApplied ≤ s.lastPosted
  pending_gen : ∀ p, s.pending = some p → p.generation = s.lastPosted ∧ s.lastApplied < p.generation

theorem MailInv.reach [Inhabited F] [Inhabited P] {v₀ : ViewState F P B} {s : Sys F P B}
    (h : Reach v₀ s) : MailInv v₀ s := by
  induction h with
  | init => exact ⟨by simp [fold], Nat.le_refl _, by simp⟩
  | @post s c _ hgen hwf ih =>
    obtain ⟨hv, hle, hpg⟩ := ih
    refine ⟨?_, ?_, ?_⟩
    · simp only [Sys.post]
      rw [fold_append]
      cases hp : s.pending with
      | none => simp only [hp] at hv; simp [hv]
      | some p =>
        simp only [hp] at hv
        rw [Commit.apply_merge, hv]
        rw [hv]; exact hwf
    · simp [Sys.post]; omega
    · intro p hp
      simp only [Sys.post, Option.some.injEq] at hp
      subst hp
      cases hq : s.pending with
      | none => simp [Sys.post]; omega
      | some q => simp [Sys.post, Commit.merge]; omega
  | @take s _ ih =>
    obtain ⟨hv, hle, hpg⟩ := ih
    cases hp : s.pending with
    | none =>
      simp only [Sys.takeApply, hp]
      exact ⟨by simp only [hp] at hv ⊢; exact hv, hle, by simp [hp]⟩
    | some c =>
      obtain ⟨hcg, hlt⟩ := hpg c hp
      simp only [hp] at hv
      simp only [Sys.takeApply, hp, hlt, ite_true]
      exact ⟨hv, by simp; omega, by simp⟩

/-- **Generations**: whenever the main thread takes a commit, its generation
is newer than the last one applied, so the guard in `NodeHostView.apply`
never discards a delta, and no older state overwrites a newer one. -/
theorem take_is_newer [Inhabited F] [Inhabited P] {v₀ : ViewState F P B} {s : Sys F P B}
    (h : Reach v₀ s) {c : Commit F P B} (hp : s.pending = some c) : s.lastApplied < c.generation :=
  ((MailInv.reach h).pending_gen c hp).2

/-- **Nothing is lost or reordered**: once the main thread has taken the
pending commit, its views are exactly those obtained by applying every
posted commit, in order, one by one. -/
theorem views_after_take [Inhabited F] [Inhabited P] {v₀ : ViewState F P B} {s : Sys F P B}
    (h : Reach v₀ s) : s.takeApply.views = fold s.posted v₀ := by
  have := (MailInv.reach (Reach.take h)).views
  simpa [Sys.takeApply_pending, Sys.takeApply_posted] using this

end UltraProofs.Commits
