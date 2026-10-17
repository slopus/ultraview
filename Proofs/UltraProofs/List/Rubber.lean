import UltraProofs.List.Insets

/-!
# Rubber banding and re-anchoring a drag

Models `ScrollMath.rubberBand` and `inverseRubberBand` (ScrollMath.swift)
and how `ScrollAxis.reanchorDrag` uses them. Beyond an edge, a drag of
distance `d` shows `band d = r (1 - 1 / (1 + c d / r))`, `r` the range and
`c` the coefficient. The inverse caps the shown distance at `r * cap` (the
Swift's `cap` is `1 - 1e-6`), since `band` never reaches `r`. When a pass
changes the edges during a drag (`absorbsEdgeChangeIntoOverscroll`), the list
shifts the axis and calls `reanchorDrag`, which replaces the proposed offset
with the inverse of the shown one and moves the drag's anchor by the same
amount. Swipe actions use the same pair for a row's reveal
(`SwipeRevealLayout.displayed` and `proposed`). Distances are rationals; the
Swift's `ulpOfOne` guard is `0 < r` here.

* `band_bounds`, `band_mono`: the shown distance is in `[0, r)` and grows
  with the drag.
* `rubber_unrubber`: the inverse of a shown offset within `r * cap` of its
  edge rubber-bands back to it exactly, so catching a row in motion or
  re-anchoring a drag does not move what is shown.
  `unrubber_rubber`: the inverse of a rubber-banded offset whose band is
  within the cap is the offset it came from.
* `reanchor_no_jump`: after a re-anchor, the drag's current translation
  shows the offset that was shown before it, whatever the new edges, so an
  edge change in the middle of a drag moves nothing under the finger.
  `reanchor_idle`: with the edges the drag was banded against, a re-anchor
  changes nothing, so repeated passes never drift the anchor.
* `reanchor_capped`: beyond the cap the next drag sample jumps toward the
  edge, to `r * cap` past it. `capped_jump`: with a 400-point range and an
  offset 500 points past a new edge, by just over 100 points.
* `adapt_covers`, `adapt_no_jump`: re-anchoring with the range raised to
  twice the shown overscroll when that is past the cap (`adapt`) meets the
  cap for any overscroll, so nothing jumps; `adapt_example` is the
  500-point case. `adapt_idle`: within the cap the range is kept.
* `begin_catches`: a drag that begins on overscrolled content and
  re-anchors with the adapted range shows the caught offset at once.
  `begin_unanchored_jumps`: without that re-anchor, the first sample shows
  less overscroll than was caught.
-/

namespace UltraProofs.ListRubber

open UltraProofs.ListInsets

def absR (x : Rat) : Rat := if x < 0 then -x else x

theorem absR_neg {x : Rat} (h : x < 0) : absR x = -x := by unfold absR; split <;> grind
theorem absR_nonneg {x : Rat} (h : 0 ≤ x) : absR x = x := by unfold absR; split <;> grind
theorem if_t {α : Type} {p : Prop} [Decidable p] (h : p) (a b : α) : (if p then a else b) = a := by simp [h]
theorem if_f {α : Type} {p : Prop} [Decidable p] (h : ¬p) (a b : α) : (if p then a else b) = b := by simp [h]
theorem min_left {a b : Rat} (h : a ≤ b) : min a b = a := by rw [Rat.min_def]; split <;> grind
theorem min_right {a b : Rat} (h : b ≤ a) : min a b = b := by rw [Rat.min_def]; split <;> grind

/-- The shown distance for a drag of `d` past an edge. -/
def band (r c d : Rat) : Rat := r * (1 - 1 / (1 + c * d / r))

/-- The drag distance that shows `b`. -/
def unband (r c b : Rat) : Rat := r * b / (c * (r - b))

/-- `ScrollMath.rubberBand`. -/
def rubber (e : Edges) (r c x : Rat) : Rat :=
  if 0 < r ∧ 0 < c then
    let edge := clamp e x
    let b := band r c (absR (x - edge))
    edge + (if x < edge then -b else b)
  else x

/-- `ScrollMath.inverseRubberBand`. -/
def unrubber (e : Edges) (r c cap x : Rat) : Rat :=
  if 0 < r ∧ 0 < c then
    let edge := clamp e x
    let d := unband r c (min (absR (x - edge)) (r * cap))
    edge + (if x < edge then -d else d)
  else x

theorem band_zero (r c : Rat) : band r c 0 = 0 := by
  simp only [band]; grind

theorem band_eq {r c d : Rat} (hr : 0 < r) (hc : 0 < c) (hd : 0 ≤ d) :
    band r c d = r * c * d / (r + c * d) := by
  have h1 : r + c * d ≠ 0 := by
    have : 0 ≤ c * d := Rat.mul_nonneg (Rat.le_of_lt hc) hd
    grind
  have h2 : r ≠ 0 := by grind
  simp only [band]; grind

/-- **The shown distance is in `[0, r)`.** -/
theorem band_bounds {r c d : Rat} (hr : 0 < r) (hc : 0 < c) (hd : 0 ≤ d) :
    0 ≤ band r c d ∧ band r c d < r := by
  have hcd : 0 ≤ c * d := Rat.mul_nonneg (Rat.le_of_lt hc) hd
  have hpos : 0 < r + c * d := by grind
  have hsub : r - band r c d = r * r / (r + c * d) := by
    rw [band_eq hr hc hd]; have : r + c * d ≠ 0 := by grind
    grind
  have hq : 0 < r * r / (r + c * d) := by
    rw [Rat.div_def]
    exact Rat.mul_pos (Rat.mul_pos hr hr) (Rat.inv_pos.mpr hpos)
  refine ⟨?_, by grind⟩
  rw [band_eq hr hc hd, Rat.div_def]
  exact Rat.mul_nonneg (Rat.mul_nonneg (Rat.mul_nonneg (Rat.le_of_lt hr) (Rat.le_of_lt hc)) hd)
    (Rat.le_of_lt (Rat.inv_pos.mpr hpos))

/-- **The shown distance grows with the drag.** -/
theorem band_mono {r c d e : Rat} (hr : 0 < r) (hc : 0 < c) (hd : 0 ≤ d) (hde : d ≤ e) :
    band r c d ≤ band r c e := by
  have he : 0 ≤ e := Rat.le_trans hd hde
  have hb1 := band_bounds hr hc hd
  have hb2 := band_bounds hr hc he
  -- `r - band` is `r² / (r + c·)`, which shrinks as the drag grows.
  have hcd : 0 ≤ c * d := Rat.mul_nonneg (Rat.le_of_lt hc) hd
  have hce : c * d ≤ c * e := Rat.mul_le_mul_of_nonneg_left hde (Rat.le_of_lt hc)
  have hd' : r + c * d ≠ 0 := by grind
  have he' : r + c * e ≠ 0 := by grind
  have s1 : (r - band r c d) * (r + c * d) = r * r := by rw [band_eq hr hc hd]; grind
  have s2 : (r - band r c e) * (r + c * e) = r * r := by rw [band_eq hr hc he]; grind
  by_cases h : band r c e < band r c d
  · exfalso
    have : (r - band r c d) * (r + c * d) < (r - band r c e) * (r + c * e) := by
      have a : (r - band r c d) * (r + c * d) ≤ (r - band r c d) * (r + c * e) :=
        Rat.mul_le_mul_of_nonneg_left (by grind) (by grind)
      have b : (r - band r c d) * (r + c * e) < (r - band r c e) * (r + c * e) := by
        have hpos : 0 < r + c * e := by grind
        exact Rat.mul_lt_mul_of_pos_right (a := r - band r c d) (b := r - band r c e) (by grind) hpos
      grind
    grind
  · exact Rat.not_lt.mp h

/-- **The inverse undoes the band** below `r`. -/
theorem band_unband {r c b : Rat} (hr : 0 < r) (hc : 0 < c) (_hb : 0 ≤ b) (hbr : b < r) :
    band r c (unband r c b) = b := by
  have h1 : r - b ≠ 0 := by grind
  have h2 : c ≠ 0 := by grind
  have h3 : r ≠ 0 := by grind
  simp only [band, unband]; grind

theorem unband_nonneg {r c b : Rat} (hr : 0 < r) (hc : 0 < c) (hb : 0 ≤ b) (hbr : b < r) :
    0 ≤ unband r c b := by
  simp only [unband, Rat.div_def]
  exact Rat.mul_nonneg (Rat.mul_nonneg (Rat.le_of_lt hr) hb)
    (Rat.le_of_lt (Rat.inv_pos.mpr (Rat.mul_pos hc (by grind))))

theorem unband_band {r c d : Rat} (hr : 0 < r) (hc : 0 < c) (hd : 0 ≤ d) :
    unband r c (band r c d) = d := by
  have hcd : 0 ≤ c * d := Rat.mul_nonneg (Rat.le_of_lt hc) hd
  have h1 : r + c * d ≠ 0 := by grind
  have h2 : c ≠ 0 := by grind
  have h3 : r ≠ 0 := by grind
  have hsub : r - r * c * d / (r + c * d) = r * r / (r + c * d) := by grind
  have h4 : r * r / (r + c * d) ≠ 0 := by
    have : 0 < r * r / (r + c * d) := by
      rw [Rat.div_def]; exact Rat.mul_pos (Rat.mul_pos hr hr) (Rat.inv_pos.mpr (by grind))
    grind
  rw [band_eq hr hc hd]; simp only [unband, hsub]; grind

/-! ## The side of the edge -/

theorem clamp_above {e : Edges} {x y : Rat} (hx : clamp e x < x) (hy : clamp e x ≤ y) :
    clamp e y = clamp e x := by
  cases hl : e.minimum <;> cases hh : e.maximum <;> simp only [clamp, hl, hh] at hx hy ⊢ <;> grind

theorem clamp_below {e : Edges} {x y : Rat} (hx : x < clamp e x) (hy : y ≤ clamp e x) :
    clamp e y = clamp e x := by
  cases hl : e.minimum <;> cases hh : e.maximum <;> simp only [clamp, hl, hh] at hx hy ⊢ <;> grind

/-- **The inverse of a shown offset rubber-bands back to it**, when it is
within the cap of its edge. -/
theorem rubber_unrubber {e : Edges} {r c cap x : Rat} (hr : 0 < r) (hc : 0 < c) (hcap : cap < 1)
    (hx : absR (x - clamp e x) ≤ r * cap) : rubber e r c (unrubber e r c cap x) = x := by
  have hrc : 0 < r ∧ 0 < c := ⟨hr, hc⟩
  have hcapr : r * cap < r := by
    have := Rat.mul_lt_mul_of_pos_left hcap hr; grind
  simp only [unrubber, hrc, and_self, ite_true]
  generalize hE : clamp e x = E at hx
  have hmin : min (absR (x - E)) (r * cap) = absR (x - E) := min_left hx
  rw [hmin]
  by_cases hxe : x < E
  · have hb : absR (x - E) = E - x := by rw [absR_neg (by grind)]; grind
    rw [hb] at hx ⊢
    have hD := unband_nonneg hr hc (b := E - x) (by grind) (by grind)
    have hy : clamp e (E + -unband r c (E - x)) = E := by
      rw [← hE]; exact clamp_below (by grind) (by grind)
    simp only [rubber, hrc, and_self, ite_true, hy, hxe, ite_true]
    have hpos : 0 < unband r c (E - x) := by
      rcases Rat.le_iff_lt_or_eq.mp hD with h | h
      · exact h
      · exfalso
        have := band_unband hr hc (b := E - x) (by grind) (by grind)
        rw [← h, band_zero] at this; grind
    have hlt : E + -unband r c (E - x) < E := by grind
    have hab : absR (E + -unband r c (E - x) - E) = unband r c (E - x) := by
      rw [absR_neg (by grind)]; grind
    rw [if_t hlt, hab, band_unband hr hc (by grind) (by grind)]; grind
  · have hb : absR (x - E) = x - E := by rw [absR_nonneg (by grind)]
    rw [hb] at hx ⊢
    have hD := unband_nonneg hr hc (b := x - E) (by grind) (by grind)
    have hy : clamp e (E + unband r c (x - E)) = E := by
      by_cases h : E < x
      · rw [← hE]; exact clamp_above (by grind) (by grind)
      · have hxE : x = E := by grind
        have hu : unband r c (x - E) = 0 := by simp only [unband, hxE]; grind
        rw [hu, Rat.add_zero, ← hE]; exact clamp_idem e x
    simp only [rubber, hrc, and_self, ite_true, hy, hxe, ite_false]
    have hab : absR (E + unband r c (x - E) - E) = unband r c (x - E) := by
      rw [absR_nonneg (by grind)]; grind
    rw [if_f (by grind), hab, band_unband hr hc (by grind) (by grind)]; grind

/-- **The inverse of a banded offset is where it came from**, when its band
is within the cap. -/
theorem unrubber_rubber {e : Edges} {r c cap y : Rat} (hr : 0 < r) (hc : 0 < c)
    (hcap : band r c (absR (y - clamp e y)) ≤ r * cap) : unrubber e r c cap (rubber e r c y) = y := by
  have hrc : 0 < r ∧ 0 < c := ⟨hr, hc⟩
  simp only [rubber, hrc, and_self, ite_true]
  generalize hE : clamp e y = E at hcap
  by_cases hye : y < E
  · have hd : absR (y - E) = E - y := by rw [absR_neg (by grind)]; grind
    rw [hd] at hcap ⊢
    have hB := band_bounds hr hc (d := E - y) (by grind)
    have hpos : 0 < band r c (E - y) := by
      rcases Rat.le_iff_lt_or_eq.mp hB.1 with h | h
      · exact h
      · exfalso; have := unband_band hr hc (d := E - y) (by grind); rw [← h] at this
        simp only [unband] at this; grind
    have hx : clamp e (E + -band r c (E - y)) = E := by
      rw [← hE]; exact clamp_below (by grind) (by grind)
    simp only [ite_true, hye, unrubber, hrc, and_self, hx]
    have hab : absR (E + -band r c (E - y) - E) = band r c (E - y) := by
      rw [absR_neg (by grind)]; grind
    rw [hab, min_left hcap, if_t (by grind), unband_band hr hc (by grind)]; grind
  · have hd : absR (y - E) = y - E := by rw [absR_nonneg (by grind)]
    rw [hd] at hcap ⊢
    have hB := band_bounds hr hc (d := y - E) (by grind)
    have hx : clamp e (E + band r c (y - E)) = E := by
      by_cases h : E < y
      · rw [← hE]; exact clamp_above (by grind) (by grind)
      · have hyE : y = E := by grind
        rw [hyE, Rat.sub_self, band_zero, Rat.add_zero, ← hE]; exact clamp_idem e y
    simp only [ite_false, hye, unrubber, hrc, and_self, hx]
    have hab : absR (E + band r c (y - E) - E) = band r c (y - E) := by
      rw [absR_nonneg (by grind)]; grind
    have hB0 := hB.1
    rw [hab, min_left hcap, if_f (show ¬(E + band r c (y - E) < E) by grind), unband_band hr hc (by grind)]
    grind

/-! ## Re-anchoring a drag -/

/-- A drag: the anchor, the proposed offset (`anchor - translation`) and the
shown offset. -/
structure Drag where
  anchor : Rat
  proposed : Rat
  offset : Rat

/-- `ScrollAxis.drag(translation:)`. -/
def drag (e : Edges) (r c : Rat) (s : Drag) (t : Rat) : Drag :=
  { s with proposed := s.anchor - t, offset := rubber e r c (s.anchor - t) }

/-- `ScrollAxis.reanchorDrag()`. -/
def reanchor (e : Edges) (r c cap : Rat) (s : Drag) : Drag :=
  let rep := unrubber e r c cap s.offset
  { s with anchor := s.anchor + (rep - s.proposed), proposed := rep }

theorem reanchor_proposed (e : Edges) (r c cap : Rat) (s : Drag) (t : Rat) (ht : s.proposed = s.anchor - t) :
    (reanchor e r c cap s).anchor - t = unrubber e r c cap s.offset := by
  simp only [reanchor]; grind

/-- **An edge change mid-drag moves nothing under the finger**: after a
re-anchor against the new edges, the drag's current translation shows the
offset shown before it. -/
theorem reanchor_no_jump {e : Edges} {r c cap : Rat} (hr : 0 < r) (hc : 0 < c) (hcap : cap < 1)
    (s : Drag) (t : Rat) (ht : s.proposed = s.anchor - t)
    (hx : absR (s.offset - clamp e s.offset) ≤ r * cap) :
    (drag e r c (reanchor e r c cap s) t).offset = s.offset := by
  simp only [drag]; rw [reanchor_proposed e r c cap s t ht, rubber_unrubber hr hc hcap hx]

/-- **With unchanged edges a re-anchor changes nothing**, so passes that
re-anchor a drag repeatedly never drift it. -/
theorem reanchor_idle {e : Edges} {r c cap : Rat} (hr : 0 < r) (hc : 0 < c) (s : Drag) (t : Rat)
    (hs : s = drag e r c s t)
    (hcap : band r c (absR (s.proposed - clamp e s.proposed)) ≤ r * cap) :
    reanchor e r c cap s = s := by
  have hp : s.proposed = s.anchor - t := by
    have := congrArg Drag.proposed hs; simp only [drag] at this; exact this
  have ho : s.offset = rubber e r c s.proposed := by
    have := congrArg Drag.offset hs; simp only [drag] at this; rw [hp]; exact this
  cases s with
  | mk a p o =>
    simp only at hp ho hcap
    simp only [reanchor, ho, unrubber_rubber hr hc hcap]; grind

/-- **Beyond the cap the drag jumps to the cap**: an offset farther than
`r * cap` past its edge re-anchors so the current translation shows
`r * cap` past it. -/
theorem reanchor_capped {e : Edges} {r c cap : Rat} (hr : 0 < r) (hc : 0 < c) (hcap0 : 0 ≤ cap)
    (hcap : cap < 1) (s : Drag) (t : Rat) (ht : s.proposed = s.anchor - t)
    (hx : clamp e s.offset + r * cap < s.offset) :
    (drag e r c (reanchor e r c cap s) t).offset = clamp e s.offset + r * cap := by
  have hrc : 0 < r ∧ 0 < c := ⟨hr, hc⟩
  have hcapr : r * cap < r := by have := Rat.mul_lt_mul_of_pos_left hcap hr; grind
  have hrc0 : 0 ≤ r * cap := Rat.mul_nonneg (Rat.le_of_lt hr) hcap0
  simp only [drag]; rw [reanchor_proposed e r c cap s t ht]
  generalize hE : clamp e s.offset = E at hx
  have hb : absR (s.offset - E) = s.offset - E := by rw [absR_nonneg (by grind)]
  have hmin : min (s.offset - E) (r * cap) = r * cap := min_right (by grind)
  have hD := unband_nonneg hr hc hrc0 hcapr
  have hy : clamp e (E + unband r c (r * cap)) = E := by
    rw [← hE]; exact clamp_above (by grind) (by grind)
  simp only [unrubber, hrc, and_self, ite_true, hE, hb, hmin, if_f (show ¬s.offset < E by grind)]
  simp only [rubber, hrc, and_self, ite_true, hy]
  have hab : absR (E + unband r c (r * cap) - E) = unband r c (r * cap) := by
    rw [absR_nonneg (by grind)]; grind
  rw [if_f (by grind), hab, band_unband hr hc hrc0 hcapr]

/-- A 400-point range, the Swift's cap, and an offset 500 points past a new
edge at 0: the next drag sample shows `400 - 0.0004`, a jump of just over
100 points. -/
theorem capped_jump (s : Drag) (t : Rat) (ht : s.proposed = s.anchor - t) (ho : s.offset = 500) :
    (drag ⟨some 0, some 0⟩ 400 (11 / 20) (reanchor ⟨some 0, some 0⟩ 400 (11 / 20) (1 - 1 / 1000000) s) t).offset =
      400 - 1 / 2500 := by
  rw [reanchor_capped (by decide +kernel) (by decide +kernel) (by decide +kernel) (by decide +kernel) s t ht
    (by rw [ho]; decide +kernel), ho]
  decide +kernel

/-! ## An adaptive range -/

/-- The range a re-anchor bands the drag with from then on: the current one,
or twice the shown overscroll `x` when `x` is past the cap. -/
def adapt (R cap x : Rat) : Rat := if R * cap < x then max R (2 * x) else R

theorem adapt_ge (R cap x : Rat) : R ≤ adapt R cap x := by
  unfold adapt; split
  · rw [Rat.max_def]; split <;> grind
  · exact Rat.le_refl

/-- **The adapted range always meets the cap**, for a cap of at least one
half, so `reanchor_no_jump` applies with it. -/
theorem adapt_covers {R cap x : Rat} (hcap : 1 / 2 ≤ cap) (hx : 0 ≤ x) :
    x ≤ adapt R cap x * cap := by
  unfold adapt
  split
  · rename_i h
    have hm : 2 * x ≤ max R (2 * x) := by rw [Rat.max_def]; split <;> grind
    have h2 : x ≤ 2 * x * cap := by
      have := Rat.mul_le_mul_of_nonneg_left hcap (show 0 ≤ 2 * x by grind); grind
    have h3 : 2 * x * cap ≤ max R (2 * x) * cap :=
      Rat.mul_le_mul_of_nonneg_right hm (by grind)
    exact Rat.le_trans h2 h3
  · grind

/-- **Within the cap the range is kept**, so drags that never pass it band
exactly as before. -/
theorem adapt_idle {R cap x : Rat} (hx : x ≤ R * cap) : adapt R cap x = R := by
  unfold adapt; rw [ite_eq_right_iff]; intro h; exact absurd hx (Rat.not_le.mpr h)

/-- **With the adapted range, an edge change mid-drag moves nothing under
the finger, however far past the new edge the content is.** -/
theorem adapt_no_jump {e : Edges} {R c cap : Rat} (hR : 0 < R) (hc : 0 < c) (hcap0 : 1 / 2 ≤ cap)
    (hcap : cap < 1) (s : Drag) (t : Rat) (ht : s.proposed = s.anchor - t) :
    let R' := adapt R cap (absR (s.offset - clamp e s.offset))
    (drag e R' c (reanchor e R' c cap s) t).offset = s.offset := by
  intro R'
  have hx : 0 ≤ absR (s.offset - clamp e s.offset) := by
    unfold absR; split <;> grind
  have hR' : 0 < R' := by have := adapt_ge R cap (absR (s.offset - clamp e s.offset)); grind
  have hcov : absR (s.offset - clamp e s.offset) ≤ R' * cap := adapt_covers hcap0 hx
  exact reanchor_no_jump hR' hc hcap s t ht hcov

/-- The capped case again with the range adapted: 500 points past a new edge
in a 400-point viewport, the range becomes 1000 and nothing jumps. -/
theorem adapt_example (s : Drag) (t : Rat) (ht : s.proposed = s.anchor - t) (ho : s.offset = 500) :
    adapt 400 (1 - 1 / 1000000) (absR (s.offset - clamp ⟨some 0, some 0⟩ s.offset)) = 1000 ∧
      (drag ⟨some 0, some 0⟩ 1000 (11 / 20)
        (reanchor ⟨some 0, some 0⟩ 1000 (11 / 20) (1 - 1 / 1000000) s) t).offset = 500 := by
  have ha : adapt 400 (1 - 1 / 1000000) (absR (s.offset - clamp ⟨some 0, some 0⟩ s.offset)) = 1000 := by
    rw [ho]; decide +kernel
  refine ⟨ha, ?_⟩
  have := adapt_no_jump (e := ⟨some 0, some 0⟩) (R := 400) (c := 11 / 20) (cap := 1 - 1 / 1000000)
    (by decide +kernel) (by decide +kernel) (by decide +kernel) (by decide +kernel) s t ht
  simp only at this; rw [ha, ho] at this; exact this

/-- How far a drag has gone past the edge to show `b`, with the range twice
`b`: `2b / c`. The band's slope there, `c ((r - b) / r)²`, is a quarter of
its slope at the edge; at the cap of an unadapted range it is about
`c · 10⁻¹²`, so the content would barely follow the finger. -/
theorem adapt_depth {b c : Rat} (hb : 0 < b) (hc : 0 < c) : unband (2 * b) c b = 2 * b / c := by
  have h1 : c ≠ 0 := by grind
  have h2 : b ≠ 0 := by grind
  simp only [unband]; grind

/-! ## Catching overscrolled content -/

/-- **Catching re-anchors to what is shown**: a drag that begins at the
shown offset `o` (anchor and proposed both `o`, translation 0) and
re-anchors with the adapted range shows `o` at once, however far past the
edge `o` is. -/
theorem begin_catches {e : Edges} {R c cap : Rat} (hR : 0 < R) (hc : 0 < c) (hcap0 : 1 / 2 ≤ cap)
    (hcap : cap < 1) (o : Rat) :
    let R' := adapt R cap (absR (o - clamp e o))
    (drag e R' c (reanchor e R' c cap ⟨o, o, o⟩) 0).offset = o := by
  intro R'
  exact adapt_no_jump (e := e) hR hc hcap0 hcap ⟨o, o, o⟩ 0 (by simp only; grind)

theorem band_lt {r c d : Rat} (hr : 0 < r) (hc : 0 < c) (hc1 : c ≤ 1) (hd : 0 < d) : band r c d < d := by
  have hcd : 0 < c * d := Rat.mul_pos hc hd
  have hden : r + c * d ≠ 0 := by grind
  have hb : band r c d * (r + c * d) = r * c * d := by
    rw [band_eq hr hc (Rat.le_of_lt hd)]; exact Rat.div_mul_cancel hden
  have h1 : 0 < c * d * d := Rat.mul_pos hcd hd
  have h2 : 0 ≤ d * r * (1 - c) := Rat.mul_nonneg (Rat.mul_nonneg (Rat.le_of_lt hd) (Rat.le_of_lt hr)) (by grind)
  apply Rat.not_le.mp
  intro hle
  have := Rat.mul_le_mul_of_nonneg_right hle (show 0 ≤ r + c * d by grind)
  grind

/-- **Without the re-anchor, catching jumps toward the edge**: with the
anchor at the shown offset `o` past an edge, the first drag sample bands
`o` again and shows less overscroll than was shown, for the Swift's
coefficient (at most 1). -/
theorem begin_unanchored_jumps {e : Edges} {r c : Rat} (hr : 0 < r) (hc : 0 < c) (hc1 : c ≤ 1) {o : Rat}
    (ho : clamp e o < o) : (drag e r c ⟨o, o, o⟩ 0).offset < o := by
  have hrc : 0 < r ∧ 0 < c := ⟨hr, hc⟩
  simp only [drag, show o - 0 = o by grind, rubber, hrc, and_self, ite_true]
  generalize hE : clamp e o = E at ho
  rw [if_f (show ¬o < E by grind), absR_nonneg (by grind)]
  have := band_lt hr hc hc1 (show 0 < o - E by grind)
  grind

end UltraProofs.ListRubber
