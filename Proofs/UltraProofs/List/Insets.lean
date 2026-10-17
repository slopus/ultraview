import UltraProofs.List.Window

/-!
# The inset-only path

`UltraListView.updateViewportInsets` (UltraListView.swift) handles an inset
change that touches nothing else without a full pass. It keeps the window,
moves the engine offset, recomputes the edges and starts the viewport track
from where the content was. It returns early only for that case, so it must
leave the content where the full pass would. Offsets are in the window's
frame coordinate: a row is drawn at `base + y - offset`.

* `cheap_eq_full`: the full pass, which rebuilds the window rigidly in new
  coordinates (`ListPass.rigid`) and then clamps to the new edges, puts every
  row on screen exactly where `cheapFixed` does: the old settled offset, less
  the inset change plus the pin-slack change, clamped to the new edges, plus
  the old overscroll.
* `cheapFixed_settled`: settled content stays settled, so nothing bounces.
* `uncompensated_keeps_offset`: without compensation the offset is left alone
  (overscroll, if any, is the engine's to return).
* `cheap_swift_overscrolls` (a gap in the Swift at `76bac32`): moving by the
  inset change alone ignores the slack and the edges. A short pinned list
  gaining a 100-point top inset ends 100 points past its top edge, and
  content at its end losing a 252-point top inset ends 252 points past it;
  `cheapFixed` leaves both where they were.
* `inset_drops_shown` (a gap in the Swift at `76bac32`): `rebalance` after
  the change keeps only rows near the final offset. The viewport track still
  shows the content where it was, so a change larger than the preload margin
  drops rows on screen at its start: with 50-point rows and a 252-point
  inset, row 7 at 350. `rebalanceIn_keeps_covered`, `track_in_hull`: covering
  the offsets the track shows at its progress bounds keeps every row shown at
  any time of the track. `sum_covers`: with the engine in flight too, the
  covered interval must be the sum of the two ranges, not their hull
  (`hull_misses`).
-/

namespace UltraProofs.ListInsets

open UltraProofs.ListWindow

/-- `ScrollEdges`. -/
structure Edges where
  minimum : Option Rat
  maximum : Option Rat
deriving DecidableEq

/-- `ScrollEdges.clamped`: `min(max(value, low), max(low, maximum ?? ∞))`. -/
def clamp (e : Edges) (x : Rat) : Rat :=
  let a := match e.minimum with | some l => max x l | none => x
  match e.maximum with
  | some h => min a (match e.minimum with | some l => max l h | none => h)
  | none => a

def Edges.shift (e : Edges) (k : Rat) : Edges := ⟨e.minimum.map (· + k), e.maximum.map (· + k)⟩

theorem clamp_shift (e : Edges) (k x : Rat) : clamp (e.shift k) (x + k) = clamp e x + k := by
  cases hl : e.minimum <;> cases hh : e.maximum <;>
    simp only [clamp, Edges.shift, hl, hh, Option.map_some, Option.map_none] <;> grind

theorem clamp_idem (e : Edges) (x : Rat) : clamp e (clamp e x) = clamp e x := by
  cases hl : e.minimum <;> cases hh : e.maximum <;> simp only [clamp, hl, hh] <;> grind

/-- `ListWindow.edges(origin:count:viewport:pinnedIndex:)`, with the
container origin written as `base + minY`. -/
def edgesAt (w : Window) (base : Rat) (count : Nat) (vp : Viewport) (pinned : Option Nat) : Edges :=
  if w = [] then ⟨some 0, some 0⟩
  else ⟨if w.lower = 0 then some (base + w.minY - vp.top - pinSlack w pinned vp) else none,
    if w.upper = count then some (base + w.maxY + vp.bottom - vp.height) else none⟩

theorem translate_upper (w : Window) (d : Rat) : (w.translate d).upper = w.upper := by
  simp only [Window.upper, Window.translate, List.getLast?_map]
  cases w.getLast? <;> rfl

theorem pinSlack_translate (w : Window) (d : Rat) (pinned : Option Nat) (vp : Viewport)
    (h : w ≠ []) : pinSlack (w.translate d) pinned vp = pinSlack w pinned vp := by
  have hf : ∀ i, ((fun r => decide (r.index = i)) ∘ fun r : Row => { r with y := r.y + d }) =
      fun r => decide (r.index = i) := fun i => by funext r; rfl
  simp only [pinSlack, translate_lower, translate_minY d h]
  split
  · cases pinned with
    | none => rfl
    | some i =>
      simp only [Window.translate, List.find?_map, hf]
      cases w.find? (fun r => r.index = i) with
      | none => rfl
      | some row => simp only [Option.map_some, Row.maxY]; grind
  · rfl

/-- **Edges move with a rigid window**: drawn at `base - d`, a window
translated by `d` has the same edges. -/
theorem edgesAt_translate (w : Window) (base d : Rat) (count : Nat) (vp : Viewport)
    (pinned : Option Nat) : edgesAt (w.translate d) (base - d) count vp pinned = edgesAt w base count vp pinned := by
  by_cases h : w = []
  · subst h; rfl
  · have h' := translate_ne d h
    simp only [edgesAt, h, h', ite_false, translate_lower, translate_upper, pinSlack_translate w d _ _ h,
      translate_minY d h, translate_maxY d h]
    congr 1 <;> split <;> grind

/-- The screen move the full pass's `resolveY` gives the anchor with
`compensatesInsetChange`: the inset change plus the pin-slack change. -/
def move (w : Window) (vp vp' : Viewport) (pinned : Option Nat) : Rat :=
  vp'.top - vp.top + (pinSlack w pinned vp' - pinSlack w pinned vp)

/-- The inset-only path as proposed: the old settled offset less the move,
clamped to the new edges, plus the old overscroll (the full pass's own
terms). -/
def cheapFixed (e e' : Edges) (offset mv : Rat) : Rat :=
  clamp e' (clamp e offset - mv) + (offset - clamp e offset)

/-- The inset-only path at `76bac32`: the offset less the inset change. -/
def cheapSwift (vp vp' : Viewport) (offset : Rat) : Rat := offset - (vp'.top - vp.top)

/-- The full pass for an inset change, in its own coordinates: it rebuilds
the window as `w.translate d` drawn at `base'`, puts the anchor `mv` below
its old settled screen position, then clamps to the new window's edges and
adds the old overscroll. -/
def fullPass (w : Window) (base base' d : Rat) (count : Nat) (vp vp' : Viewport)
    (pinned : Option Nat) (anchorY offset : Rat) : Rat :=
  let e := edgesAt w base count vp pinned
  let settled := clamp e offset
  let screenY := base + anchorY - settled + move w vp vp' pinned
  let unclamped := base' + (anchorY + d) - screenY
  clamp (edgesAt (w.translate d) base' count vp' pinned) unclamped + (offset - settled)

/-- **The inset-only path matches the full pass.** Every row of the window is
drawn at the same screen position after either: the full pass, which
rebuilds the window rigidly in its own coordinates, and `cheapFixed`, which
keeps the window. -/
theorem cheap_eq_full (w : Window) (hne : w ≠ []) (base base' d : Rat) (count : Nat)
    (vp vp' : Viewport) (pinned : Option Nat) (anchorY offset : Rat) (r : Row) :
    (base' + (r.y + d)) - fullPass w base base' d count vp vp' pinned anchorY offset =
      (base + r.y) - cheapFixed (edgesAt w base count vp pinned) (edgesAt w base count vp' pinned)
        offset (move w vp vp' pinned) := by
  simp only [fullPass, cheapFixed]
  have e := edgesAt_translate w (base' + d) d count vp' pinned
  rw [show base' + d - d = base' by grind] at e
  have hk : edgesAt (w.translate d) base' count vp' pinned =
      (edgesAt w base count vp' pinned).shift (base' + d - base) := by
    rw [e]
    simp only [edgesAt, hne, ite_false, Edges.shift, Edges.mk.injEq]
    constructor <;> split <;> simp <;> grind
  rw [hk]
  have := clamp_shift (edgesAt w base count vp' pinned) (base' + d - base)
    (clamp (edgesAt w base count vp pinned) offset - move w vp vp' pinned)
  rw [show base' + (anchorY + d) - (base + anchorY - clamp (edgesAt w base count vp pinned) offset +
      move w vp vp' pinned) = clamp (edgesAt w base count vp pinned) offset - move w vp vp' pinned +
      (base' + d - base) by grind, this]
  grind

/-- **Settled content stays settled**: with no overscroll before, there is
none after, so the change starts no bounce. -/
theorem cheapFixed_settled (e e' : Edges) (offset mv : Rat) (h : clamp e offset = offset) :
    clamp e' (cheapFixed e e' offset mv) = cheapFixed e e' offset mv := by
  simp only [cheapFixed, h]
  rw [show offset - offset = (0 : Rat) by grind, Rat.add_zero]
  exact clamp_idem e' _

/-- Without `compensates`, the inset-only path leaves the offset alone: the
content keeps its place in the frame, and overscroll is the engine's to
return. -/
def cheapUncompensated (offset : Rat) : Rat := offset

theorem uncompensated_keeps_offset (offset : Rat) : cheapUncompensated offset = offset := rfl

/-! ## The Swift's inset-only path overscrolls -/

/-- A 320 × 400 viewport with a top inset. -/
def phone (top : Rat) : Viewport := ⟨320, 400, top, 0, 0, 0⟩

/-- Three rows of 100, the last pinned, at the top of the frame. -/
def short : Window := (List.range 3).map fun i => mkRow i (i * 100) ⟨100, 0, 0⟩

/-- Rows 12 to 19 of a 20-row list of 100, loaded at the end. -/
def tail : Window := ((List.range 8).map (· + 12)).map fun i => mkRow i (i * 100) ⟨100, 0, 0⟩

/-- **The Swift's inset-only path overscrolls (at `76bac32`).** A short list
with its last row pinned rests at its top edge, `-100` (the slack). A 100-point
top inset uses up the slack, so the edge stays at `-100`, but the Swift
moves the offset to `-200`: 100 points past the edge, with the pinned row's
bottom at 500 instead of 400. Content resting at its end (offset 1600) that
loses a 252-point top inset is moved to 1852, 252 past its end. `cheapFixed`
leaves both where they were. -/
theorem cheap_swift_overscrolls :
    let e := edgesAt short 0 3 (phone 0) (some 2)
    let e' := edgesAt short 0 3 (phone 100) (some 2)
    let mv := move short (phone 0) (phone 100) (some 2)
    let f := edgesAt tail 0 20 (phone 252) none
    let f' := edgesAt tail 0 20 (phone 0) none
    let mv' := move tail (phone 252) (phone 0) none
    clamp e (-100) = -100 ∧ e'.minimum = some (-100) ∧
    cheapSwift (phone 0) (phone 100) (-100) = -200 ∧ clamp e' (-200) = -100 ∧
    cheapFixed e e' (-100) mv = -100 ∧
    clamp f 1600 = 1600 ∧ cheapSwift (phone 252) (phone 0) 1600 = 1852 ∧ clamp f' 1852 = 1600 ∧
    cheapFixed f f' 1600 mv' = 1600 := by
  decide +kernel

/-! ## Rows shown during the viewport track -/

/-- `ListWindow.rebalance` at `76bac32`, with the loop bounds `low` and
`high` it computes from the offset, the covered offsets and the margin, and
fuel standing for its row budget (the theorems hold for any fuel). -/
def rebalanceIn (count : Nat) (low high : Rat) (measure : Nat → Option Meas) (pf af : Nat)
    (w : Window) : Window :=
  let w1 := dropBack high (dropFront low w)
  appendWhile count measure (lastBelow high) af (prependWhile measure (headAbove low) pf w1)

theorem dropFront_keeps (low : Rat) : ∀ (w : Window) (r : Row), r ∈ w → low ≤ r.bandBottom →
    r ∈ dropFront low w
  | [], _, h, _ => by simp at h
  | [x], _, h, _ => by simpa [dropFront] using h
  | x :: y :: rest, r, h, hb => by
    simp only [dropFront]
    split
    · rename_i hx
      have : r ≠ x := by rintro rfl; grind
      exact dropFront_keeps low (y :: rest) r (by simp_all) hb
    · exact h

theorem dropBackRev_keeps (high : Rat) : ∀ (w : Window) (r : Row), r ∈ w → r.bandTop ≤ high →
    r ∈ dropBackRev high w
  | [], _, h, _ => by simp at h
  | [x], _, h, _ => by simpa [dropBackRev] using h
  | x :: y :: rest, r, h, hb => by
    simp only [dropBackRev]
    split
    · rename_i hx
      have : r ≠ x := by rintro rfl; grind
      exact dropBackRev_keeps high (y :: rest) r (by simp_all) hb
    · exact h

theorem dropBack_keeps (high : Rat) (w : Window) (r : Row) (h : r ∈ w) (hb : r.bandTop ≤ high) :
    r ∈ dropBack high w := by
  simp only [dropBack, List.mem_reverse]
  exact dropBackRev_keeps high w.reverse r (by simpa using h) hb

/-- **`rebalance` keeps every row inside its bounds**, whatever it adds. -/
theorem rebalanceIn_keeps (count : Nat) (low high : Rat) (measure : Nat → Option Meas) (pf af : Nat)
    (w : Window) (r : Row) (h : r ∈ w) (hl : low ≤ r.bandBottom) (hh : r.bandTop ≤ high) :
    r ∈ rebalanceIn count low high measure pf af w := by
  simp only [rebalanceIn]
  obtain ⟨S, eS⟩ := appendWhile_prefix (count := count) (measure := measure) (lastBelow high) af
    (prependWhile measure (headAbove low) pf (dropBack high (dropFront low w)))
  obtain ⟨P, eP⟩ := prependWhile_suffix (measure := measure) (headAbove low) pf
    (dropBack high (dropFront low w))
  rw [eS, eP]
  simp only [List.mem_append]
  exact Or.inl (Or.inr (dropBack_keeps high _ r (dropFront_keeps low w r h hl) hh))

/-- A row is shown at offset `q` when its band meets the viewport `[q, q + vh]`. -/
def Shown (vh q : Rat) (r : Row) : Prop := q ≤ r.bandBottom ∧ r.bandTop ≤ q + vh

/-- **Covering the viewport track keeps every row it shows.** If every offset
the track shows lies in the covered interval `[cl, ch]`, `rebalance`'s bounds
(`min(offset, cl) - margin`, `max(offset, ch) + vh + margin`) keep every row
shown at any time of the track, whatever the budget adds. -/
theorem rebalanceIn_keeps_covered (count : Nat) (measure : Nat → Option Meas) (pf af : Nat)
    (w : Window) (offset cl ch vh margin q : Rat) (hm : 0 ≤ margin) (hq : cl ≤ q ∧ q ≤ ch)
    (r : Row) (h : r ∈ w) (hs : Shown vh q r) :
    r ∈ rebalanceIn count (min offset cl - margin) (max offset ch + vh + margin) measure pf af w :=
  rebalanceIn_keeps count _ _ measure pf af w r h (by have := hs.1; grind) (by have := hs.2; grind)

/-- **A track with bounded progress stays in the hull of its bounds.** The
viewport track shows the content at `offset + (1 - p) * delta`. If the curve's
progress stays in `[lo, hi]` (`[0, 1]` for curves that do not overshoot, wider
for a spring), every offset it shows lies between the offsets at `lo` and at
`hi`, so covering those two keeps every row the track shows
(`rebalanceIn_keeps_covered`). -/
theorem track_in_hull (offset delta lo hi p : Rat) (hp : lo ≤ p ∧ p ≤ hi) :
    min (offset + (1 - lo) * delta) (offset + (1 - hi) * delta) ≤ offset + (1 - p) * delta ∧
      offset + (1 - p) * delta ≤ max (offset + (1 - lo) * delta) (offset + (1 - hi) * delta) := by
  have e1 : offset + (1 - p) * delta = offset + (1 - lo) * delta - (p - lo) * delta := by grind
  have e2 : offset + (1 - hi) * delta = offset + (1 - lo) * delta - (p - lo) * delta -
      (hi - p) * delta := by grind
  have h1 : 0 ≤ p - lo := by grind
  have h2 : 0 ≤ hi - p := by grind
  by_cases hd : 0 ≤ delta
  · have a := Rat.mul_nonneg h1 hd
    have b := Rat.mul_nonneg h2 hd
    constructor <;> grind
  · have hd' : 0 ≤ -delta := by grind
    have a := Rat.mul_nonneg h1 hd'
    have b := Rat.mul_nonneg h2 hd'
    constructor <;> grind

/-- **A moving engine under a viewport track needs the sum of their ranges.**
What is shown is the engine offset plus the viewport delta. If the engine's
flight stays in `[el, eh]` and the track's delta in `[vl, vh]`, the shown
offset stays in `[el + vl, eh + vh]`, so covering that interval keeps every
row shown (`rebalanceIn_keeps_covered`). The hull of the two ranges is not
enough (`hull_misses`). -/
theorem sum_covers (count : Nat) (measure : Nat → Option Meas) (pf af : Nat) (w : Window)
    (offset el eh vl vh e v vh' margin : Rat) (hm : 0 ≤ margin) (he : el ≤ e ∧ e ≤ eh)
    (hv : vl ≤ v ∧ v ≤ vh) (r : Row) (h : r ∈ w) (hs : Shown vh' (e + v) r) :
    r ∈ rebalanceIn count (min offset (el + vl) - margin) (max offset (eh + vh) + vh' + margin)
      measure pf af w :=
  rebalanceIn_keeps_covered count measure pf af w offset _ _ vh' margin (e + v) hm
    ⟨by grind, by grind⟩ r h hs

/-- The hull of an engine flight over `[0, 100]` and a viewport delta over
`[0, 252]` is `[0, 252]`, but they show offset 352 together. -/
theorem hull_misses : ¬((0 : Rat) ≤ 100 + 252 ∧ (100 : Rat) + 252 ≤ max 100 252) := by
  decide +kernel

/-- Rows of 50 points, loaded at the top: rows 0 to 11 of 40. -/
def fifty (_ : Nat) : Option Meas := some ⟨50, 0, 0⟩

def topWindow : Window := build 40 0 (phone 0) 160 none true none fifty (fun _ => 0)

/-- **An inset change larger than the margin drops rows on screen (Swift at
`76bac32`).** A 252-point top inset moves the offset from 0 to -252, and the
viewport track starts at +252, so the content is still shown at offset 0.
Rebalancing around the final offset alone keeps rows up to `bandTop` 308 and
drops row 7, whose band `[350, 400]` is on screen at offset 0. Covering the
track's start keeps every row. -/
theorem inset_drops_shown :
    topWindow.map (·.index) = List.range 12 ∧
    (topWindow.find? (·.index == 7)).map (fun r => (r.bandTop, r.bandBottom)) = some (350, 400) ∧
    (rebalanceIn 40 (-252 - 160) (-252 + 400 + 160) fifty 40 40 topWindow).map (·.index) =
      List.range 7 ∧
    (rebalanceIn 40 (min (-252) 0 - 160) (max (-252) 0 + 400 + 160) fifty 40 40 topWindow).map
      (·.index) = List.range 12 := by
  decide +kernel

end UltraProofs.ListInsets
