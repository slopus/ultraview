/-!
# Item diffs: adding, removing and moving rows

Models `ItemDiff.init` (ItemDiff.swift). Rows whose identity survives form
`pairs` (old index, new index) in old order. The diff keeps a longest run of
pairs whose new indices increase (patience sorting with a binary search and
predecessor links), calls those survivors, and moves every other surviving
row. A moved row is also an insert and a delete, as in the Swift.

The proofs are about the search over `vs`, the pairs' new indices in old
order (distinct, because identities are unique):

* `search_spec`: the binary search finds the first tail not below the value.
* `kept_increasing`: the survivors keep their order (their new indices
  increase with their old ones), so no survivor ever has to cross another.
* `kept_longest`: no order-preserving choice of rows keeps more of them, so
  the diff moves as few rows as any diff that keeps the rest in place can.
* `partition`: every surviving row is a survivor or a move, never both.
-/

namespace UltraProofs.ListDiff

def val (vs : List Nat) (i : Nat) : Nat := vs.getD i 0

/-- The binary search in `ItemDiff.init`: the first slot in `low ..< high`
whose tail's value is not below `x`. -/
def search (tv : Nat → Nat) (x low high : Nat) : Nat :=
  if low < high then
    if tv ((low + high) / 2) < x then search tv x ((low + high) / 2 + 1) high
    else search tv x low ((low + high) / 2)
  else low
termination_by high - low

/-- **The search finds the first tail not below `x`**, when the tails' values
increase. -/
theorem search_spec (tv : Nat → Nat) (x n : Nat) (mono : ∀ a b, a < b → b < n → tv a < tv b) :
    ∀ low high, low ≤ high → high ≤ n → (∀ l, l < low → tv l < x) →
      (∀ l, high ≤ l → l < n → x ≤ tv l) →
      search tv x low high ≤ n ∧ (∀ l, l < search tv x low high → tv l < x) ∧
        (∀ l, search tv x low high ≤ l → l < n → x ≤ tv l)
  | low, high, h1, h2, h3, h4 => by
    rw [search]
    split
    · rename_i hlt
      split
      · rename_i hm
        exact search_spec tv x n mono _ high (by omega) h2
          (fun l hl => by
            by_cases e : l = (low + high) / 2
            · subst e; exact hm
            · by_cases e2 : l < low
              · exact h3 l e2
              · have := mono l ((low + high) / 2) (by omega) (by omega); omega)
          h4
      · rename_i hm
        exact search_spec tv x n mono low _ (by omega) (by omega) h3
          (fun l hl hn => by
            by_cases e : l = (low + high) / 2
            · subst e; omega
            · by_cases e2 : high ≤ l
              · exact h4 l e2 hn
              · have := mono ((low + high) / 2) l (by omega) hn; omega)
    · exact ⟨by omega, h3, fun l hl hn => h4 l (by omega) hn⟩
termination_by low high => high - low

/-- The search state. `rank` is ghost state: the slot each element took. -/
structure St where
  tails : List Nat
  preds : Nat → Option Nat
  rank : Nat → Nat

def set {α : Type} (f : Nat → α) (i : Nat) (a : α) : Nat → α := fun j => if j = i then a else f j

def St.tv (vs : List Nat) (st : St) (l : Nat) : Nat := val vs (st.tails.getD l 0)

/-- One iteration of the `for index in pairs.indices` loop. -/
def step (vs : List Nat) (st : St) (i : Nat) : St :=
  let low := search (st.tv vs) (val vs i) 0 st.tails.length
  { tails := if low = st.tails.length then st.tails ++ [i] else st.tails.set low i
    preds := if 0 < low then set st.preds i (some (st.tails.getD (low - 1) 0)) else st.preds
    rank := set st.rank i low }

/-- The loop over the first `n` pairs. -/
def run (vs : List Nat) : Nat → St
  | 0 => ⟨[], fun _ => none, fun _ => 0⟩
  | n + 1 => step vs (run vs n) n

/-- `while cursor >= 0 { kept.insert(cursor); cursor = predecessors[cursor] }`,
with fuel. -/
def walk (preds : Nat → Option Nat) : Nat → Option Nat → List Nat
  | 0, _ => []
  | _ + 1, none => []
  | fuel + 1, some c => c :: walk preds fuel (preds c)

/-- The survivors' positions in `pairs`, last first. -/
def kept (vs : List Nat) : List Nat :=
  let st := run vs vs.length
  walk st.preds vs.length st.tails.getLast?

/-- Each element is before the previous one in `pairs`, with a smaller
value: read backwards, an increasing run. -/
def Desc (vs : List Nat) : List Nat → Prop
  | [] => True
  | [_] => True
  | a :: b :: rest => b < a ∧ val vs b < val vs a ∧ Desc vs (b :: rest)

/-- `c` starts a predecessor chain with `l` more links, each to an earlier
pair with a smaller value. -/
inductive Linked (vs : List Nat) (preds : Nat → Option Nat) : Nat → Nat → Prop
  | base {c : Nat} : preds c = none → Linked vs preds c 0
  | cons {c p l : Nat} : preds c = some p → p < c → val vs p < val vs c → Linked vs preds p l →
      Linked vs preds c (l + 1)

theorem linked_set {vs : List Nat} {preds : Nat → Option Nat} {i : Nat} (a : Option Nat) :
    ∀ {c l}, Linked vs preds c l → c < i → Linked vs (set preds i a) c l
  | c, _, .base h, hc => .base (by simp only [set, Nat.ne_of_lt hc, ite_false]; exact h)
  | c, _, .cons hp hlt hv hl, hc =>
    .cons (by simp only [set, Nat.ne_of_lt hc, ite_false]; exact hp) hlt hv
      (linked_set a hl (by omega))

theorem walk_none (preds : Nat → Option Nat) : ∀ fuel, walk preds fuel none = []
  | 0 => rfl
  | _ + 1 => rfl

theorem walk_linked {vs : List Nat} {preds : Nat → Option Nat} :
    ∀ {c l fuel}, Linked vs preds c l → l < fuel →
      (walk preds fuel (some c)).length = l + 1 ∧ Desc vs (walk preds fuel (some c)) ∧
        (walk preds fuel (some c)).head? = some c
  | c, 0, fuel + 1, .base h, _ => by simp [walk, h, walk_none, Desc]
  | c, l + 1, fuel + 1, .cons (p := p) hp hlt hv hl, hf => by
    have ih := walk_linked (fuel := fuel) hl (by omega)
    have e : walk preds (fuel + 1) (some c) = c :: walk preds fuel (some p) := by simp [walk, hp]
    rw [e]
    obtain ⟨h1, h2, h3⟩ := ih
    generalize walk preds fuel (some p) = w at h1 h2 h3
    refine ⟨by simp [h1], ?_, rfl⟩
    cases w with
    | nil => simp at h3
    | cons b rest =>
      simp only [List.head?_cons, Option.some.injEq] at h3
      subst h3
      exact ⟨hlt, hv, h2⟩

/-- What holds after `n` iterations. -/
structure Inv (vs : List Nat) (n : Nat) (st : St) : Prop where
  len_le : st.tails.length ≤ n
  tails_lt : ∀ l, l < st.tails.length → st.tails.getD l 0 < n
  mono : ∀ a b, a < b → b < st.tails.length → st.tv vs a < st.tv vs b
  rank_lt : ∀ j, j < n → st.rank j < st.tails.length
  rank_tv : ∀ j, j < n → st.tv vs (st.rank j) ≤ val vs j
  rank_inc : ∀ j j', j < j' → j' < n → val vs j < val vs j' → st.rank j < st.rank j'
  preds_none : ∀ j, n ≤ j → st.preds j = none
  linked : ∀ l, l < st.tails.length → Linked vs st.preds (st.tails.getD l 0) l

theorem getD_set_eq (l : List Nat) (k i d : Nat) (h : k < l.length) : (l.set k i).getD k d = i := by
  simp [List.getD_eq_getElem?_getD, h]

theorem getD_set_ne (l : List Nat) (k k' i d : Nat) (h : k' ≠ k) :
    (l.set k i).getD k' d = l.getD k' d := by
  simp [List.getD_eq_getElem?_getD, Ne.symm h]

theorem getD_append_lt (l : List Nat) (k i d : Nat) (h : k < l.length) :
    (l ++ [i]).getD k d = l.getD k d := by
  simp [List.getD_eq_getElem?_getD, List.getElem?_append_left h]

theorem getD_append_eq (l : List Nat) (i d : Nat) : (l ++ [i]).getD l.length d = i := by
  simp [List.getD_eq_getElem?_getD]

theorem inv_step {vs : List Nat} {n : Nat} {st : St} (h : Inv vs n st) :
    Inv vs (n + 1) (step vs st n) := by
  have sp := search_spec (st.tv vs) (val vs n) st.tails.length h.mono 0 st.tails.length
    (Nat.zero_le _) (Nat.le_refl _) (fun _ h => absurd h (Nat.not_lt_zero _)) (fun _ h1 h2 => by omega)
  generalize hlow : search (st.tv vs) (val vs n) 0 st.tails.length = low at sp
  obtain ⟨hle, below, above⟩ := sp
  have len' : (step vs st n).tails.length = if low = st.tails.length then st.tails.length + 1
      else st.tails.length := by
    simp only [step, hlow]; split <;> simp
  -- The new tails, as a function of the slot.
  have tails' : ∀ l, l < (step vs st n).tails.length →
      (step vs st n).tails.getD l 0 = if l = low then n else st.tails.getD l 0 := by
    intro l hl
    rw [len'] at hl
    simp only [step, hlow]
    by_cases e : low = st.tails.length
    · rw [ite_eq_left e] at hl ⊢
      by_cases el : l = st.tails.length
      · rw [ite_eq_left (el.trans e.symm), el, getD_append_eq]
      · rw [ite_eq_right (fun h => el (h.trans e)), getD_append_lt _ _ _ _ (by omega)]
    · rw [ite_eq_right e] at hl ⊢
      by_cases el : l = low
      · rw [ite_eq_left el, el, getD_set_eq _ _ _ _ (by omega)]
      · rw [ite_eq_right el, getD_set_ne _ _ _ _ _ el]
  have tv' : ∀ l, l < (step vs st n).tails.length →
      (step vs st n).tv vs l = if l = low then val vs n else st.tv vs l := by
    intro l hl
    simp only [St.tv]; rw [tails' l hl]; split <;> rfl
  have rank' : ∀ j, (step vs st n).rank j = if j = n then low else st.rank j := by
    intro j; simp only [step, hlow, set]
  have preds' : (step vs st n).preds =
      if 0 < low then set st.preds n (some (st.tails.getD (low - 1) 0)) else st.preds := by
    simp only [step, hlow]
  refine ⟨?_, ?_, ?_, ?_, ?_, ?_, ?_, ?_⟩
  · rw [len']; have := h.len_le; split <;> omega
  · intro l hl
    rw [tails' l hl]
    split
    · omega
    · have := h.tails_lt l (by rw [len'] at hl; split at hl <;> omega); omega
  · intro a b hab hb
    have ha : a < (step vs st n).tails.length := by omega
    rw [tv' a ha, tv' b hb]
    rw [len'] at hb
    by_cases ea : a = low <;> by_cases eb : b = low <;> simp only [ea, eb, ite_true, ite_false]
    · omega
    · -- `b` is after the slot: its value is at least the new one, strictly above the old one.
      have hb' : b < st.tails.length := by split at hb <;> omega
      have := above low (by omega) (by split at hb <;> omega)
      have := h.mono low b (by omega) hb'
      omega
    · have := below a (by omega); omega
    · exact h.mono a b hab (by split at hb <;> omega)
  · intro j hj
    rw [rank', len']
    split
    · split <;> omega
    · have := h.rank_lt j (by omega); split <;> omega
  · intro j hj
    rw [rank']
    by_cases ej : j = n
    · simp only [ej, ite_true]
      rw [tv' low (by rw [len']; split <;> omega)]; simp
    · simp only [ej, ite_false]
      have hr := h.rank_lt j (by omega)
      rw [tv' (st.rank j) (by rw [len']; split <;> omega)]
      by_cases er : st.rank j = low
      · simp only [er, ite_true]
        have := above low (by omega) (by omega)
        have := h.rank_tv j (by omega)
        rw [er] at this; omega
      · simp only [er, ite_false]; exact h.rank_tv j (by omega)
  · intro j j' hjj hj' hv
    rw [rank', rank']
    by_cases ej' : j' = n
    · simp only [ej', ite_true, show ¬j = n by omega, ite_false]
      have := h.rank_tv j (by omega)
      have hr := h.rank_lt j (by omega)
      by_cases c : low ≤ st.rank j
      · have := above (st.rank j) c hr; subst ej'; omega
      · omega
    · simp only [ej', show ¬j = n by omega, ite_false]
      exact h.rank_inc j j' hjj (by omega) hv
  · intro j hj
    rw [preds']
    split
    · simp [set, show ¬j = n by omega, h.preds_none j (by omega)]
    · exact h.preds_none j (by omega)
  · intro l hl
    rw [tails' l hl, preds']
    by_cases el : l = low
    · subst el
      simp only [ite_true]
      by_cases z : 0 < l
      · simp only [z, ite_true]
        have hp := h.tails_lt (l - 1) (by omega)
        have := below (l - 1) (by omega)
        have lk := h.linked (l - 1) (by omega)
        rw [show l = (l - 1) + 1 by omega]
        exact .cons (by simp [set]) hp this (linked_set _ lk hp)
      · simp only [show l = 0 by omega]
        exact .base (h.preds_none n (Nat.le_refl _))
    · simp only [el, ite_false]
      have hl' : l < st.tails.length := by rw [len'] at hl; split at hl <;> omega
      have lk := h.linked l hl'
      split
      · exact linked_set _ lk (h.tails_lt l hl')
      · exact lk

theorem inv_run (vs : List Nat) : ∀ n, Inv vs n (run vs n)
  | 0 => ⟨by simp [run], by simp [run], by simp [run], fun _ h => absurd h (Nat.not_lt_zero _),
      fun _ h => absurd h (Nat.not_lt_zero _), fun _ _ _ h => absurd h (Nat.not_lt_zero _),
      fun _ _ => rfl, by simp [run]⟩
  | n + 1 => inv_step (inv_run vs n)

/-- **The survivors keep their order.** Read backwards (old order), the kept
pairs have increasing old and new indices, and there are as many as tails. -/
theorem kept_increasing (vs : List Nat) :
    Desc vs (kept vs) ∧ (kept vs).length = (run vs vs.length).tails.length := by
  have h := inv_run vs vs.length
  simp only [kept]
  generalize run vs vs.length = st at h
  cases e : st.tails.getLast? with
  | none =>
    have : st.tails = [] := List.getLast?_eq_none_iff.mp e
    cases hn : vs.length <;> simp [walk, Desc, this]
  | some c =>
    have hne : st.tails ≠ [] := by intro h'; simp [h'] at e
    have hlen : 0 < st.tails.length := List.length_pos_iff.mpr hne
    have hc : st.tails.getD (st.tails.length - 1) 0 = c := by
      rw [List.getLast?_eq_getElem?] at e
      simp [List.getD_eq_getElem?_getD, e]
    have lk := h.linked (st.tails.length - 1) (by omega)
    rw [hc] at lk
    have w := walk_linked (fuel := vs.length) lk (by have := h.len_le; omega)
    exact ⟨w.2.1, by rw [w.1]; omega⟩

/-- Along a backwards-increasing run, ranks strictly decrease. -/
theorem rank_desc {vs : List Nat} {n : Nat} {st : St} (h : Inv vs n st) :
    ∀ (ps : List Nat) (a : Nat), Desc vs (a :: ps) → (∀ p ∈ a :: ps, p < n) →
      ps.length ≤ st.rank a
  | [], _, _, _ => Nat.zero_le _
  | b :: ps, a, hd, hn => by
    have ih := rank_desc h ps b hd.2.2 (fun p hp => hn p (List.mem_cons_of_mem _ hp))
    have := h.rank_inc b a hd.1 (hn a (List.mem_cons_self ..)) hd.2.1
    simp only [List.length_cons]; omega

/-- **No order-preserving choice keeps more rows.** Any run of pairs with
increasing old and new indices is no longer than the survivors, so the diff
moves the fewest rows of any diff that leaves the others in order. -/
theorem kept_longest (vs : List Nat) (ps : List Nat) (hd : Desc vs ps)
    (hn : ∀ p ∈ ps, p < vs.length) : ps.length ≤ (kept vs).length := by
  rw [(kept_increasing vs).2]
  have h := inv_run vs vs.length
  match ps, hd, hn with
  | [], _, _ => exact Nat.zero_le _
  | a :: ps, hd, hn =>
    have := rank_desc h ps a hd hn
    have := h.rank_lt a (hn a (List.mem_cons_self ..))
    simp only [List.length_cons]; omega

/-- `pairs`: for each old index whose identity is in the new list, the new
index, in old order. -/
def pairs {α : Type} [DecidableEq α] (old new : List α) : List (Nat × Nat) :=
  (List.range old.length).filterMap fun i =>
    (old[i]?).bind fun id => (new.idxOf? id).map fun j => (i, j)

/-- Survivors and moves: the pairs at kept positions, and the rest. -/
def survivors {α : Type} [DecidableEq α] (old new : List α) : List (Nat × Nat) :=
  let ps := pairs old new
  (List.range ps.length).filterMap fun k => if k ∈ kept (ps.map (·.2)) then ps[k]? else none

def moves {α : Type} [DecidableEq α] (old new : List α) : List (Nat × Nat) :=
  let ps := pairs old new
  (List.range ps.length).filterMap fun k => if k ∈ kept (ps.map (·.2)) then none else ps[k]?

/-- **Every surviving row is a survivor or a move, never both.** -/
theorem partition {α : Type} [DecidableEq α] (old new : List α) (k : Nat)
    (hk : k < (pairs old new).length) :
    let ps := pairs old new
    (ps[k]? ∈ (survivors old new).map some ∨ ps[k]? ∈ (moves old new).map some) ∧
      ¬(k ∈ kept (ps.map (·.2)) ∧ k ∉ kept (ps.map (·.2))) := by
  intro ps
  refine ⟨?_, fun h => h.2 h.1⟩
  have hs : ps[k]? = some ps[k] := List.getElem?_eq_getElem hk
  by_cases e : k ∈ kept (ps.map (·.2))
  · left
    simp only [survivors, List.mem_map, List.mem_filterMap, List.mem_range]
    exact ⟨ps[k], ⟨k, hk, by simp [ps, e, hs]⟩, hs.symm⟩
  · right
    simp only [moves, List.mem_map, List.mem_filterMap, List.mem_range]
    exact ⟨ps[k], ⟨k, hk, by simp [ps, e, hs]⟩, hs.symm⟩

end UltraProofs.ListDiff
