import UltraProofs.List.Animation

/-!
# Rows mounted while a structural move runs

A pass that inserts, removes or moves rows animates the rows in its window
from where they were to where they settle, on one clock. A row that enters
the window later, while that motion runs (scrolling mounts it), was never
animated. `UltraListView.mountMotion` gives it a copy of a surviving
neighbour's own position track (the witness's, `inheritPosition`) and a
continuation term on the pass's clock that starts at the witness's
continuation plus `δ`, the change in the row's offset from the witness
between the old order and the new. `ContinuationField.delta` computes `δ`
from bands: per identity, how often it lies between the two rows in each
order, times its extent, plus the two rows' top reserves and placements.

* `delta_spec`: whenever `delta` returns a value, it is the row's offset
  from the reference in the old layout less its offset in the new one,
  where a layout places a row at the extents of the rows before it, plus its
  top reserve, plus its placement times its height. The dictionary's
  iteration order is left open (the theorem holds for every order), and so
  is which bands are known: a known band is the row's band in that order,
  and a row with no band in either order is taken to be unchanged, which
  is what the two skips assume.
* `mount_relative`: the mounted row's own motion less the witness's is
  their settled difference plus `δ` times the remaining fraction of the
  pass's clock, at every frame, whatever clock the witness's own track is
  on.
* `mount_moved`: when the witness moves as the pass moved it on that clock,
  and `δ` is the change in their offset, the mounted row is where the pass
  would have put it, at every frame. A row mounted against a mounted row
  satisfies the same hypothesis, so chains of mounts follow by repeating it
  (`delta_telescopes`: their offsets add up).
* `mounted_as_moved`: the two together, with `δ` from `delta`.
-/

namespace UltraProofs.ListMount

open UltraProofs.ListAnimation

theorem if_t {α : Type} {p : Prop} [Decidable p] {a b : α} (h : p) : (if p then a else b) = a := by
  simp [h]
theorem if_f {α : Type} {p : Prop} [Decidable p] {a b : α} (h : ¬p) : (if p then a else b) = b := by
  simp [h]

/-! ## Sums over identities -/

/-- A sum over a list of identities. -/
def total (f : String → Rat) : List String → Rat
  | [] => 0
  | k :: ks => f k + total f ks

/-- How often `k` occurs in `xs`. -/
def occ (k : String) : List String → Rat
  | [] => 0
  | x :: xs => (if k = x then 1 else 0) + occ k xs

theorem total_append (f : String → Rat) (xs ys : List String) :
    total f (xs ++ ys) = total f xs + total f ys := by
  induction xs with
  | nil => simp only [List.nil_append, total]; grind
  | cons x xs ih => simp only [List.cons_append, total, ih]; grind

theorem total_sub (f g : String → Rat) (ks : List String) :
    total (fun k => f k - g k) ks = total f ks - total g ks := by
  induction ks with
  | nil => simp only [total]; grind
  | cons k ks ih => simp only [total, ih]; grind

theorem total_add (f g : String → Rat) (ks : List String) :
    total (fun k => f k + g k) ks = total f ks + total g ks := by
  induction ks with
  | nil => simp only [total]; grind
  | cons k ks ih => simp only [total, ih]; grind

theorem total_mul (c : Rat) (f : String → Rat) (ks : List String) :
    total (fun k => c * f k) ks = c * total f ks := by
  induction ks with
  | nil => simp only [total]; grind
  | cons k ks ih => simp only [total, ih]; grind

theorem total_zero (ks : List String) : total (fun _ => 0) ks = 0 := by
  induction ks with
  | nil => simp [total]
  | cons k ks ih => simp only [total, ih]; grind

theorem total_congr {f g : String → Rat} {ks : List String} (h : ∀ k ∈ ks, f k = g k) :
    total f ks = total g ks := by
  induction ks with
  | nil => simp [total]
  | cons k ks ih =>
    simp only [total]
    rw [h k (List.mem_cons_self ..), ih (fun k' hk' => h k' (List.mem_cons_of_mem _ hk'))]

/-- A key missing from the keys adds nothing. -/
theorem total_single_absent (x : String) (f : String → Rat) {ks : List String} (h : x ∉ ks) :
    total (fun k => (if k = x then 1 else 0) * f k) ks = 0 := by
  induction ks with
  | nil => simp [total]
  | cons k ks ih =>
    have hk : k ≠ x := fun e => h (e ▸ List.mem_cons_self ..)
    have hs : x ∉ ks := fun m => h (List.mem_cons_of_mem _ m)
    simp only [total, if_f hk, ih hs]; grind

/-- Over distinct keys, a key present once adds its value once. -/
theorem total_single (x : String) (f : String → Rat) {ks : List String} (hd : ks.Nodup) (hx : x ∈ ks) :
    total (fun k => (if k = x then 1 else 0) * f k) ks = f x := by
  induction ks with
  | nil => simp at hx
  | cons k ks ih =>
    rw [List.nodup_cons] at hd
    simp only [total]
    by_cases hk : k = x
    · subst hk
      rw [if_t rfl, total_single_absent k f hd.1]; grind
    · have hs : x ∈ ks := by
        rcases List.mem_cons.mp hx with e | m
        · exact absurd e.symm hk
        · exact m
      rw [if_f hk, ih hd.2 hs]; grind

/-- **Regrouping by identity.** Summing each distinct key's count times its
value is summing the list, when every element is a key. -/
theorem regroup (f : String → Rat) {ks : List String} (hd : ks.Nodup) :
    ∀ xs : List String, (∀ x ∈ xs, x ∈ ks) → total (fun k => occ k xs * f k) ks = total f xs
  | [], _ => by
    have e : total (fun k => occ k [] * f k) ks = total (fun _ => 0) ks :=
      total_congr (fun k _ => by simp only [occ]; grind)
    rw [e, total_zero]; rfl
  | x :: xs, h => by
    have e : (fun k => occ k (x :: xs) * f k) =
        fun k => (if k = x then 1 else 0) * f k + occ k xs * f k := by
      funext k; simp only [occ]; grind
    rw [e, total_add, total_single x f hd (h x (List.mem_cons_self ..)),
      regroup f hd xs (fun y hy => h y (List.mem_cons_of_mem _ hy))]
    simp [total]

/-! ## `ContinuationField.delta` -/

/-- `ContinuationField.Band`: a row's height and its reserves above and below. -/
structure Band where
  height : Rat
  top : Rat
  bottom : Rat

/-- `Band.extent`. -/
def Band.extent (b : Band) : Rat := b.top + b.height + b.bottom

/-- `before?.extent ?? 0`. -/
def ext : Option Band → Rat
  | some b => b.extent
  | none => 0

/-- The identities at `a ..< b` of an order. -/
def slice (order : List String) (a b : Nat) : List String := (order.drop a).take (b - a)

/-- `oldRow >= oldReference ? 1 : -1`. -/
def sign (ref row : Nat) : Rat := if ref ≤ row then 1 else -1

/-- `for index in … { coefficients[order[index]] += s }`, the dictionary read as
a function (0 for a missing key). -/
def tally (s : Rat) (m : String → Rat) : List String → String → Rat
  | [] => m
  | x :: xs => tally s (fun k => if k = x then m k + s else m k) xs

/-- One key of `for (identity, coefficient) in coefficients`: skipped when it
lies between the rows equally often in both orders and has no band in either;
`nil` when a nonzero coefficient has no band; else its share. -/
def keyTerm (oldBand newBand : String → Option Band) (cOld cNew : String → Rat) (k : String) :
    Option Rat :=
  if cOld k = cNew k ∧ (oldBand k).isNone ∧ (newBand k).isNone then some 0
  else if (cOld k = 0 ∨ (oldBand k).isSome) ∧ (cNew k = 0 ∨ (newBand k).isSome) then
    some (cOld k * ext (oldBand k) - cNew k * ext (newBand k))
  else none

/-- The loop over the keys: the sum of their shares, `nil` at the first failure. -/
def keySum (oldBand newBand : String → Option Band) (cOld cNew : String → Rat) :
    List String → Option Rat
  | [] => some 0
  | k :: ks =>
    match keyTerm oldBand newBand cOld cNew k, keySum oldBand newBand cOld cNew ks with
    | some t, some r => some (t + r)
    | _, _ => none

/-- The loop over the two rows: a row with no band in either order adds
nothing, one known in a single order fails, else the change in its top
reserve and placed height. -/
def endTerm (before after : Option Band) (c pl : Rat) : Option Rat :=
  match before, after with
  | none, none => some 0
  | some b, some a => some (c * (b.top - a.top + pl * (b.height - a.height)))
  | _, _ => none

/-- `ContinuationField.delta`. `keys` is the dictionary's keys in its
iteration order. -/
def delta (old new : List String) (oldRef oldRow newRef newRow limit : Nat) (keys : List String)
    (oldBand newBand : String → Option Band) (plRef plRow : Rat) : Option Rat :=
  if oldRow - oldRef ≤ limit ∧ oldRef - oldRow ≤ limit ∧ newRow - newRef ≤ limit ∧
      newRef - newRow ≤ limit ∧ oldRef < old.length ∧ oldRow < old.length ∧
      newRef < new.length ∧ newRow < new.length then
    match keySum oldBand newBand
        (tally (sign oldRef oldRow) (fun _ => 0) (slice old (min oldRef oldRow) (max oldRef oldRow)))
        (tally (sign newRef newRow) (fun _ => 0) (slice new (min newRef newRow) (max newRef newRow)))
        keys,
      endTerm (oldBand (old.getD oldRow "")) (newBand (new.getD newRow "")) 1 plRow,
      endTerm (oldBand (old.getD oldRef "")) (newBand (new.getD newRef "")) (-1) plRef with
    | some r, some x, some y => some (r + x + y)
    | _, _, _ => none
  else none

/-- Where a layout places the row at `i`: the extents of the rows before it,
its top reserve, and its placement `pl` times its height. (A placement's
constant part is the view's in both layouts and cancels.) -/
def place (B : String → Band) (order : List String) (i : Nat) (pl : Rat) : Rat :=
  total (fun k => (B k).extent) (order.take i) + (B (order.getD i "")).top
    + pl * (B (order.getD i "")).height

theorem tally_eq (s : Rat) : ∀ (xs : List String) (m : String → Rat),
    tally s m xs = fun k => m k + s * occ k xs
  | [], m => by funext k; simp only [tally, occ]; grind
  | x :: xs, m => by
    rw [tally, tally_eq s xs]
    funext k; simp only [occ]
    by_cases h : k = x
    · simp only [if_t h]; grind
    · simp only [if_f h]; grind

theorem take_slice (order : List String) {a b : Nat} (h : a ≤ b) :
    order.take b = order.take a ++ slice order a b := by
  unfold slice
  have e : b = a + (b - a) := by omega
  conv => lhs; rw [e]
  exact List.take_add ..

/-- **The signed interval is the prefix difference**, in either direction. -/
theorem signed_slice (f : String → Rat) (order : List String) (ref row : Nat) :
    sign ref row * total f (slice order (min ref row) (max ref row)) =
      total f (order.take row) - total f (order.take ref) := by
  by_cases h : ref ≤ row
  · rw [Nat.min_eq_left h, Nat.max_eq_right h, take_slice order h, total_append]
    simp only [sign, if_t h]; grind
  · have h' : row ≤ ref := by omega
    rw [Nat.min_eq_right h', Nat.max_eq_left h', take_slice order h' (b := ref), total_append]
    simp only [sign, if_f h]; grind

section Spec

variable {oldBand newBand : String → Option Band} (Bold Bnew : String → Band)
  (hOld : ∀ k b, oldBand k = some b → b = Bold k)
  (hNew : ∀ k b, newBand k = some b → b = Bnew k)
  (hSame : ∀ k, oldBand k = none → newBand k = none → Bold k = Bnew k)

include hOld hNew hSame in
theorem keyTerm_spec {cOld cNew : String → Rat} {k : String} {t : Rat}
    (h : keyTerm oldBand newBand cOld cNew k = some t) :
    t = cOld k * (Bold k).extent - cNew k * (Bnew k).extent := by
  unfold keyTerm at h
  by_cases h1 : cOld k = cNew k ∧ (oldBand k).isNone ∧ (newBand k).isNone
  · rw [if_t h1] at h
    cases h
    have ho : oldBand k = none := Option.isNone_iff_eq_none.mp h1.2.1
    have hn : newBand k = none := Option.isNone_iff_eq_none.mp h1.2.2
    rw [hSame k ho hn, h1.1]; grind
  · rw [if_f h1] at h
    by_cases h2 : (cOld k = 0 ∨ (oldBand k).isSome) ∧ (cNew k = 0 ∨ (newBand k).isSome)
    · rw [if_t h2] at h
      cases h
      have eo : cOld k * ext (oldBand k) = cOld k * (Bold k).extent := by
        cases ho : oldBand k with
        | none =>
          rcases h2.1 with z | s
          · rw [z]; grind
          · rw [ho] at s; simp at s
        | some b => rw [hOld k b ho]; rfl
      have en : cNew k * ext (newBand k) = cNew k * (Bnew k).extent := by
        cases hn : newBand k with
        | none =>
          rcases h2.2 with z | s
          · rw [z]; grind
          · rw [hn] at s; simp at s
        | some b => rw [hNew k b hn]; rfl
      rw [eo, en]
    · rw [if_f h2] at h; cases h

include hOld hNew hSame in
theorem keySum_spec {cOld cNew : String → Rat} :
    ∀ {ks : List String} {r : Rat}, keySum oldBand newBand cOld cNew ks = some r →
      r = total (fun k => cOld k * (Bold k).extent - cNew k * (Bnew k).extent) ks
  | [], r, h => by simp only [keySum] at h; cases h; rfl
  | k :: ks, r, h => by
    simp only [keySum] at h
    split at h
    · rename_i t r' ht hr
      cases h
      rw [keyTerm_spec Bold Bnew hOld hNew hSame ht, keySum_spec hr]
      rfl
    · cases h

include hOld hNew hSame in
theorem endTerm_spec {X Y : String} {c pl x : Rat} (hXY : X = Y)
    (h : endTerm (oldBand X) (newBand Y) c pl = some x) :
    x = c * ((Bold X).top - (Bnew Y).top + pl * ((Bold X).height - (Bnew Y).height)) := by
  unfold endTerm at h
  split at h
  · rename_i ho hn
    cases h
    subst hXY
    rw [hSame X ho hn]; grind
  · rename_i b a ho hn
    cases h
    rw [hOld X b ho, hNew Y a hn]
  · cases h

include hOld hNew hSame in
/-- **`delta` is the change in the row's offset from the reference.** Whenever
it returns a value, that value is the row's place less the reference's in
the old layout, less the same in the new one. -/
theorem delta_spec {old new keys : List String} {oldRef oldRow newRef newRow limit : Nat}
    {plRef plRow d : Rat} (hNodup : keys.Nodup)
    (hKeys : ∀ k, k ∈ slice old (min oldRef oldRow) (max oldRef oldRow) ∨
      k ∈ slice new (min newRef newRow) (max newRef newRow) → k ∈ keys)
    (hRow : old.getD oldRow "" = new.getD newRow "")
    (hRef : old.getD oldRef "" = new.getD newRef "")
    (h : delta old new oldRef oldRow newRef newRow limit keys oldBand newBand plRef plRow = some d) :
    d = (place Bold old oldRow plRow - place Bold old oldRef plRef)
      - (place Bnew new newRow plRow - place Bnew new newRef plRef) := by
  unfold delta at h
  split at h
  · split at h
    · rename_i r x y hr hx hy
      cases h
      have er := keySum_spec Bold Bnew hOld hNew hSame hr
      have ex := endTerm_spec Bold Bnew hOld hNew hSame hRow hx
      have ey := endTerm_spec Bold Bnew hOld hNew hSame hRef hy
      rw [tally_eq, tally_eq] at er
      rw [total_sub] at er
      have eo := regroup (fun k => (Bold k).extent) hNodup
        (slice old (min oldRef oldRow) (max oldRef oldRow)) (fun k hk => hKeys k (Or.inl hk))
      have en := regroup (fun k => (Bnew k).extent) hNodup
        (slice new (min newRef newRow) (max newRef newRow)) (fun k hk => hKeys k (Or.inr hk))
      have fo : total (fun k => (0 + sign oldRef oldRow *
            occ k (slice old (min oldRef oldRow) (max oldRef oldRow))) * (Bold k).extent) keys =
          sign oldRef oldRow * total (fun k => occ k (slice old (min oldRef oldRow) (max oldRef oldRow)) *
            (Bold k).extent) keys := by
        rw [← total_mul]; apply total_congr; intro k _; grind
      have fn : total (fun k => (0 + sign newRef newRow *
            occ k (slice new (min newRef newRow) (max newRef newRow))) * (Bnew k).extent) keys =
          sign newRef newRow * total (fun k => occ k (slice new (min newRef newRow) (max newRef newRow)) *
            (Bnew k).extent) keys := by
        rw [← total_mul]; apply total_congr; intro k _; grind
      rw [fo, fn, eo, en, signed_slice, signed_slice] at er
      rw [er, ex, ey, ← hRow, ← hRef]
      simp only [place]; grind
    · cases h
  · cases h

end Spec

/-! ## The mounted row -/

/-- A row's own motion as shown: its settled place, its own position track
and its continuation term (the height followers, on their own clocks, are
`ListLayers.composed_seam`'s). -/
def shown (C : Curves) (S : Rat) (own cont : Track) (t : Rat) : Rat :=
  S + own.value C t + cont.value C t

/-- A continuation term on the record's clock: from `c` to 0. -/
def cont (clock : Track) (c : Rat) : Track := { clock with src := c, dst := 0 }

theorem cont_value (C : Curves) (clock : Track) (c t : Rat) :
    (cont clock c).value C t = c * (1 - clock.progress C t) := by
  have hp : (cont clock c).progress C t = clock.progress C t := progress_timing C rfl rfl t
  rw [Track.value, hp]; simp only [cont]; grind

/-- `inheritPosition`'s copy (a new generation, the same ends, start and
transition) shows what the witness's track shows. -/
theorem copy_value (C : Curves) (own : Track) (g : Nat) (t : Rat) :
    ({ own with generation := g } : Track).value C t = own.value C t := by
  have hp : ({ own with generation := g } : Track).progress C t = own.progress C t :=
    progress_timing C rfl rfl t
  simp only [Track.value, hp]

/-- **A mounted row keeps its offset from its witness on the record's
clock.** Its own track is the witness's copy and its continuation starts at
the witness's plus `δ`: at every frame they are apart by their settled
difference plus `δ` times what is left of the clock. -/
theorem mount_relative (C : Curves) (clock own : Track) (g : Nat) (SW SR c δ t : Rat) :
    shown C SR { own with generation := g } (cont clock (c + δ)) t - shown C SW own (cont clock c) t =
      (SR - SW) + δ * (1 - clock.progress C t) := by
  simp only [shown, copy_value, cont_value]; grind

/-- **A mounted row takes the move the pass would have given it.** If the
witness moves from `OW` to `SW` on the record's clock and `δ` is the change
in the row's offset from it, the row moves from `OR` to `SR` on that clock. -/
theorem mount_moved (C : Curves) (clock own : Track) (g : Nat) (OW SW OR SR c δ : Rat)
    (hδ : δ = (OR - OW) - (SR - SW))
    (hW : ∀ t, shown C SW own (cont clock c) t = SW + (OW - SW) * (1 - clock.progress C t))
    (t : Rat) :
    shown C SR { own with generation := g } (cont clock (c + δ)) t =
      SR + (OR - SR) * (1 - clock.progress C t) := by
  have h := mount_relative C clock own g SW SR c δ t
  have hw := hW t
  rw [hδ] at h; grind

/-- A witness the pass moved on the record's clock, with no continuation of
its own, moves from `OW` to `SW` on it. -/
theorem pass_witness (C : Curves) (clock : Track) (g : Nat) (OW SW t : Rat) :
    shown C SW { cont clock (OW - SW) with generation := g } (cont clock 0) t =
      SW + (OW - SW) * (1 - clock.progress C t) := by
  simp only [shown, copy_value, cont_value]; grind

/-- Offset changes add along a chain of witnesses. -/
theorem delta_telescopes (OR OW O0 SR SW S0 : Rat) :
    ((OR - OW) - (SR - SW)) + ((OW - O0) - (SW - S0)) = (OR - O0) - (SR - S0) := by
  grind

/-- **`mountMotion` with `delta`'s value.** A row mounted against a witness
that moves as the pass moved it is where the pass would have put it at every
frame, when the two rows' places on screen are their places in each layout
plus one offset per layout and one constant per view. -/
theorem mounted_as_moved {oldBand newBand : String → Option Band} (Bold Bnew : String → Band)
    (hOld : ∀ k b, oldBand k = some b → b = Bold k)
    (hNew : ∀ k b, newBand k = some b → b = Bnew k)
    (hSame : ∀ k, oldBand k = none → newBand k = none → Bold k = Bnew k)
    {old new keys : List String} {oldRef oldRow newRef newRow limit : Nat}
    {plRef plRow δ : Rat} (hNodup : keys.Nodup)
    (hKeys : ∀ k, k ∈ slice old (min oldRef oldRow) (max oldRef oldRow) ∨
      k ∈ slice new (min newRef newRow) (max newRef newRow) → k ∈ keys)
    (hRow : old.getD oldRow "" = new.getD newRow "")
    (hRef : old.getD oldRef "" = new.getD newRef "")
    (hδ : delta old new oldRef oldRow newRef newRow limit keys oldBand newBand plRef plRow = some δ)
    (C : Curves) (clock own : Track) (g : Nat) (OW SW OR SR c κo κn eR eW : Rat)
    (hOR : OR = place Bold old oldRow plRow + κo + eR) (hOW : OW = place Bold old oldRef plRef + κo + eW)
    (hSR : SR = place Bnew new newRow plRow + κn + eR) (hSW : SW = place Bnew new newRef plRef + κn + eW)
    (hW : ∀ t, shown C SW own (cont clock c) t = SW + (OW - SW) * (1 - clock.progress C t))
    (t : Rat) :
    shown C SR { own with generation := g } (cont clock (c + δ)) t =
      SR + (OR - SR) * (1 - clock.progress C t) := by
  have e := delta_spec Bold Bnew hOld hNew hSame hNodup hKeys hRow hRef hδ
  apply mount_moved C clock own g OW SW OR SR c δ _ hW t
  rw [e, hOR, hOW, hSR, hSW]; grind

/-- A sample: rows `a b c d` with extents 10, 20, 30, 40 (no reserves),
reordered to `a c b d`; the row `d` against the reference `a` has the same
offset (60) in both orders, and `c` against `a` moves up by `b`'s 20. -/
def sampleBand : String → Option Band
  | "a" => some ⟨10, 0, 0⟩
  | "b" => some ⟨20, 0, 0⟩
  | "c" => some ⟨30, 0, 0⟩
  | "d" => some ⟨40, 0, 0⟩
  | _ => none

theorem delta_sample :
    delta ["a", "b", "c", "d"] ["a", "c", "b", "d"] 0 3 0 3 64 ["a", "b", "c"]
        sampleBand sampleBand 0 0 = some 0 ∧
      delta ["a", "b", "c", "d"] ["a", "c", "b", "d"] 0 2 0 1 64 ["a", "b"]
        sampleBand sampleBand 0 0 = some 20 := by
  constructor <;> decide +kernel

end UltraProofs.ListMount
