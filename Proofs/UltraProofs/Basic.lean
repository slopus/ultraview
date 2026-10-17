/-!
# Basics

Nodes are natural numbers. A `Tree` is the pipeline's view of the node
tree: parent links, children lists that agree with them, and a rank that
strictly decreases toward the root (so the parent relation has no cycles).
-/

namespace UltraProofs

abbrev Node := Nat

/-- `f` with the value at `n` replaced by `a`. -/
def upd {α : Type} (f : Node → α) (n : Node) (a : α) : Node → α :=
  fun m => if m = n then a else f m

@[simp] theorem upd_same {α : Type} (f : Node → α) (n : Node) (a : α) : upd f n a n = a := by
  simp [upd]

@[simp] theorem upd_other {α : Type} (f : Node → α) {n m : Node} (a : α) (h : m ≠ n) :
    upd f n a m = f m := by
  simp [upd, h]

theorem upd_apply {α : Type} (f : Node → α) (n m : Node) (a : α) :
    upd f n a m = if m = n then a else f m := rfl

/-- The tree a pass works on. Every node other than `root` has a parent. -/
structure Tree where
  root : Node
  parent : Node → Option Node
  children : Node → List Node
  rank : Node → Nat
  parent_rank : ∀ {c p}, parent c = some p → rank p < rank c
  root_parent : parent root = none
  parent_none : ∀ {n}, parent n = none → n = root
  mem_children : ∀ {c p}, c ∈ children p ↔ parent c = some p
  children_nodup : ∀ p, (children p).Nodup

/-- `Anc t a n`: `a` is `n` or one of its ancestors. -/
inductive Anc (t : Tree) : Node → Node → Prop
  | refl (n : Node) : Anc t n n
  | up {a c p : Node} : t.parent c = some p → Anc t a p → Anc t a c

theorem Anc.rank_le {t : Tree} {a n : Node} (h : Anc t a n) : t.rank a ≤ t.rank n := by
  induction h with
  | refl => exact Nat.le_refl _
  | up hp _ ih => exact Nat.le_trans ih (Nat.le_of_lt (t.parent_rank hp))

theorem Anc.trans {t : Tree} {a b c : Node} (h₁ : Anc t a b) (h₂ : Anc t b c) : Anc t a c := by
  induction h₂ with
  | refl => exact h₁
  | up hp _ ih => exact Anc.up hp ih

theorem Anc.of_parent {t : Tree} {c p : Node} (h : t.parent c = some p) : Anc t p c :=
  Anc.up h (Anc.refl p)

theorem Anc.root (t : Tree) : ∀ n, Anc t t.root n := by
  intro n
  induction h : t.rank n using Nat.strongRecOn generalizing n with
  | _ r ih =>
    cases hp : t.parent n with
    | none => rw [t.parent_none hp]; exact Anc.refl _
    | some p =>
      have := t.parent_rank hp
      exact Anc.up hp (ih (t.rank p) (by omega) p rfl)

/-- The sum of `f` over a list. -/
def sumBy {α : Type} (f : α → Nat) : List α → Nat
  | [] => 0
  | a :: l => f a + sumBy f l

@[simp] theorem sumBy_nil {α : Type} (f : α → Nat) : sumBy f [] = 0 := rfl
@[simp] theorem sumBy_cons {α : Type} (f : α → Nat) (a : α) (l : List α) :
    sumBy f (a :: l) = f a + sumBy f l := rfl

theorem sumBy_append {α : Type} (f : α → Nat) (l₁ l₂ : List α) :
    sumBy f (l₁ ++ l₂) = sumBy f l₁ + sumBy f l₂ := by
  induction l₁ with
  | nil => simp
  | cons a l ih => simp [ih]; omega

/-- Prefer the newer optional value. -/
def pick {α : Type} : Option α → Option α → Option α
  | some a, _ => some a
  | none, o => o

@[simp] theorem pick_some {α : Type} (a : α) (o : Option α) : pick (some a) o = some a := rfl
@[simp] theorem pick_none {α : Type} (o : Option α) : pick none o = o := rfl

theorem getD_pick {α : Type} (n o : Option α) (d : α) :
    (pick n o).getD d = n.getD (o.getD d) := by
  cases n <;> rfl

end UltraProofs
