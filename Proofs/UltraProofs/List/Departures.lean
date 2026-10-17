/-!
# Departure blocks

Models the ledger of departure blocks (`DepartureLedger`,
DepartureGeometry.swift): the wrappers that carry removed rows while they
fade out. A block rides a witness: the top or bottom edge of a live row, or
an edge of another block (its carrier). Each pass the list relinks blocks
whose witness moved or left (`updateGhosts`) and moves every block to its
resolved target (`targets`), animating the move on the pass's timing. A
block is collected once its members have finished fading and no block
rides it.

Blocks are named by number, rows too (the Swift uses `UInt64` and the row
identity). Coordinates are rationals.

* `link_inv`, `insert_inv`, `promote_inv`, `drop_inv`, `modify_inv`,
  `inv_run`: after every sequence of inserts, links, promotions, collections
  and witness-keeping updates (roots, seals, shifts, member counts), no
  chain of carriers is a cycle, and every block a block rides exists.
  `walk_sound` is why: `link` accepts a carrier only when following the
  carrier's own chain ends without reaching the block.
* `no_cycle`, `stable`, `resolves`: no chain comes back to a block on it,
  so `targets`' guard against a block already on the stack never fires;
  and every block's target is fixed after finitely many steps of the
  recursion, so its memo holds the recursion's value.
* `weld_block`, `weld_row`, `keeps_root`: a block's riding edge lands on its
  carrier's resolved edge, or on its witness row's edge; with no witness, or
  a witness row outside the window, it stays where it is. With
  `ListPass.ghost_follows_witness`, a block then moves with what it rides at
  every frame of the pass.
* `collect_empties`: once every member has finished, collecting leaves no
  block, so no wrapper outlives its rows.
-/

namespace UltraProofs.ListDepartures

open Classical

inductive Edge
  | top
  | bottom
deriving DecidableEq

inductive Witness
  | unresolved
  | row (r : Nat) (e : Edge)
  | block (t : Nat) (e : Edge)
deriving DecidableEq

def Witness.target : Witness → Option Nat
  | .block t _ => some t
  | _ => none

structure Block where
  root : Rat
  localTop : Rat
  localBottom : Rat
  edge : Edge
  witness : Witness
  anchored : Bool
  isOpen : Bool
  members : Int

abbrev Ledger := Nat → Option Block

def upd (L : Ledger) (k : Nat) (a : Option Block) : Ledger := fun k' => if k' = k then a else L k'

@[simp] theorem upd_same (L : Ledger) (k : Nat) (a : Option Block) : upd L k a k = a := by simp [upd]
theorem upd_other (L : Ledger) {k k' : Nat} (a : Option Block) (h : k' ≠ k) : upd L k a k' = L k' := by
  simp [upd, h]

/-! ## Chains of carriers -/

/-- The block `x` rides, if it rides one. -/
def next (L : Ledger) (x : Nat) : Option Nat := (L x).bind (·.witness.target)

/-- `k` steps along the chain from `x`; `none` once it reaches a block that
rides no block. -/
def iter (L : Ledger) : Nat → Nat → Option Nat
  | 0, x => some x
  | k + 1, x => (next L x).bind (iter L k)

def Terminates (L : Ledger) (x : Nat) : Prop := ∃ k, iter L k x = none

/-- Every block a block rides exists. -/
def Closed (L : Ledger) : Prop := ∀ x t, next L x = some t → L t ≠ none

structure Inv (L : Ledger) : Prop where
  closed : Closed L
  acyclic : ∀ x, Terminates L x

theorem iter_succ_none {L : Ledger} : ∀ {k x}, iter L k x = none → iter L (k + 1) x = none
  | 0, _, h => by simp [iter] at h
  | k + 1, x, h => by
    simp only [iter] at h ⊢
    cases hn : next L x with
    | none => rfl
    | some t => simp only [hn, Option.bind_some] at h ⊢; exact iter_succ_none h

theorem iter_le_none {L : Ledger} {k m x : Nat} (hkm : k ≤ m) (h : iter L k x = none) : iter L m x = none := by
  induction m with
  | zero => rw [Nat.le_zero.mp hkm] at h; exact h
  | succ m ih =>
    by_cases e : k = m + 1
    · subst e; exact h
    · exact iter_succ_none (ih (by omega))

theorem iter_add (L : Ledger) : ∀ a b x, iter L (a + b) x = (iter L a x).bind (iter L b)
  | 0, b, x => by simp [iter]
  | a + 1, b, x => by
    rw [show a + 1 + b = (a + b) + 1 by omega]
    simp only [iter]
    cases next L x with
    | none => rfl
    | some n => simp only [Option.bind_some]; exact iter_add L a b n

/-- **A finite chain never comes back to where it started**, so a recursion
along it never meets a block already on its stack. -/
theorem no_cycle {L : Ledger} {x : Nat} (h : Terminates L x) {k : Nat} (hk : 0 < k) :
    iter L k x ≠ some x := by
  intro e
  obtain ⟨m, hm⟩ := h
  have rep : ∀ j, iter L (k * j) x = some x := by
    intro j; induction j with
    | zero => rfl
    | succ j ih => rw [Nat.mul_succ, iter_add, ih, Option.bind_some, e]
  have := iter_le_none (m := k * m) (by
    calc m = 1 * m := (Nat.one_mul m).symm
      _ ≤ k * m := Nat.mul_le_mul_right m hk) hm
  rw [rep] at this; cases this

/-- **Changing only `id`'s carrier keeps every chain finite once `id`'s is.** -/
theorem extend {L L' : Ledger} {id : Nat} (agree : ∀ x, x ≠ id → next L' x = next L x)
    (hid : Terminates L' id) : ∀ m x, iter L m x = none → Terminates L' x
  | 0, _, h => by simp [iter] at h
  | m + 1, x, h => by
    by_cases e : x = id
    · subst e; exact hid
    · cases hn : next L x with
      | none => exact ⟨1, by simp [iter, agree x e, hn]⟩
      | some n =>
        simp only [iter, hn, Option.bind_some] at h
        obtain ⟨k, hk⟩ := extend agree hid m n h
        exact ⟨k + 1, by simp [iter, agree x e, hn, hk]⟩

/-- A chain that never reaches `id` is the same after `id`'s carrier changes. -/
theorem avoid {L L' : Ledger} {id : Nat} (agree : ∀ x, x ≠ id → next L' x = next L x) :
    ∀ k x, (∀ j, j < k → iter L j x ≠ some id) → iter L' k x = iter L k x
  | 0, _, _ => rfl
  | k + 1, x, h => by
    have hx : x ≠ id := fun e => h 0 (by omega) (by simp [iter, e])
    simp only [iter, agree x hx]
    cases hn : next L x with
    | none => rfl
    | some n =>
      simp only [Option.bind_some]
      exact avoid agree k n fun j hj => by
        have := h (j + 1) (by omega); simp only [iter, hn, Option.bind_some] at this; exact this

/-! ## `link`'s cycle check -/

/-- `link`'s loop: from `c`, give up on a block already seen, accept at a
block that rides no block. The Swift's loop has no bound; here running out
of `fuel` rejects. A Swift link that accepts after `n` steps is this one
with fuel `n + 1`, and one that rejects is this one with any fuel, so every
link the Swift makes is a `link` below. -/
def walk (L : Ledger) : List Nat → Nat → Nat → Bool
  | _, 0, _ => false
  | seen, f + 1, c =>
    if c ∈ seen then false
    else match next L c with
      | none => true
      | some n => walk L (c :: seen) f n

/-- **An accepted walk ends without meeting a seen block.** -/
theorem walk_sound (L : Ledger) : ∀ f seen c, walk L seen f c = true →
    ∃ k, iter L k c = none ∧ ∀ j, j < k → ∀ x ∈ seen, iter L j c ≠ some x
  | 0, _, _, h => by simp [walk] at h
  | f + 1, seen, c, h => by
    simp only [walk] at h
    split at h
    · cases h
    · rename_i hc
      cases hn : next L c with
      | none =>
        refine ⟨1, by simp [iter, hn], fun j hj x hx e => ?_⟩
        have : j = 0 := by omega
        subst this; simp only [iter, Option.some.injEq] at e; subst e; exact hc hx
      | some n =>
        rw [hn] at h
        obtain ⟨k, hk, hav⟩ := walk_sound L f (c :: seen) n h
        refine ⟨k + 1, by simp [iter, hn, hk], fun j hj x hx e => ?_⟩
        cases j with
        | zero => simp only [iter, Option.some.injEq] at e; subst e; exact hc hx
        | succ j =>
          simp only [iter, hn, Option.bind_some] at e
          exact hav j (by omega) x (List.mem_cons_of_mem _ hx) e

/-! ## Operations -/

/-- `link(_:to:edge:)`; `none` where it returns false and leaves the ledger. -/
def link (L : Ledger) (fuel id : Nat) (w : Witness) (e : Edge) : Option Ledger :=
  match L id with
  | none => none
  | some b =>
    if b.anchored = true ∧ w ≠ .unresolved then none
    else match w with
      | .block t _ =>
        if L t ≠ none ∧ t ≠ id ∧ walk L [id] fuel t = true then
          some (upd L id (some { b with witness := w, edge := e }))
        else none
      | _ => some (upd L id (some { b with witness := w, edge := e }))

/-- `insert(_:)`: a new block, riding nothing. The Swift's precondition is
that the id is new; the list takes it from a counter. -/
def insert (L : Ledger) (id : Nat) (root localBottom : Rat) (members : Int) : Ledger :=
  if L id = none then
    upd L id (some ⟨root, 0, localBottom, .top, .unresolved, false, true, members⟩)
  else L

/-- `promoteToViewport(_:offset:)`. -/
def promote (L : Ledger) (id : Nat) (offset : Rat) : Ledger :=
  match L id with
  | none => L
  | some b => upd L id (some { b with root := b.root - offset, anchored := true, witness := .unresolved })

/-- One removal of `collect()`'s loop: a block whose members have finished
and that no block rides. -/
noncomputable def drop (L : Ledger) (id : Nat) : Ledger :=
  match L id with
  | none => L
  | some b => if b.members ≤ 0 ∧ ∀ x, next L x ≠ some id then upd L id none else L

/-- Every update that keeps each block's witness: `setRoot`, `seal`,
`shift(by:)`, `finishMember`, `addMember` (`seal` is `close`). -/
def modify (L : Ledger) (f : Nat → Block → Block) : Ledger := fun x => (L x).map (f x)

def setRoot (id : Nat) (r : Rat) (x : Nat) (b : Block) : Block := if x = id then { b with root := r } else b
def close (id : Nat) (x : Nat) (b : Block) : Block := if x = id then { b with isOpen := false } else b
def shift (d : Rat) (_ : Nat) (b : Block) : Block := if b.anchored then b else { b with root := b.root + d }
def finish (id : Nat) (x : Nat) (b : Block) : Block := if x = id then { b with members := b.members - 1 } else b
def addMember (id : Nat) (lt lb : Rat) (x : Nat) (b : Block) : Block :=
  if x = id then { b with members := b.members + 1, localTop := min b.localTop lt, localBottom := max b.localBottom lb }
  else b

/-! ## Each operation keeps the invariant -/

theorem next_upd_other (L : Ledger) {id x : Nat} (a : Option Block) (h : x ≠ id) :
    next (upd L id a) x = next L x := by
  simp [next, upd_other L a h]

/-- Replacing `id`'s entry with one that rides no block. -/
theorem free_inv {L : Ledger} (hs : Inv L) {id : Nat} {a : Option Block}
    (ha : (a.bind (·.witness.target)) = none) (keep : L id ≠ none → a ≠ none) : Inv (upd L id a) := by
  have agree : ∀ x, x ≠ id → next (upd L id a) x = next L x := fun x h => next_upd_other L a h
  have hid : Terminates (upd L id a) id := ⟨1, by simp [iter, next, ha]⟩
  refine ⟨fun x t hxt => ?_, fun x => ?_⟩
  · by_cases e : x = id
    · subst e; simp [next, ha] at hxt
    · rw [agree x e] at hxt
      have := hs.closed x t hxt
      by_cases et : t = id
      · subst et; simpa using keep this
      · rwa [upd_other L a et]
  · obtain ⟨m, hm⟩ := hs.acyclic x
    exact extend agree hid m x hm

theorem insert_inv {L : Ledger} (hs : Inv L) (id : Nat) (root lb : Rat) (members : Int) :
    Inv (insert L id root lb members) := by
  unfold insert
  split
  · exact free_inv hs (by simp [Witness.target]) (by simp)
  · exact hs

theorem promote_inv {L : Ledger} (hs : Inv L) (id : Nat) (offset : Rat) : Inv (promote L id offset) := by
  unfold promote
  split
  · exact hs
  · exact free_inv hs (by simp [Witness.target]) (by simp)

theorem drop_inv {L : Ledger} (hs : Inv L) (id : Nat) : Inv (drop L id) := by
  unfold drop
  split
  · exact hs
  · split
    · rename_i hg
      have agree : ∀ x, x ≠ id → next (upd L id none) x = next L x := fun x h => next_upd_other L none h
      have hid : Terminates (upd L id none) id := ⟨1, by simp [iter, next]⟩
      refine ⟨fun x t hxt => ?_, fun x => ?_⟩
      · by_cases e : x = id
        · subst e; simp [next] at hxt
        · rw [agree x e] at hxt
          have et : t ≠ id := fun et => hg.2 x (et ▸ hxt)
          rw [upd_other L none et]; exact hs.closed x t hxt
      · obtain ⟨m, hm⟩ := hs.acyclic x
        exact extend agree hid m x hm
    · exact hs

theorem modify_inv {L : Ledger} (hs : Inv L) (f : Nat → Block → Block)
    (hf : ∀ x b, (f x b).witness = b.witness) : Inv (modify L f) := by
  have hn : ∀ x, next (modify L f) x = next L x := by
    intro x; simp only [next, modify]; cases L x <;> simp [hf]
  have hi : ∀ k x, iter (modify L f) k x = iter L k x := by
    intro k; induction k with
    | zero => intro x; rfl
    | succ k ih => intro x; simp only [iter, hn]; cases next L x <;> simp [ih]
  refine ⟨fun x t hxt => ?_, fun x => ?_⟩
  · rw [hn] at hxt
    have := hs.closed x t hxt
    simp only [modify]; cases h : L t
    · exact absurd h this
    · simp
  · obtain ⟨k, hk⟩ := hs.acyclic x; exact ⟨k, by rw [hi, hk]⟩

/-- **A link keeps every chain finite and every carrier present.** -/
theorem link_inv {L L' : Ledger} (hs : Inv L) {fuel id : Nat} {w : Witness} {e : Edge}
    (h : link L fuel id w e = some L') : Inv L' := by
  unfold link at h
  split at h
  · cases h
  · rename_i b hb
    split at h
    · cases h
    · cases w with
      | unresolved =>
        cases h; exact free_inv hs (by simp [Witness.target]) (by simp)
      | row r e' =>
        cases h; exact free_inv hs (by simp [Witness.target]) (by simp)
      | block t e' =>
        simp only at h
        split at h
        · rename_i hg
          obtain ⟨ht, hti, hw⟩ := hg
          cases h
          generalize hL' : upd L id (some { b with witness := .block t e', edge := e }) = L'
          have agree : ∀ x, x ≠ id → next L' x = next L x := fun x hx => by
            rw [← hL']; exact next_upd_other L _ hx
          have hnid : next L' id = some t := by rw [← hL']; simp [next, Witness.target]
          obtain ⟨k, hk, hav⟩ := walk_sound L fuel [id] t hw
          have ht' : iter L' k t = none := by
            rw [avoid agree k t (fun j hj => hav j hj id (List.mem_singleton_self _)), hk]
          have hid : Terminates L' id := ⟨k + 1, by simp [iter, hnid, ht']⟩
          refine ⟨fun x u hxu => ?_, fun x => ?_⟩
          · by_cases ex : x = id
            · subst ex; rw [hnid] at hxu; cases hxu
              rw [← hL', upd_other L _ hti]; exact ht
            · rw [agree x ex] at hxu
              have := hs.closed x u hxu
              rw [← hL']
              by_cases eu : u = id
              · subst eu; simp
              · rwa [upd_other L _ eu]
          · obtain ⟨m, hm⟩ := hs.acyclic x
            exact extend agree hid m x hm
        · cases h

inductive Op
  | insert (id : Nat) (root localBottom : Rat) (members : Int)
  | link (fuel id : Nat) (w : Witness) (e : Edge)
  | promote (id : Nat) (offset : Rat)
  | drop (id : Nat)
  | setRoot (id : Nat) (r : Rat)
  | close (id : Nat)
  | shift (d : Rat)
  | finish (id : Nat)
  | addMember (id : Nat) (lt lb : Rat)

noncomputable def step (L : Ledger) : Op → Ledger
  | .insert id r lb m => insert L id r lb m
  | .link fuel id w e => (link L fuel id w e).getD L
  | .promote id o => promote L id o
  | .drop id => drop L id
  | .setRoot id r => modify L (setRoot id r)
  | .close id => modify L (close id)
  | .shift d => modify L (shift d)
  | .finish id => modify L (finish id)
  | .addMember id lt lb => modify L (addMember id lt lb)

noncomputable def run (L : Ledger) (ops : List Op) : Ledger := ops.foldl step L

def empty : Ledger := fun _ => none

theorem inv_empty : Inv empty := ⟨fun _ _ h => by simp [next, empty] at h, fun _ => ⟨1, by simp [iter, next, empty]⟩⟩

theorem step_inv {L : Ledger} (hs : Inv L) : ∀ op, Inv (step L op)
  | .insert id r lb m => insert_inv hs id r lb m
  | .link fuel id w e => by
    simp only [step]
    cases h : link L fuel id w e with
    | none => exact hs
    | some L' => exact link_inv hs h
  | .promote id o => promote_inv hs id o
  | .drop id => drop_inv hs id
  | .setRoot id r => modify_inv hs _ fun x b => by unfold setRoot; split <;> rfl
  | .close id => modify_inv hs _ fun x b => by unfold close; split <;> rfl
  | .shift d => modify_inv hs _ fun x b => by unfold shift; split <;> rfl
  | .finish id => modify_inv hs _ fun x b => by unfold finish; split <;> rfl
  | .addMember id lt lb => modify_inv hs _ fun x b => by unfold addMember; split <;> rfl

/-- **Every sequence of ledger operations keeps the invariant**: no chain of
carriers is a cycle and no block rides a missing one. -/
theorem inv_run : ∀ (ops : List Op) {L : Ledger}, Inv L → Inv (run L ops)
  | [], _, h => h
  | op :: ops, _, h => inv_run ops (step_inv h op)

/-! ## Targets -/

def own (b : Block) : Rat := if b.edge = .top then b.localTop else b.localBottom
def carrierEdge (c : Block) (e : Edge) : Rat := if e = .top then c.localTop else c.localBottom
def rowEdge (p : Rat × Rat) (e : Edge) : Rat := if e = .top then p.1 else p.2

/-- The boundary a witness names, with `rec` the targets of other blocks. -/
def bound (L : Ledger) (rows : Nat → Option (Rat × Rat)) (rec : Nat → Rat) : Witness → Option Rat
  | .unresolved => none
  | .row r e => (rows r).map (rowEdge · e)
  | .block t e => (L t).map fun c => rec t + carrierEdge c e

/-- `targets(rows:)`'s `solve`, with `f` steps of recursion; at 0 it
returns what the Swift's guard against revisiting a block returns. -/
def solve (L : Ledger) (rows : Nat → Option (Rat × Rat)) : Nat → Nat → Rat
  | 0, id => ((L id).map (·.root)).getD 0
  | f + 1, id => match L id with
    | none => 0
    | some b => ((bound L rows (solve L rows f) b.witness).map (· - own b)).getD b.root

/-- **Targets settle**: once the chain from a block has ended, more
recursion changes nothing. -/
theorem stable (L : Ledger) (rows : Nat → Option (Rat × Rat)) :
    ∀ k id, iter L k id = none → ∀ f, k ≤ f → solve L rows f id = solve L rows k id
  | 0, _, h, _, _ => by simp [iter] at h
  | k + 1, id, h, f, hf => by
    obtain ⟨f, rfl⟩ : ∃ f', f = f' + 1 := ⟨f - 1, by omega⟩
    simp only [solve]
    cases hb : L id with
    | none => rfl
    | some b =>
      simp only
      cases hw : b.witness with
      | unresolved => rfl
      | row r e => rfl
      | block t e =>
        have hn : next L id = some t := by simp [next, hb, hw, Witness.target]
        simp only [iter, hn, Option.bind_some] at h
        simp only [bound, stable L rows k t h f (by omega)]

theorem resolves {L : Ledger} (hs : Inv L) (rows : Nat → Option (Rat × Rat)) (id : Nat) :
    ∃ k, ∀ f, k ≤ f → solve L rows f id = solve L rows k id := by
  obtain ⟨k, hk⟩ := hs.acyclic id
  exact ⟨k, stable L rows k id hk⟩

/-- **A block's riding edge lands on its carrier's edge**, both at their
settled targets. -/
theorem weld_block {L : Ledger} (hs : Inv L) (rows : Nat → Option (Rat × Rat)) {id t : Nat} {e : Edge}
    {b : Block} (hb : L id = some b) (hw : b.witness = .block t e) :
    ∃ c, L t = some c ∧ ∃ k, ∀ f, k ≤ f →
      solve L rows f id + own b = solve L rows f t + carrierEdge c e := by
  have hn : next L id = some t := by simp [next, hb, hw, Witness.target]
  obtain ⟨c, hc⟩ := Option.ne_none_iff_exists'.mp (hs.closed id t hn)
  obtain ⟨k, hk⟩ := hs.acyclic t
  refine ⟨c, hc, k + 1, fun f hf => ?_⟩
  obtain ⟨f, rfl⟩ : ∃ f', f = f' + 1 := ⟨f - 1, by omega⟩
  have hid : solve L rows (f + 1) id = solve L rows f t + carrierEdge c e - own b := by
    simp only [solve, hb, hw, bound, hc, Option.map_some, Option.getD_some]
  rw [hid, stable L rows k t hk f (by omega), stable L rows k t hk (f + 1) (by omega)]
  grind

/-- **A block on a live row's edge lands on it.** -/
theorem weld_row (L : Ledger) (rows : Nat → Option (Rat × Rat)) {id r : Nat} {e : Edge} {b : Block}
    {p : Rat × Rat} (hb : L id = some b) (hw : b.witness = .row r e) (hp : rows r = some p) (f : Nat) :
    solve L rows (f + 1) id + own b = rowEdge p e := by
  simp only [solve, hb, hw, bound, hp, Option.map_some, Option.getD_some]
  grind

/-- **With no witness, or a witness row outside the window, a block stays.** -/
theorem keeps_root (L : Ledger) (rows : Nat → Option (Rat × Rat)) {id : Nat} {b : Block} (hb : L id = some b)
    (hw : b.witness = .unresolved ∨ ∃ r e, b.witness = .row r e ∧ rows r = none) (f : Nat) :
    solve L rows (f + 1) id = b.root := by
  rcases hw with hw | ⟨r, e, hw, hr⟩
  · simp [solve, hb, hw, bound]
  · simp [solve, hb, hw, bound, hr]

/-! ## Collection -/

theorem uniform {L : Ledger} : ∀ ks : List Nat, (∀ x ∈ ks, Terminates L x) →
    ∃ K, ∀ x ∈ ks, iter L K x = none
  | [], _ => ⟨0, by simp⟩
  | x :: ks, h => by
    obtain ⟨k, hk⟩ := h x (List.mem_cons_self ..)
    obtain ⟨K, hK⟩ := uniform ks fun y hy => h y (List.mem_cons_of_mem _ hy)
    refine ⟨max k K, fun y hy => ?_⟩
    rcases List.mem_cons.mp hy with rfl | hy
    · exact iter_le_none (Nat.le_max_left ..) hk
    · exact iter_le_none (Nat.le_max_right ..) (hK y hy)

/-- **Once every member has finished, collecting leaves no block.** When
`collect()`'s loop stops, every block whose members have finished is
ridden by another; with every member finished, that would need a cycle. -/
theorem collect_empties {L : Ledger} (hs : Inv L) (ks : List Nat) (hdom : ∀ x, L x ≠ none → x ∈ ks)
    (finished : ∀ x b, L x = some b → b.members ≤ 0)
    (stopped : ∀ x b, L x = some b → b.members ≤ 0 → ∃ z, next L z = some x) : ∀ x, L x = none := by
  intro x0
  cases h0 : L x0 with
  | none => rfl
  | some b0 =>
    exfalso
    obtain ⟨K, hK⟩ := uniform ks fun x _ => hs.acyclic x
    have chain : ∀ j, ∃ y, L y ≠ none ∧ iter L j y = some x0 := by
      intro j; induction j with
      | zero => exact ⟨x0, by simp [h0], rfl⟩
      | succ j ih =>
        obtain ⟨y, hy, hj⟩ := ih
        obtain ⟨b, hb⟩ := Option.ne_none_iff_exists'.mp hy
        obtain ⟨z, hz⟩ := stopped y b hb (finished y b hb)
        have hzl : L z ≠ none := fun e => by simp [next, e] at hz
        exact ⟨z, hzl, by simp [iter, hz, hj]⟩
    obtain ⟨y, hy, hj⟩ := chain K
    rw [hK y (hdom y hy)] at hj
    cases hj

end UltraProofs.ListDepartures
