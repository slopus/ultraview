/-!
# The list window: frames

Models `ListWindow.build`, `ListWindow.rebalance` and `ListWindow.translate`
(ListWindow.swift). Coordinates are exact rationals; the Swift uses `Double`,
so these results hold up to rounding.

A window is a list of rows. `prepend` puts the new row's band bottom on the
first row's band top and `append` puts the new row's band top on the last
row's band bottom, so every window `build` and `rebalance` produce is
*linked*: consecutive indices, each band starting where the previous one
ends, and every row carrying the measurement for its index.

* `build_good`, `rebalance_good`: the frames are stacked and measured.
* `linked_y`: a row's `y` is the anchor's `y` plus the measured extents in
  between, so nothing else can move a row.
* `resize_frames`: when one row's height changes by `Δ` and the anchor keeps
  its position, the rows between the anchor and the resized row keep their
  frames and every row on the far side moves by exactly `Δ`.
* `rebalance_keeps`: scrolling (`rebalance`) never changes a loaded row's
  frame; it only drops rows at the ends and adds new ones.
* `build_top_pinned`: with the loaded top pinned, the content's top edge sits
  exactly at `insets.top + slack`.
-/

namespace UltraProofs.ListWindow

/-- What `measure(index)` returns: the row's height and the space reserved
above and below it. -/
structure Meas where
  height : Rat
  top : Rat
  bottom : Rat

/-- `WindowRow`. -/
structure Row where
  index : Nat
  y : Rat
  height : Rat
  top : Rat
  bottom : Rat

namespace Row
def maxY (r : Row) : Rat := r.y + r.height
def bandTop (r : Row) : Rat := r.y - r.top
def bandBottom (r : Row) : Rat := r.y + r.height + r.bottom
def meas (r : Row) : Meas := ⟨r.height, r.top, r.bottom⟩
end Row

/-- The `row(_:_:_:)` helper in `build`. -/
def mkRow (i : Nat) (y : Rat) (m : Meas) : Row := ⟨i, y, m.height, m.top, m.bottom⟩

abbrev Window := List Row

namespace Window
def minY : Window → Rat
  | [] => 0
  | r :: _ => r.bandTop
def maxY (w : Window) : Rat :=
  match w.getLast? with
  | some r => r.bandBottom
  | none => 0
def height (w : Window) : Rat := w.maxY - w.minY
/-- `range.lowerBound`. -/
def lower : Window → Nat
  | [] => 0
  | r :: _ => r.index
/-- `range.upperBound`. -/
def upper (w : Window) : Nat :=
  match w.getLast? with
  | some r => r.index + 1
  | none => 0
def translate (d : Rat) (w : Window) : Window := w.map fun r => { r with y := r.y + d }
end Window

/-- `ListViewport`, with the insets flattened. -/
structure Viewport where
  width : Rat
  height : Rat
  top : Rat
  left : Rat
  bottom : Rat
  right : Rat

def Viewport.contentWidth (v : Viewport) : Rat := max 0 (v.width - v.left - v.right)
def Viewport.visibleHeight (v : Viewport) : Rat := max 0 (v.height - v.top - v.bottom)

/-! ## The operations -/

/-- `prepend()` in `build` (and the body of `rebalance`'s third loop). -/
def prepend (measure : Nat → Option Meas) : Window → Option Window
  | [] => none
  | first :: rest =>
    if first.index = 0 then none
    else match measure (first.index - 1) with
      | none => none
      | some m => some (mkRow (first.index - 1) (first.bandTop - m.bottom - m.height) m :: first :: rest)

/-- `append()` in `build` (and the body of `rebalance`'s last loop). -/
def append (count : Nat) (measure : Nat → Option Meas) (w : Window) : Option Window :=
  match w.getLast? with
  | none => none
  | some last =>
    if last.index + 1 < count then
      match measure (last.index + 1) with
      | none => none
      | some m => some (w ++ [mkRow (last.index + 1) (last.bandBottom + m.top) m])
    else none

/-- `while cond { if !prepend() { break } }`. Each iteration lowers the first
index, so fuel `count` covers every iteration the Swift loop can make. -/
def prependWhile (measure : Nat → Option Meas) (cond : Window → Bool) : Nat → Window → Window
  | 0, w => w
  | n + 1, w =>
    if cond w then
      match prepend measure w with
      | some w' => prependWhile measure cond n w'
      | none => w
    else w

/-- `while cond { if !append() { break } }`. -/
def appendWhile (count : Nat) (measure : Nat → Option Meas) (cond : Window → Bool) :
    Nat → Window → Window
  | 0, w => w
  | n + 1, w =>
    if cond w then
      match append count measure w with
      | some w' => appendWhile count measure cond n w'
      | none => w
    else w

/-- `pinSlack(index:viewport:)`. -/
def pinSlack (w : Window) (index : Option Nat) (vp : Viewport) : Rat :=
  if w.lower = 0 then
    match index with
    | some i =>
      match w.find? (fun r => r.index = i) with
      | some row =>
        let ext := max 0 (row.height - vp.visibleHeight / 2)
        max 0 (vp.visibleHeight + ext - (row.maxY - w.minY))
      | none => 0
    | none => 0
  else 0

/-- The pin loop in `build`: with the top loaded, append until the pinned
row is loaded or the window fills the visible height. -/
def pinRoom (count : Nat) (measure : Nat → Option Meas) (vp : Viewport) (pinned : Option Nat)
    (w : Window) : Window :=
  if w.lower = 0 then
    match pinned with
    | some p => appendWhile count measure
        (fun w => decide (w.upper ≤ p) && decide (w.height < vp.visibleHeight)) count w
    | none => w
  else w

/-- The placement step in `build`: pin the loaded top to `top`, or apply the
slack baseline and keep a loaded top from sinking below `top`. -/
def place (vp : Viewport) (pinned : Option Nat) (pinsLoadedTop : Bool)
    (slackBaseline : Option Rat) (w : Window) : Window :=
  let slack := pinSlack w pinned vp
  let top := vp.top + slack
  if pinsLoadedTop ∧ w.lower = 0 then w.translate (top - w.minY)
  else
    let w' := match slackBaseline with
      | some b => w.translate (slack - b)
      | none => w
    if w'.lower = 0 ∧ w'.minY > top then w'.translate (top - w'.minY) else w'

/-- The underfill step at the end of `build`, with `top` from before the
placement step. -/
def underfill (count : Nat) (measure : Nat → Option Meas) (vp : Viewport) (margin top : Rat)
    (w : Window) : Window :=
  let bottom := vp.height - vp.bottom
  if w.upper = count ∧ w.maxY < bottom then
    if w.lower = 0 ∧ w.height ≤ vp.visibleHeight then w.translate (top - w.minY)
    else
      let w5 := w.translate (bottom - w.maxY)
      let w6 := prependWhile measure (fun w => decide (w.minY > -margin)) count w5
      if w6.lower = 0 ∧ (w6.height ≤ vp.visibleHeight ∨ w6.minY > top) then
        w6.translate (top - w6.minY)
      else w6
  else w

/-- `ListWindow.build`, branch for branch (split into the steps above). -/
def build (count anchor : Nat) (vp : Viewport) (margin : Rat) (pinned : Option Nat)
    (pinsLoadedTop : Bool) (slackBaseline : Option Rat) (measure : Nat → Option Meas)
    (resolveY : Rat → Rat) : Window :=
  if anchor < count ∧ 0 < vp.contentWidth ∧ 0 < vp.height then
    match measure anchor with
    | none => []
    | some m =>
      let w1 := prependWhile measure (fun w => decide (w.minY > -margin)) count
        [mkRow anchor (resolveY m.height) m]
      let w2 := pinRoom count measure vp pinned w1
      let top := vp.top + pinSlack w2 pinned vp
      let w4 := appendWhile count measure (fun w => decide (w.maxY < vp.height + margin)) count
        (place vp pinned pinsLoadedTop slackBaseline w2)
      underfill count measure vp margin top w4
  else []

/-- The first loop's condition in `rebalance`: `first.bandTop > low`. -/
def headAbove (low : Rat) : Window → Bool
  | [] => false
  | f :: _ => decide (f.bandTop > low)

/-- The last loop's condition in `rebalance`: `last.bandBottom < high`. -/
def lastBelow (high : Rat) (w : Window) : Bool :=
  match w.getLast? with
  | some l => decide (l.bandBottom < high)
  | none => false

/-- `while rows.count > 1 && rows[0].bandBottom < low { rows.removeFirst() }`. -/
def dropFront (low : Rat) : Window → Window
  | r :: s :: rest => if r.bandBottom < low then dropFront low (s :: rest) else r :: s :: rest
  | w => w

/-- `dropFront` from the other end, on the reversed rows. -/
def dropBackRev (high : Rat) : Window → Window
  | r :: s :: rest => if r.bandTop > high then dropBackRev high (s :: rest) else r :: s :: rest
  | w => w

/-- `while rows.count > 1 && rows.last!.bandTop > high { rows.removeLast() }`. -/
def dropBack (high : Rat) (w : Window) : Window := (dropBackRev high w.reverse).reverse

/-- `ListWindow.rebalance`, in the old frame coordinate. -/
def rebalance (count : Nat) (offset viewportHeight margin : Rat) (measure : Nat → Option Meas)
    (w : Window) : Window :=
  let low := offset - margin
  let high := offset + viewportHeight + margin
  let w1 := dropBack high (dropFront low w)
  let w2 := prependWhile measure (headAbove low) count w1
  appendWhile count measure (lastBelow high) count w2

/-! ## Linked windows -/

/-- Two consecutive rows: the next index, and bands that meet. -/
def Next (r s : Row) : Prop := s.index = r.index + 1 ∧ s.bandTop = r.bandBottom

/-- `R` holds between every pair of neighbours. -/
def Chain (R : Row → Row → Prop) : Window → Prop
  | [] => True
  | [_] => True
  | r :: s :: rest => R r s ∧ Chain R (s :: rest)

abbrev Linked : Window → Prop := Chain Next

/-- Every row is in range and carries the measurement for its index. -/
def Measured (count : Nat) (measure : Nat → Option Meas) (w : Window) : Prop :=
  ∀ r ∈ w, r.index < count ∧ measure r.index = some r.meas

def Good (count : Nat) (measure : Nat → Option Meas) (w : Window) : Prop :=
  Linked w ∧ Measured count measure w

def HasIndex (i : Nat) (w : Window) : Prop := ∃ r ∈ w, r.index = i

theorem linked_tail {r : Row} {rest : Window} (h : Linked (r :: rest)) : Linked rest := by
  cases rest with
  | nil => trivial
  | cons s rest => exact h.2

theorem linked_head_le : ∀ {r : Row} {rest : Window}, Linked (r :: rest) → ∀ s ∈ r :: rest,
    r.index ≤ s.index
  | r, [], _, s, hs => by simp at hs; subst hs; exact Nat.le_refl _
  | r, t :: rest, h, s, hs => by
    rcases List.mem_cons.mp hs with hs | hs
    · subst hs; exact Nat.le_refl _
    · have := linked_head_le h.2 s hs
      have := h.1.1
      omega

theorem linked_head_lt {r : Row} {rest : Window} (h : Linked (r :: rest)) :
    ∀ s ∈ rest, r.index < s.index := by
  cases rest with
  | nil => simp
  | cons t rest =>
    intro s hs
    have := linked_head_le h.2 s hs
    have := h.1.1
    omega

/-- Indices identify rows. -/
theorem linked_unique : ∀ {w : Window}, Linked w → ∀ r ∈ w, ∀ s ∈ w, r.index = s.index → r = s
  | [], _, r, hr, _, _, _ => by simp at hr
  | a :: rest, h, r, hr, s, hs, he => by
    have lt := linked_head_lt h
    rcases List.mem_cons.mp hr with hr' | hr' <;> rcases List.mem_cons.mp hs with hs' | hs'
    · rw [hr', hs']
    · have := lt s hs'; rw [hr'] at he; omega
    · have := lt r hr'; rw [hs'] at he; omega
    · exact linked_unique (linked_tail h) r hr' s hs' he

theorem chain_append {R : Row → Row → Prop} : ∀ (l : Window) (n : Row), Chain R l →
    (∀ last, l.getLast? = some last → R last n) → Chain R (l ++ [n])
  | [], _, _, _ => trivial
  | [a], n, _, h => ⟨h a rfl, trivial⟩
  | a :: b :: rest, n, hl, h => by
    refine ⟨hl.1, ?_⟩
    have := chain_append (b :: rest) n hl.2 (fun last hlast => h last (by
      simpa [List.getLast?_cons_cons] using hlast))
    simpa using this

theorem linked_append : ∀ (l : Window) (n : Row), Linked l →
    (∀ last, l.getLast? = some last → Next last n) → Linked (l ++ [n]) :=
  chain_append

theorem chain_of_append {R : Row → Row → Prop} : ∀ (l m : Window), Chain R (l ++ m) →
    Chain R l ∧ Chain R m
  | [], m, h => ⟨trivial, h⟩
  | [a], [], _ => ⟨trivial, trivial⟩
  | [a], b :: m, h => ⟨trivial, h.2⟩
  | a :: b :: l, m, h => by
    have := chain_of_append (b :: l) m h.2
    exact ⟨⟨h.1, this.1⟩, this.2⟩

theorem linked_of_append (l m : Window) (h : Linked (l ++ m)) : Linked l ∧ Linked m :=
  chain_of_append l m h

theorem chain_tail {R : Row → Row → Prop} {r : Row} {rest : Window} (h : Chain R (r :: rest)) :
    Chain R rest := by
  cases rest with
  | nil => trivial
  | cons s rest => exact h.2

/-- Reversing a chain flips the relation. -/
theorem chain_reverse {R : Row → Row → Prop} : ∀ (l : Window), Chain R l →
    Chain (fun a b => R b a) l.reverse
  | [], _ => trivial
  | a :: rest, h => by
    rw [List.reverse_cons]
    refine chain_append _ a (chain_reverse rest (chain_tail h)) (fun last hl => ?_)
    rw [List.getLast?_reverse] at hl
    cases rest with
    | nil => simp at hl
    | cons b rest => simp at hl; subst hl; exact h.1

theorem linked_translate (d : Rat) : ∀ w : Window, Linked w → Linked (w.translate d)
  | [], _ => trivial
  | [_], _ => trivial
  | r :: s :: rest, h => by
    refine ⟨⟨h.1.1, ?_⟩, linked_translate d (s :: rest) h.2⟩
    have := h.1.2
    simp only [Row.bandTop, Row.bandBottom] at this ⊢
    grind

theorem measured_translate {count : Nat} {measure : Nat → Option Meas} (d : Rat) {w : Window}
    (h : Measured count measure w) : Measured count measure (w.translate d) := by
  intro r hr
  simp only [Window.translate, List.mem_map] at hr
  obtain ⟨s, hs, rfl⟩ := hr
  exact h s hs

theorem good_translate {count : Nat} {measure : Nat → Option Meas} (d : Rat) {w : Window}
    (h : Good count measure w) : Good count measure (w.translate d) :=
  ⟨linked_translate d w h.1, measured_translate d h.2⟩

theorem hasIndex_translate {i : Nat} (d : Rat) {w : Window} (h : HasIndex i w) :
    HasIndex i (w.translate d) := by
  obtain ⟨r, hr, he⟩ := h
  exact ⟨{ r with y := r.y + d }, List.mem_map.mpr ⟨r, hr, rfl⟩, he⟩

theorem prepend_good {count : Nat} {measure : Nat → Option Meas} {w w' : Window}
    (h : Good count measure w) (hp : prepend measure w = some w') : Good count measure w' := by
  match w, hp with
  | first :: rest, hp =>
    simp only [prepend] at hp
    split at hp
    · cases hp
    · rename_i hz
      split at hp
      · cases hp
      · rename_i m hm
        cases hp
        have hf := h.2 first (List.mem_cons_self ..)
        refine ⟨⟨⟨by simp [mkRow]; omega, ?_⟩, h.1⟩, ?_⟩
        · simp only [mkRow, Row.bandTop, Row.bandBottom]; grind
        · intro r hr
          rcases List.mem_cons.mp hr with hr | hr
          · subst hr; exact ⟨by simp [mkRow]; omega, by simpa [mkRow, Row.meas] using hm⟩
          · exact h.2 r hr

theorem prepend_hasIndex {measure : Nat → Option Meas} {i : Nat} {w w' : Window}
    (h : HasIndex i w) (hp : prepend measure w = some w') : HasIndex i w' := by
  match w, hp with
  | first :: rest, hp =>
    simp only [prepend] at hp
    split at hp
    · cases hp
    · split at hp
      · cases hp
      · cases hp
        obtain ⟨r, hr, he⟩ := h
        exact ⟨r, List.mem_cons_of_mem _ hr, he⟩

theorem append_good {count : Nat} {measure : Nat → Option Meas} {w w' : Window}
    (h : Good count measure w) (ha : append count measure w = some w') : Good count measure w' := by
  unfold append at ha
  split at ha
  · cases ha
  · rename_i last hlast
    split at ha
    · rename_i hlt
      split at ha
      · cases ha
      · rename_i m hm
        cases ha
        refine ⟨linked_append w _ h.1 (fun l hl => ?_), ?_⟩
        · rw [hlast] at hl; cases hl
          refine ⟨by simp [mkRow], ?_⟩
          simp only [mkRow, Row.bandTop]; grind
        · intro r hr
          rcases List.mem_append.mp hr with hr | hr
          · exact h.2 r hr
          · simp at hr; subst hr
            exact ⟨by simp [mkRow]; omega, by simpa [mkRow, Row.meas] using hm⟩
    · cases ha

theorem append_hasIndex {count : Nat} {measure : Nat → Option Meas} {i : Nat} {w w' : Window}
    (h : HasIndex i w) (ha : append count measure w = some w') : HasIndex i w' := by
  unfold append at ha
  split at ha
  · cases ha
  · split at ha
    · split at ha
      · cases ha
      · cases ha
        obtain ⟨r, hr, he⟩ := h
        exact ⟨r, List.mem_append_left _ hr, he⟩
    · cases ha

theorem prependWhile_good {count : Nat} {measure : Nat → Option Meas} (cond : Window → Bool) :
    ∀ (n : Nat) {w : Window}, Good count measure w → Good count measure (prependWhile measure cond n w)
  | 0, _, h => h
  | n + 1, w, h => by
    simp only [prependWhile]
    split
    · split
      · rename_i w' hp; exact prependWhile_good cond n (prepend_good h hp)
      · exact h
    · exact h

theorem prependWhile_hasIndex {measure : Nat → Option Meas} {i : Nat} (cond : Window → Bool) :
    ∀ (n : Nat) {w : Window}, HasIndex i w → HasIndex i (prependWhile measure cond n w)
  | 0, _, h => h
  | n + 1, w, h => by
    simp only [prependWhile]
    split
    · split
      · rename_i w' hp; exact prependWhile_hasIndex cond n (prepend_hasIndex h hp)
      · exact h
    · exact h

theorem appendWhile_good {count : Nat} {measure : Nat → Option Meas} (cond : Window → Bool) :
    ∀ (n : Nat) {w : Window}, Good count measure w →
      Good count measure (appendWhile count measure cond n w)
  | 0, _, h => h
  | n + 1, w, h => by
    simp only [appendWhile]
    split
    · split
      · rename_i w' ha; exact appendWhile_good cond n (append_good h ha)
      · exact h
    · exact h

theorem appendWhile_hasIndex {count : Nat} {measure : Nat → Option Meas} {i : Nat}
    (cond : Window → Bool) : ∀ (n : Nat) {w : Window}, HasIndex i w →
      HasIndex i (appendWhile count measure cond n w)
  | 0, _, h => h
  | n + 1, w, h => by
    simp only [appendWhile]
    split
    · split
      · rename_i w' ha; exact appendWhile_hasIndex cond n (append_hasIndex h ha)
      · exact h
    · exact h

/-! ## `build` -/

/-- Linked, measured, and holding `anchor`. -/
def Holds (count : Nat) (measure : Nat → Option Meas) (anchor : Nat) (w : Window) : Prop :=
  Good count measure w ∧ HasIndex anchor w

theorem holds_translate {count : Nat} {measure : Nat → Option Meas} {anchor : Nat} (d : Rat)
    {w : Window} (h : Holds count measure anchor w) : Holds count measure anchor (w.translate d) :=
  ⟨good_translate d h.1, hasIndex_translate d h.2⟩

theorem holds_prependWhile {count : Nat} {measure : Nat → Option Meas} {anchor : Nat}
    (cond : Window → Bool) (n : Nat) {w : Window} (h : Holds count measure anchor w) :
    Holds count measure anchor (prependWhile measure cond n w) :=
  ⟨prependWhile_good cond n h.1, prependWhile_hasIndex cond n h.2⟩

theorem holds_appendWhile {count : Nat} {measure : Nat → Option Meas} {anchor : Nat}
    (cond : Window → Bool) (n : Nat) {w : Window} (h : Holds count measure anchor w) :
    Holds count measure anchor (appendWhile count measure cond n w) :=
  ⟨appendWhile_good cond n h.1, appendWhile_hasIndex cond n h.2⟩

theorem holds_pinRoom {count : Nat} {measure : Nat → Option Meas} {anchor : Nat} (vp : Viewport)
    (pinned : Option Nat) {w : Window} (h : Holds count measure anchor w) :
    Holds count measure anchor (pinRoom count measure vp pinned w) := by
  unfold pinRoom
  split
  · split
    · exact holds_appendWhile _ _ h
    · exact h
  · exact h

theorem holds_place {count : Nat} {measure : Nat → Option Meas} {anchor : Nat} (vp : Viewport)
    (pinned : Option Nat) (pinsLoadedTop : Bool) (slackBaseline : Option Rat) {w : Window}
    (h : Holds count measure anchor w) :
    Holds count measure anchor (place vp pinned pinsLoadedTop slackBaseline w) := by
  unfold place
  simp only
  split
  · exact holds_translate _ h
  · cases slackBaseline with
    | none =>
      simp only
      split
      · exact holds_translate _ h
      · exact h
    | some b =>
      simp only
      split
      · exact holds_translate _ (holds_translate _ h)
      · exact holds_translate _ h

theorem holds_underfill {count : Nat} {measure : Nat → Option Meas} {anchor : Nat}
    (vp : Viewport) (margin top : Rat) {w : Window} (h : Holds count measure anchor w) :
    Holds count measure anchor (underfill count measure vp margin top w) := by
  unfold underfill
  simp only
  split
  · split
    · exact holds_translate _ h
    · have h6 := holds_prependWhile (fun w => decide (w.minY > -margin)) count
        (holds_translate (vp.height - vp.bottom - w.maxY) h)
      split
      · exact holds_translate _ h6
      · exact h6
  · exact h

/-- **`build` produces linked, measured frames**, and the anchor is one of
them whenever the window is not empty. -/
theorem build_good (count anchor : Nat) (vp : Viewport) (margin : Rat) (pinned : Option Nat)
    (pinsLoadedTop : Bool) (slackBaseline : Option Rat) (measure : Nat → Option Meas)
    (resolveY : Rat → Rat) :
    let w := build count anchor vp margin pinned pinsLoadedTop slackBaseline measure resolveY
    Good count measure w ∧ (w ≠ [] → HasIndex anchor w) := by
  intro w
  have empty : Good count measure [] ∧(([] : Window) ≠ [] → HasIndex anchor []) :=
    ⟨⟨trivial, by simp [Measured]⟩, fun h => (h rfl).elim⟩
  unfold w build
  split
  · rename_i hg
    split
    · exact empty
    · rename_i m hm
      have h0 : Holds count measure anchor [mkRow anchor (resolveY m.height) m] :=
        ⟨⟨trivial, by
          intro r hr; simp at hr; subst hr
          exact ⟨by simp [mkRow]; omega, by simpa [mkRow, Row.meas] using hm⟩⟩,
         ⟨_, List.mem_singleton_self _, rfl⟩⟩
      have h1 := holds_prependWhile (fun w => decide (w.minY > -margin)) count h0
      have h2 := holds_pinRoom vp pinned h1
      have h4 := holds_appendWhile (fun w => decide (w.maxY < vp.height + margin)) count
        (holds_place vp pinned pinsLoadedTop slackBaseline h2)
      have h := holds_underfill vp margin
        (vp.top + pinSlack (pinRoom count measure vp pinned
          (prependWhile measure (fun w => decide (w.minY > -margin)) count
            [mkRow anchor (resolveY m.height) m])) pinned vp) h4
      exact ⟨h.1, fun _ => h.2⟩
  · exact empty

/-! ## Positions follow from measurements -/

def zeroMeas : Meas := ⟨0, 0, 0⟩

/-- The distance from row `k`'s `y` to row `k + 1`'s: its height, the space it
reserves below, and the space the next row reserves above. -/
def gap (measure : Nat → Option Meas) (k : Nat) : Rat :=
  ((measure k).getD zeroMeas).height + ((measure k).getD zeroMeas).bottom +
    ((measure (k + 1)).getD zeroMeas).top

/-- The distance from row `j`'s `y` to row `j + n`'s. -/
def span (measure : Nat → Option Meas) (j : Nat) : Nat → Rat
  | 0 => 0
  | n + 1 => gap measure j + span measure (j + 1) n

theorem span_add (measure : Nat → Option Meas) :
    ∀ (j n m : Nat), span measure j (n + m) = span measure j n + span measure (j + n) m
  | j, 0, m => by simp only [span, Nat.zero_add, Nat.add_zero]; grind
  | j, n + 1, m => by
    rw [show n + 1 + m = (n + m) + 1 by omega, span, span, span_add measure (j + 1) n m,
      show j + 1 + n = j + (n + 1) by omega]
    grind

theorem measured_tail {count : Nat} {measure : Nat → Option Meas} {r : Row} {rest : Window}
    (h : Measured count measure (r :: rest)) : Measured count measure rest :=
  fun s hs => h s (List.mem_cons_of_mem _ hs)

theorem good_y_head {count : Nat} {measure : Nat → Option Meas} :
    ∀ {a : Row} {rest : Window}, Good count measure (a :: rest) → ∀ s ∈ a :: rest,
      s.y = a.y + span measure a.index (s.index - a.index)
  | a, [], _, s, hs => by simp at hs; subst hs; simp only [Nat.sub_self, span]; grind
  | a, b :: rest, h, s, hs => by
    rcases List.mem_cons.mp hs with hs | hs
    · subst hs; simp only [Nat.sub_self, span]; grind
    · have ih := good_y_head ⟨h.1.2, measured_tail h.2⟩ s hs
      have hle := linked_head_le h.1.2 s hs
      have hn := h.1.1
      have hb : b.index = a.index + 1 := hn.1
      have ma := (h.2 a (List.mem_cons_self ..)).2
      have mb := (h.2 b (List.mem_cons_of_mem _ (List.mem_cons_self ..))).2
      have hgap : gap measure a.index = a.height + a.bottom + b.top := by
        simp only [gap, ma, ← hn.1, mb, Option.getD_some, Row.meas]
      rw [show s.index - a.index = (s.index - b.index) + 1 by omega, span, hgap,
        show a.index + 1 = b.index from hn.1.symm, ih]
      have := hn.2
      simp only [Row.bandTop, Row.bandBottom] at this
      grind

/-- **A row's position is the anchor's plus the measured extents in
between.** Nothing else in a linked window can move a row. -/
theorem linked_y {count : Nat} {measure : Nat → Option Meas} {w : Window}
    (h : Good count measure w) {r s : Row} (hr : r ∈ w) (hs : s ∈ w) (hle : r.index ≤ s.index) :
    s.y = r.y + span measure r.index (s.index - r.index) := by
  match w, h, hr, hs with
  | a :: rest, h, hr, hs =>
    have er := good_y_head h r hr
    have es := good_y_head h s hs
    have ha := linked_head_le h.1 r hr
    rw [es, er, show s.index - a.index = (r.index - a.index) + (s.index - r.index) by omega,
      span_add, show a.index + (r.index - a.index) = r.index by omega]
    grind

/-- `measure'` is `measure` with row `i`'s height changed by `Δ`. -/
def Resized (measure measure' : Nat → Option Meas) (i : Nat) (Δ : Rat) : Prop :=
  (∀ k, k ≠ i → measure' k = measure k) ∧
    ∃ m, measure i = some m ∧ measure' i = some { m with height := m.height + Δ }

theorem gap_resized {measure measure' : Nat → Option Meas} {i : Nat} {Δ : Rat}
    (h : Resized measure measure' i Δ) (k : Nat) :
    gap measure' k = gap measure k + if k = i then Δ else 0 := by
  obtain ⟨same, m, hm, hm'⟩ := h
  by_cases hk : k = i
  · subst hk
    simp only [gap, hm, hm', same (k + 1) (by omega), Option.getD_some, ite_true]
    grind
  · simp only [gap, same k hk, hk, ite_false]
    by_cases hk1 : k + 1 = i
    · rw [hk1, hm, hm']; simp only [Option.getD_some]; grind
    · rw [same (k + 1) hk1]; grind

theorem span_resized {measure measure' : Nat → Option Meas} {i : Nat} {Δ : Rat}
    (h : Resized measure measure' i Δ) : ∀ (j n : Nat),
    span measure' j n = span measure j n + if j ≤ i ∧ i < j + n then Δ else 0
  | j, 0 => by
    simp only [span, show ¬(j ≤ i ∧ i < j + 0) by omega, ite_false]; grind
  | j, n + 1 => by
    rw [span, span, gap_resized h, span_resized h (j + 1) n]
    by_cases h1 : j = i <;> by_cases h2 : j + 1 ≤ i ∧ i < j + 1 + n <;>
      by_cases h3 : j ≤ i ∧ i < j + (n + 1) <;> simp only [h1, h2, h3, ite_true, ite_false] <;>
      first | omega | grind

/-- **Resizing one row.** Two linked windows whose measurements differ only
in row `i`'s height, by `Δ`, and whose anchors sit at the same `y`. When the
anchor is at or above the resized row, the rows down to it keep their frames
and every row below it moves down by exactly `Δ`; when the anchor is below,
the rows up to the resized row move up by exactly `Δ` (it grows upward) and
the rest keep their frames. Heights change only at `i`. -/
theorem resize_frames {count count' : Nat} {measure measure' : Nat → Option Meas} {i : Nat}
    {Δ : Rat} (hres : Resized measure measure' i Δ) {w w' : Window} (hw : Good count measure w)
    (hw' : Good count' measure' w') {a a' : Row} (ha : a ∈ w) (ha' : a' ∈ w')
    (hai : a.index = a'.index) (hay : a.y = a'.y) {r r' : Row} (hr : r ∈ w) (hr' : r' ∈ w')
    (hi : r.index = r'.index) :
    r'.y = r.y + (if a.index ≤ i then (if i < r.index then Δ else 0)
                  else (if r.index ≤ i then -Δ else 0)) ∧
    r'.height = r.height + (if r.index = i then Δ else 0) := by
  constructor
  · by_cases hle : a.index ≤ r.index
    · have e := linked_y hw ha hr hle
      have e' := linked_y hw' ha' hr' (by omega)
      rw [e', ← hai, ← hi, span_resized hres, ← hay, e,
        show a.index + (r.index - a.index) = r.index by omega]
      by_cases c1 : a.index ≤ i <;> by_cases c2 : i < r.index <;>
        simp [c1, c2] <;> first | omega | grind
    · have e := linked_y hw hr ha (by omega)
      have e' := linked_y hw' hr' ha' (by omega)
      rw [← hai, ← hi, span_resized hres, ← hay,
        show r.index + (a.index - r.index) = a.index by omega] at e'
      by_cases c1 : a.index ≤ i <;> by_cases c2 : r.index ≤ i <;>
        simp [c1, c2] at e' ⊢ <;> first | omega | grind
  · have m := (hw.2 r hr).2
    have m' := (hw'.2 r' hr').2
    obtain ⟨same, mi, hm, hm'⟩ := hres
    by_cases c : r.index = i
    · rw [← hi, c, hm'] at m'; rw [c, hm] at m
      simp only [Option.some.injEq, Row.meas] at m m'
      simp only [c, ite_true]
      have := congrArg Meas.height m; have := congrArg Meas.height m'
      simp at *; grind
    · rw [← hi, same _ c, m] at m'
      simp only [Option.some.injEq, Row.meas] at m'
      simp only [c, ite_false]
      have := congrArg Meas.height m'; simp at this; grind

/-! ## `rebalance` keeps frames -/

theorem linked_lt_of_append : ∀ (l m : Window), Linked (l ++ m) → ∀ x ∈ l, ∀ y ∈ m,
    x.index < y.index
  | [], _, _, x, hx, _, _ => by simp at hx
  | a :: l, m, h, x, hx, y, hy => by
    rcases List.mem_cons.mp hx with hx | hx
    · subst hx; exact linked_head_lt h y (List.mem_append_right _ hy)
    · exact linked_lt_of_append l m (linked_tail h) x hx y hy

theorem linked_le_last : ∀ {w : Window} {l : Row}, Linked w → w.getLast? = some l →
    ∀ x ∈ w, x.index ≤ l.index
  | [], _, _, hl, _, _ => by simp at hl
  | [a], l, _, hl, x, hx => by simp at hl hx; subst hl hx; exact Nat.le_refl _
  | a :: b :: rest, l, h, hl, x, hx => by
    rw [List.getLast?_cons_cons] at hl
    have ih := linked_le_last h.2 hl
    rcases List.mem_cons.mp hx with hx | hx
    · subst hx; have := ih b (List.mem_cons_self ..); have := h.1.1; omega
    · exact ih x hx

theorem prepend_linked {measure : Nat → Option Meas} {w w' : Window} (h : Linked w)
    (hp : prepend measure w = some w') :
    ∃ n, w' = n :: w ∧ Linked (n :: w) ∧ ∀ x ∈ w, n.index < x.index := by
  match w, hp with
  | first :: rest, hp =>
    simp only [prepend] at hp
    split at hp
    · cases hp
    · split at hp
      · cases hp
      · cases hp
        refine ⟨_, rfl, ⟨⟨by simp [mkRow]; omega, ?_⟩, h⟩, fun x hx => ?_⟩
        · simp only [mkRow, Row.bandTop, Row.bandBottom]; grind
        · have := linked_head_le h x hx
          simp [mkRow]; omega

/-- The prepend loop only adds rows in front, with smaller indices, and adds
none when its condition fails at the start. -/
theorem prependWhile_front {measure : Nat → Option Meas} (cond : Window → Bool) :
    ∀ (n : Nat) {w : Window}, Linked w → ∃ P, prependWhile measure cond n w = P ++ w ∧
      Linked (P ++ w) ∧ (∀ p ∈ P, ∀ x ∈ w, p.index < x.index) ∧ (cond w = false → P = [])
  | 0, w, h => ⟨[], by simp [prependWhile], by simpa using h, by simp, fun _ => rfl⟩
  | n + 1, w, h => by
    simp only [prependWhile]
    by_cases hc : cond w
    · simp only [hc, ite_true]
      split
      · rename_i w' hp
        obtain ⟨m, rfl, hl, hm⟩ := prepend_linked h hp
        obtain ⟨P, e, hl', hP, _⟩ := prependWhile_front cond n hl
        refine ⟨P ++ [m], by rw [e]; simp, by simpa using hl', fun p hp x hx => ?_,
          fun h' => by simp at h'⟩
        rcases List.mem_append.mp hp with hp | hp
        · exact hP p hp x (List.mem_cons_of_mem _ hx)
        · simp at hp; subst hp; exact hm x hx
      · exact ⟨[], by simp, by simpa using h, by simp, fun _ => rfl⟩
    · simp only [hc]
      exact ⟨[], by simp, by simpa using h, by simp, fun _ => rfl⟩

theorem append_linked {count : Nat} {measure : Nat → Option Meas} {w w' : Window} (h : Linked w)
    (ha : append count measure w = some w') :
    ∃ n, w' = w ++ [n] ∧ Linked w' ∧ ∀ x ∈ w, x.index < n.index := by
  unfold append at ha
  split at ha
  · cases ha
  · rename_i last hlast
    split at ha
    · split at ha
      · cases ha
      · cases ha
        refine ⟨_, rfl, linked_append w _ h (fun l hl => ?_), fun x hx => ?_⟩
        · rw [hlast] at hl; cases hl
          exact ⟨by simp [mkRow], by simp only [mkRow, Row.bandTop]; grind⟩
        · have := linked_le_last h hlast x hx
          simp [mkRow]; omega
    · cases ha

/-- The append loop only adds rows at the end, with larger indices, and adds
none when its condition fails at the start. -/
theorem appendWhile_back {count : Nat} {measure : Nat → Option Meas} (cond : Window → Bool) :
    ∀ (n : Nat) {w : Window}, Linked w → ∃ S, appendWhile count measure cond n w = w ++ S ∧
      Linked (w ++ S) ∧ (∀ s ∈ S, ∀ x ∈ w, x.index < s.index) ∧ (cond w = false → S = [])
  | 0, w, h => ⟨[], by simp [appendWhile], by simpa using h, by simp, fun _ => rfl⟩
  | n + 1, w, h => by
    simp only [appendWhile]
    by_cases hc : cond w
    · simp only [hc, ite_true]
      split
      · rename_i w' ha
        obtain ⟨m, rfl, hl, hm⟩ := append_linked h ha
        obtain ⟨S, e, hl', hS, _⟩ := appendWhile_back cond n hl
        refine ⟨m :: S, by rw [e]; simp, by simpa using hl', fun s hs x hx => ?_,
          fun h' => by simp at h'⟩
        rcases List.mem_cons.mp hs with hs | hs
        · subst hs; exact hm x hx
        · exact hS s hs x (List.mem_append_left _ hx)
      · exact ⟨[], by simp, by simpa using h, by simp, fun _ => rfl⟩
    · simp only [hc]
      exact ⟨[], by simp, by simpa using h, by simp, fun _ => rfl⟩

theorem dropFront_spec (low : Rat) : ∀ (w : Window), Linked w → ∃ pre,
    w = pre ++ dropFront low w ∧ (w ≠ [] → dropFront low w ≠ []) ∧
      (pre = [] ∨ headAbove low (dropFront low w) = false)
  | [] => fun _ => ⟨[], by simp [dropFront], by simp, Or.inl rfl⟩
  | [r] => fun _ => ⟨[], by simp [dropFront], by simp [dropFront], Or.inl rfl⟩
  | r :: s :: rest => fun h => by
    simp only [dropFront]
    by_cases hlt : r.bandBottom < low
    · simp only [hlt, ite_true]
      obtain ⟨pre, e, ne, hd⟩ := dropFront_spec low (s :: rest) h.2
      refine ⟨r :: pre, by rw [List.cons_append, ← e], fun _ => ne (by simp), Or.inr ?_⟩
      rcases hd with hd | hd
      · subst hd
        simp only [List.nil_append] at e
        rw [← e]; simp only [headAbove, decide_eq_false_iff_not]
        have := h.1.2; grind
      · exact hd
    · simp only [hlt, ite_false]
      exact ⟨[], by simp, by simp, Or.inl rfl⟩

theorem dropBackRev_spec (high : Rat) : ∀ (u : Window),
    Chain (fun a b => Next b a) u → ∃ pre, u = pre ++ dropBackRev high u ∧
      (u ≠ [] → dropBackRev high u ≠ []) ∧
      (pre = [] ∨ ∀ x, (dropBackRev high u).head? = some x → high < x.bandBottom)
  | [] => fun _ => ⟨[], by simp [dropBackRev], by simp, Or.inl rfl⟩
  | [r] => fun _ => ⟨[], by simp [dropBackRev], by simp [dropBackRev], Or.inl rfl⟩
  | r :: s :: rest => fun h => by
    simp only [dropBackRev]
    by_cases hgt : r.bandTop > high
    · simp only [hgt, ite_true]
      obtain ⟨pre, e, ne, hd⟩ := dropBackRev_spec high (s :: rest) h.2
      refine ⟨r :: pre, by rw [List.cons_append, ← e], fun _ => ne (by simp), Or.inr ?_⟩
      rcases hd with hd | hd
      · subst hd
        simp only [List.nil_append] at e
        rw [← e]; intro x hx; simp at hx; subst hx
        have := h.1.2; grind
      · exact hd
    · simp only [hgt, ite_false]
      exact ⟨[], by simp, by simp, Or.inl rfl⟩

theorem dropBack_spec (high : Rat) (v : Window) (h : Linked v) : ∃ suf,
    v = dropBack high v ++ suf ∧ (v ≠ [] → dropBack high v ≠ []) ∧
      (suf = [] ∨ lastBelow high (dropBack high v) = false) := by
  obtain ⟨pre, e, ne, hd⟩ := dropBackRev_spec high v.reverse (chain_reverse v h)
  refine ⟨pre.reverse, ?_, fun hv => ?_, ?_⟩
  · have := congrArg List.reverse e
    simp only [List.reverse_reverse, List.reverse_append] at this
    simpa [dropBack] using this
  · simpa [dropBack] using ne (by simpa using hv)
  · rcases hd with hd | hd
    · left; simp [hd]
    · right
      simp only [lastBelow, dropBack, List.getLast?_reverse]
      split
      · rename_i x hx
        have := hd x hx
        simp only [decide_eq_false_iff_not]; grind
      · rfl

theorem headAbove_append (low : Rat) {l m : Window} (hl : l ≠ []) :
    headAbove low (l ++ m) = headAbove low l := by
  cases l with
  | nil => exact absurd rfl hl
  | cons a l => rfl

theorem lastBelow_append (high : Rat) {l m : Window} (hm : m ≠ []) :
    lastBelow high (l ++ m) = lastBelow high m := by
  simp only [lastBelow, List.getLast?_append, Option.or]
  cases e : m.getLast? with
  | none => simp at e; exact absurd e hm
  | some x => rfl

/-- `rebalance` leaves a window made of rows from the old one in the
middle, rows with smaller indices in front only if it dropped none in front,
and rows with larger indices behind only if it dropped none behind. -/
theorem rebalance_shape (count : Nat) (offset vh margin : Rat) (measure : Nat → Option Meas)
    {w : Window} (hw : Linked w) (hne : w ≠ []) :
    ∃ pre mid suf P S, w = pre ++ mid ++ suf ∧ mid ≠ [] ∧
      rebalance count offset vh margin measure w = P ++ mid ++ S ∧
      Linked (P ++ mid ++ S) ∧
      (∀ p ∈ P, ∀ x ∈ mid, p.index < x.index) ∧ (∀ s ∈ S, ∀ x ∈ mid, x.index < s.index) ∧
      (P ≠ [] → pre = []) ∧ (S ≠ [] → suf = []) := by
  simp only [rebalance]
  obtain ⟨pre, e1, ne1, h1⟩ := dropFront_spec (offset - margin) w hw
  have l1 := (linked_of_append pre _ (e1 ▸ hw)).2
  obtain ⟨suf, e2, ne2, h2⟩ := dropBack_spec (offset + vh + margin) _ l1
  have ne1' := ne1 hne
  have ne2' := ne2 ne1'
  have l2 := (linked_of_append _ suf (e2 ▸ l1)).1
  generalize dropFront (offset - margin) w = v at e1 ne1' h1 l1 e2 ne2' l2 h2 ⊢
  generalize dropBack (offset + vh + margin) v = mid at e2 ne2' h2 l2 ⊢
  obtain ⟨P, eP, lP, hP, cP⟩ := prependWhile_front (measure := measure)
    (headAbove (offset - margin)) count l2
  rw [eP]
  obtain ⟨S, eS, lS, hS, cS⟩ := appendWhile_back (count := count) (measure := measure)
    (lastBelow (offset + vh + margin)) count lP
  rw [eS]
  refine ⟨pre, mid, suf, P, S, by rw [e1, e2]; simp, ne2', rfl, lS, hP,
    fun s hs x hx => hS s hs x (List.mem_append_right _ hx), fun hPne => ?_, fun hSne => ?_⟩
  · rcases h1 with h1 | h1
    · exact h1
    · rw [e2, headAbove_append _ ne2'] at h1
      exact absurd (cP h1) hPne
  · rcases h2 with h2 | h2
    · exact h2
    · rw [← lastBelow_append _ ne2' (l := P)] at h2
      exact absurd (cS h2) hSne

/-- **Scrolling never moves a loaded row.** Every row `rebalance` leaves that
was loaded before has exactly the frame it had (`ListWindow`'s "No frame
changes as a function of scrolling"). -/
theorem rebalance_keeps (count : Nat) (offset vh margin : Rat) (measure : Nat → Option Meas)
    {w : Window} (hw : Linked w) :
    ∀ r ∈ w, ∀ r' ∈ rebalance count offset vh margin measure w, r.index = r'.index → r = r' := by
  intro r hr r' hr' he
  have hne : w ≠ [] := by rintro rfl; simp at hr
  obtain ⟨pre, mid, suf, P, S, ew, nm, er, _, hP, hS, cP, cS⟩ :=
    rebalance_shape count offset vh margin measure hw hne
  rw [er] at hr'
  obtain ⟨x, hx⟩ := List.exists_mem_of_ne_nil mid nm
  have hw' := hw
  rw [ew] at hw'
  rcases List.mem_append.mp hr' with hr' | hr'
  · rcases List.mem_append.mp hr' with hr' | hr'
    · -- A new row in front: nothing was dropped there, so it precedes every old row.
      have hpre := cP (List.ne_nil_of_mem hr')
      subst hpre
      simp only [List.nil_append] at ew hw'
      rw [ew] at hr
      rcases List.mem_append.mp hr with hr | hr
      · have := hP r' hr' r hr; omega
      · have := hP r' hr' x hx
        have := linked_lt_of_append mid suf hw' x hx r hr; omega
    · exact linked_unique hw r hr r' (by rw [ew]; simp [hr']) he
  · have hsuf := cS (List.ne_nil_of_mem hr')
    subst hsuf
    simp only [List.append_nil] at ew hw'
    rw [ew] at hr
    rcases List.mem_append.mp hr with hr | hr
    · have := hS r' hr' x hx
      have := linked_lt_of_append pre mid hw' r hr x hx; omega
    · have := hS r' hr' r hr; omega

theorem prependWhile_nil {measure : Nat → Option Meas} (cond : Window → Bool) :
    ∀ n, prependWhile measure cond n [] = []
  | 0 => rfl
  | n + 1 => by simp only [prependWhile, prepend]; split <;> rfl

theorem appendWhile_nil {count : Nat} {measure : Nat → Option Meas} (cond : Window → Bool) :
    ∀ n, appendWhile count measure cond n [] = []
  | 0 => rfl
  | n + 1 => by simp only [appendWhile, append, List.getLast?_nil]; split <;> rfl

theorem good_of_append {count : Nat} {measure : Nat → Option Meas} {l m : Window}
    (h : Good count measure (l ++ m)) : Good count measure l ∧ Good count measure m :=
  ⟨⟨(linked_of_append l m h.1).1, fun r hr => h.2 r (List.mem_append_left _ hr)⟩,
   ⟨(linked_of_append l m h.1).2, fun r hr => h.2 r (List.mem_append_right _ hr)⟩⟩

theorem rebalance_good {count : Nat} (offset vh margin : Rat) {measure : Nat → Option Meas}
    {w : Window} (hw : Good count measure w) :
    Good count measure (rebalance count offset vh margin measure w) := by
  simp only [rebalance]
  obtain ⟨pre, e1, _, _⟩ := dropFront_spec (offset - margin) w hw.1
  have g1 := (good_of_append (e1 ▸ hw : Good count measure (pre ++ _))).2
  obtain ⟨suf, e2, _, _⟩ := dropBack_spec (offset + vh + margin) _ g1.1
  have g2 := (good_of_append (e2 ▸ g1 : Good count measure (_ ++ suf))).1
  exact appendWhile_good _ count (prependWhile_good _ count g2)

/-! ## The loaded top under the top pin -/

theorem translate_ne {w : Window} (d : Rat) (h : w ≠ []) : w.translate d ≠ [] := by
  simpa [Window.translate] using h

theorem translate_minY {w : Window} (d : Rat) (h : w ≠ []) : (w.translate d).minY = w.minY + d := by
  match w, h with
  | a :: rest, _ => simp only [Window.translate, List.map_cons, Window.minY, Row.bandTop]; grind

theorem translate_lower (w : Window) (d : Rat) : (w.translate d).lower = w.lower := by
  cases w <;> rfl

theorem translate_maxY {w : Window} (d : Rat) (h : w ≠ []) : (w.translate d).maxY = w.maxY + d := by
  simp only [Window.maxY, Window.translate, List.getLast?_map]
  cases e : w.getLast? with
  | none => simp at e; exact absurd e h
  | some r => simp only [Option.map_some, Row.bandBottom]; grind

theorem translate_height {w : Window} (d : Rat) (h : w ≠ []) :
    (w.translate d).height = w.height := by
  simp only [Window.height, translate_maxY d h, translate_minY d h]; grind

theorem appendWhile_prefix {count : Nat} {measure : Nat → Option Meas} (cond : Window → Bool) :
    ∀ (n : Nat) (w : Window), ∃ S, appendWhile count measure cond n w = w ++ S
  | 0, w => ⟨[], by simp [appendWhile]⟩
  | n + 1, w => by
    simp only [appendWhile]
    split
    · split
      · rename_i w' ha
        have : ∃ x, w' = w ++ [x] := by
          unfold append at ha
          split at ha
          · cases ha
          · split at ha
            · split at ha
              · cases ha
              · cases ha; exact ⟨_, rfl⟩
            · cases ha
        obtain ⟨x, rfl⟩ := this
        obtain ⟨S, e⟩ := appendWhile_prefix cond n (w ++ [x])
        exact ⟨x :: S, by rw [e]; simp⟩
      · exact ⟨[], by simp⟩
    · exact ⟨[], by simp⟩

theorem prependWhile_suffix {measure : Nat → Option Meas} (cond : Window → Bool) :
    ∀ (n : Nat) (w : Window), ∃ P, prependWhile measure cond n w = P ++ w
  | 0, w => ⟨[], by simp [prependWhile]⟩
  | n + 1, w => by
    simp only [prependWhile]
    split
    · split
      · rename_i w' hp
        have : ∃ x, w' = x :: w := by
          match w, hp with
          | first :: rest, hp =>
            simp only [prepend] at hp
            split at hp
            · cases hp
            · split at hp
              · cases hp
              · cases hp; exact ⟨_, rfl⟩
        obtain ⟨x, rfl⟩ := this
        obtain ⟨P, e⟩ := prependWhile_suffix cond n (x :: w)
        exact ⟨P ++ [x], by rw [e]; simp⟩
      · exact ⟨[], by simp⟩
    · exact ⟨[], by simp⟩

/-- Appending keeps the front: the first row, `minY` and `lower`. -/
theorem appendWhile_front {count : Nat} {measure : Nat → Option Meas} (cond : Window → Bool)
    (n : Nat) {w : Window} (h : w ≠ []) :
    let w' := appendWhile count measure cond n w
    w' ≠ [] ∧ w'.minY = w.minY ∧ w'.lower = w.lower := by
  obtain ⟨S, e⟩ := appendWhile_prefix (count := count) (measure := measure) cond n w
  simp only [e]
  match w, h with
  | a :: rest, _ => exact ⟨by simp, rfl, rfl⟩

/-- At index 0 there is nothing to prepend. -/
theorem prependWhile_at_zero {measure : Nat → Option Meas} (cond : Window → Bool) :
    ∀ (n : Nat) {w : Window}, w ≠ [] → w.lower = 0 → prependWhile measure cond n w = w
  | 0, _, _, _ => rfl
  | n + 1, w, hne, hz => by
    match w, hne with
    | a :: rest, _ =>
      simp only [Window.lower] at hz
      simp only [prependWhile, prepend, hz, ite_true]
      split <;> rfl

/-- **With the loaded top pinned, the content's top edge sits exactly at
`insets.top + slack`** whenever the first prepend loop reaches index 0,
through every later branch of `build` (the downward fill and both underfill
corrections). -/
theorem build_top_pinned (count anchor : Nat) (vp : Viewport) (margin : Rat)
    (pinned : Option Nat) (slackBaseline : Option Rat) (measure : Nat → Option Meas)
    (resolveY : Rat → Rat) (hg : anchor < count ∧ 0 < vp.contentWidth ∧ 0 < vp.height)
    {m : Meas} (hm : measure anchor = some m)
    (hlow : (prependWhile measure (fun w => decide (w.minY > -margin)) count
      [mkRow anchor (resolveY m.height) m]).lower = 0) :
    (build count anchor vp margin pinned true slackBaseline measure resolveY).minY =
      vp.top + pinSlack (pinRoom count measure vp pinned
        (prependWhile measure (fun w => decide (w.minY > -margin)) count
          [mkRow anchor (resolveY m.height) m])) pinned vp := by
  unfold build
  simp only [hg, and_self, ite_true, hm]
  have ne1 : prependWhile measure (fun w => decide (w.minY > -margin)) count
      [mkRow anchor (resolveY m.height) m] ≠ [] := by
    obtain ⟨P, e⟩ := prependWhile_suffix (measure := measure)
      (fun w => decide (w.minY > -margin)) count [mkRow anchor (resolveY m.height) m]
    rw [e]; simp
  generalize prependWhile measure _ count _ = w1 at hlow ne1 ⊢
  have p2 : pinRoom count measure vp pinned w1 ≠ [] ∧
      (pinRoom count measure vp pinned w1).lower = 0 := by
    unfold pinRoom
    simp only [hlow, ite_true]
    cases pinned with
    | none => exact ⟨ne1, hlow⟩
    | some p =>
      have := appendWhile_front (count := count) (measure := measure)
        (fun w => decide (w.upper ≤ p) && decide (w.height < vp.visibleHeight)) count ne1
      exact ⟨this.1, this.2.2.trans hlow⟩
  generalize pinRoom count measure vp pinned w1 = w2 at p2 ⊢
  generalize ht : vp.top + pinSlack w2 pinned vp = top
  have h3 : place vp pinned true slackBaseline w2 ≠ [] ∧
      (place vp pinned true slackBaseline w2).minY = top ∧
      (place vp pinned true slackBaseline w2).lower = 0 := by
    simp only [place, p2.2, and_self, ite_true, ht]
    exact ⟨translate_ne _ p2.1, by rw [translate_minY _ p2.1]; grind,
      by rw [translate_lower]; exact p2.2⟩
  generalize place vp pinned true slackBaseline w2 = w3 at h3
  have h4 := appendWhile_front (count := count) (measure := measure)
    (fun w => decide (w.maxY < vp.height + margin)) count h3.1
  generalize appendWhile count measure _ count w3 = w4 at h4
  have ne4 := h4.1
  have m4 : w4.minY = top := h4.2.1.trans h3.2.1
  have l4 : w4.lower = 0 := h4.2.2.trans h3.2.2
  unfold underfill
  simp only
  split
  · rename_i hu
    split
    · rw [translate_minY _ ne4]; grind
    · rw [prependWhile_at_zero _ count (translate_ne _ ne4) (by rw [translate_lower]; exact l4)]
      have hmin : (w4.translate (vp.height - vp.bottom - w4.maxY)).minY > top := by
        rw [translate_minY _ ne4]; grind
      simp only [translate_lower, l4, hmin, or_true, and_self, ite_true]
      rw [translate_minY _ (translate_ne _ ne4)]; grind
  · exact m4

/-- After a rebalance `handleScroll` moves the container to `nextOrigin` and
shifts the engine by `nextOrigin - minY' - base`; a kept row's screen
position `base + y - offset` does not change. -/
theorem rebalance_screen (base offset nextOrigin minY' y : Rat) :
    let shift := nextOrigin - minY' - base
    (nextOrigin - minY') + y - (offset + shift) = base + y - offset := by
  grind

end UltraProofs.ListWindow
