import UltraProofs.List.Animation

/-!
# A background that resizes with its row

An animated node row's bubble can resize elastically: its background is a
live layer whose bounds follow the row's width and height, each on its own
clock, with a fixed corner radius, and the text inside sits at a fixed
padding from the background's top-left and is swapped by crossfading. This
file states what that gives, for any width and height clocks, and what the
alternative (scaling the final background) and the crossfade's blending
cost.

* `bounds_round`, `bounds_rigid`: resizing the bounds draws every corner as
  a quarter circle of the layer's radius, and moves each corner as a rigid
  piece: the corner at any size is the final one translated by the size
  difference along the axes it sits on.
* `scale_distorts`: scaling the final background to the same size instead
  gives every corner radii `r * sx` and `r * sy`, which are `r` only once
  the size is final.
* `corners_fit`: when both clocks are tracks on curves that don't overshoot
  and the background is at least `2r` wide and tall at both ends, it is at
  every frame, so the radius is never clamped.
* `text_inset`: under any clocks the text keeps its padding from the
  background's top-left and its laid-out size; it is never stretched.
* `text_fits`, `overflow_lerp`: a text that fits the background at both ends
  fits at every frame; one that fits only the end (the new text of a growing
  bubble) overflows by `(1 - p)` of the growth at progress `p`.
* `slice_bands`, `slice_seams`: a box drawn once and nine-sliced (edge bands
  kept, the middle stretched) moves each band rigidly with its edge and
  stays continuous at the seams, so its corners are the final bitmap's.
* `stable_steady`, `ghost_shared`, `ghost_new`, `ghost_old`: with the new
  text at full opacity and the old one over it fading out, ink the two share
  stays full, ink only the new one has shows at once, and ink only the old
  one had fades. `both_dip`: fading both instead dims shared ink to
  `1 - a(1 - a)`, three quarters at mid-fade.
-/

namespace UltraProofs.ListElastic

open UltraProofs.ListAnimation

structure Rect where
  x : Rat
  y : Rat
  w : Rat
  h : Rat
deriving DecidableEq

/-- The bubble's margins inside its row. -/
structure Margins where
  l : Rat
  t : Rat
  r : Rat
  b : Rat

/-- The background when the row is `W` wide and `H` tall. -/
def bg (m : Margins) (W H : Rat) : Rect := ⟨m.l, m.t, W - m.l - m.r, H - m.t - m.b⟩

/-- A corner as drawn: its arc's center and its radii along x and y (an
ellipse's quarter when they differ). -/
structure Corner where
  cx : Rat
  cy : Rat
  rx : Rat
  ry : Rat
deriving DecidableEq

/-- The corners (top-left, top-right, bottom-left, bottom-right) of `rc`
drawn with radii `rx` and `ry`. -/
def corners (rc : Rect) (rx ry : Rat) : List Corner :=
  [⟨rc.x + rx, rc.y + ry, rx, ry⟩, ⟨rc.x + rc.w - rx, rc.y + ry, rx, ry⟩,
   ⟨rc.x + rx, rc.y + rc.h - ry, rx, ry⟩, ⟨rc.x + rc.w - rx, rc.y + rc.h - ry, rx, ry⟩]

/-- Resizing the layer's bounds: Core Animation draws its own radius `r`. -/
def boundsCorners (rc : Rect) (r : Rat) : List Corner := corners rc r r

/-- Scaling the final background `rc` by `sx`, `sy` about its top-left: the
whole drawing scales, corners included. -/
def scaledCorners (rc : Rect) (r sx sy : Rat) : List Corner :=
  corners ⟨rc.x, rc.y, rc.w * sx, rc.h * sy⟩ (r * sx) (r * sy)

/-- **Resizing the bounds keeps every corner round**, of radius `r`, at any
size. -/
theorem bounds_round (m : Margins) (r W H : Rat) :
    ∀ c ∈ boundsCorners (bg m W H) r, c.rx = r ∧ c.ry = r := by
  intro c hc
  simp only [boundsCorners, corners, List.mem_cons, List.not_mem_nil, or_false] at hc
  rcases hc with rfl | rfl | rfl | rfl <;> exact ⟨rfl, rfl⟩

/-- **Each corner moves as a rigid piece**: at width `W` and height `H` it
is the corner at the final `W1`, `H1` translated by the width difference if
it is on the right and the height difference if it is at the bottom. -/
theorem bounds_rigid (m : Margins) (r W H W1 H1 : Rat) :
    boundsCorners (bg m W H) r =
      (List.zip (boundsCorners (bg m W1 H1) r) [(0, 0), (W - W1, 0), (0, H - H1), (W - W1, H - H1)]).map
        fun (c, d) => { c with cx := c.cx + d.1, cy := c.cy + d.2 } := by
  simp only [boundsCorners, corners, bg, List.zip, List.zipWith, List.map, List.cons.injEq, Corner.mk.injEq,
    and_true]
  refine ⟨⟨?_, ?_⟩, ⟨?_, ?_⟩, ⟨?_, ?_⟩, ?_, ?_⟩ <;> grind

/-- **Scaling distorts the corners**: shown at the background width `w`
from a final width `w1` (both positive, `r` nonzero), every corner's
horizontal radius is `r` only when `w = w1`. -/
theorem scale_distorts (rc : Rect) {r w : Rat} (hr : r ≠ 0) (hw : 0 < rc.w) (sy : Rat) :
    (∀ c ∈ scaledCorners rc r (w / rc.w) sy, c.rx = r) ↔ w = rc.w := by
  have hne : rc.w ≠ 0 := by grind
  have key : r * (w / rc.w) = r ↔ w = rc.w := by
    constructor
    · intro h
      have h0 : r * (w / rc.w - 1) = 0 := by grind
      rcases Rat.mul_eq_zero.mp h0 with h1 | h1
      · exact absurd h1 hr
      · have h2 : w / rc.w = 1 := by grind
        have := Rat.div_mul_cancel (a := w) hne
        rw [h2, Rat.one_mul] at this; exact this.symm
    · rintro rfl
      rw [Rat.div_def, Rat.mul_inv_cancel _ hne, Rat.mul_one]
  constructor
  · intro h
    exact key.mp (h ⟨rc.x + r * (w / rc.w), rc.y + r * sy, r * (w / rc.w), r * sy⟩
      (by simp [scaledCorners, corners]))
  · intro h c hc
    simp only [scaledCorners, corners, List.mem_cons, List.not_mem_nil, or_false] at hc
    rcases hc with rfl | rfl | rfl | rfl <;> exact key.mpr h

/-- A track on a curve that doesn't overshoot stays at or above any bound
both its ends are at or above. -/
theorem track_ge (C : Curves) (hC : C.Bounded) (tr : Track) {lo : Rat} (hs : lo ≤ tr.src)
    (hd : lo ≤ tr.dst) (t : Rat) : lo ≤ tr.value C t := by
  rw [lerp]
  have hp := progress_bounded C hC tr t
  have a : 0 ≤ (1 - tr.progress C t) * (tr.src - lo) := Rat.mul_nonneg (by grind) (by grind)
  have b : 0 ≤ tr.progress C t * (tr.dst - lo) := Rat.mul_nonneg hp.1 (by grind)
  grind

/-- **The radius always fits**: with width and height on their own tracks
(any timings) whose curves don't overshoot, a background at least `2r` wide
and tall at both ends is at every frame. -/
theorem corners_fit (C : Curves) (hC : C.Bounded) (m : Margins) (r : Rat) (W H : Track)
    (hW0 : 2 * r ≤ (bg m W.src H.src).w) (hW1 : 2 * r ≤ (bg m W.dst H.dst).w)
    (hH0 : 2 * r ≤ (bg m W.src H.src).h) (hH1 : 2 * r ≤ (bg m W.dst H.dst).h) (t : Rat) :
    2 * r ≤ (bg m (W.value C t) (H.value C t)).w ∧ 2 * r ≤ (bg m (W.value C t) (H.value C t)).h := by
  simp only [bg] at *
  have hw := track_ge C hC W (lo := 2 * r + m.l + m.r) (by grind) (by grind) t
  have hh := track_ge C hC H (lo := 2 * r + m.t + m.b) (by grind) (by grind) t
  grind

/-- The text laid out `tw` by `th`, at padding `p` from the background's
top-left, never scaled. -/
def textFrame (rc : Rect) (p tw th : Rat) : Rect := ⟨rc.x + p, rc.y + p, tw, th⟩

/-- **The text keeps its inset and size** under any clocks. -/
theorem text_inset (m : Margins) (p tw th W H : Rat) :
    (textFrame (bg m W H) p tw th).x - (bg m W H).x = p ∧ (textFrame (bg m W H) p tw th).y - (bg m W H).y = p ∧
      (textFrame (bg m W H) p tw th).w = tw ∧ (textFrame (bg m W H) p tw th).h = th := by
  simp only [textFrame, bg]; grind

/-- The text lies inside the background's padding. -/
def Fits (rc : Rect) (p tw th : Rat) : Prop := tw ≤ rc.w - 2 * p ∧ th ≤ rc.h - 2 * p

/-- **A text that fits both ends fits at every frame**, under tracks that
don't overshoot. -/
theorem text_fits (C : Curves) (hC : C.Bounded) (m : Margins) (p tw th : Rat) (W H : Track)
    (h0 : Fits (bg m W.src H.src) p tw th) (h1 : Fits (bg m W.dst H.dst) p tw th) (t : Rat) :
    Fits (bg m (W.value C t) (H.value C t)) p tw th := by
  simp only [Fits, bg] at *
  have hw := track_ge C hC W (lo := tw + 2 * p + m.l + m.r) (by grind) (by grind) t
  have hh := track_ge C hC H (lo := th + 2 * p + m.t + m.b) (by grind) (by grind) t
  grind

/-- **A text that fills only the final width overflows by what is left of
the growth**: `(1 - p)` of it at progress `p`. -/
theorem overflow_lerp (C : Curves) (m : Margins) (pad : Rat) (W : Track) (H t : Rat) :
    let tw := (bg m W.dst H).w - 2 * pad
    tw - ((bg m (W.value C t) H).w - 2 * pad) = (1 - W.progress C t) * (W.dst - W.src) := by
  simp only [bg, Track.value]; grind

/-- Nine-slicing along one axis: a bitmap drawn `w1` long with bands `b`
long at both ends, shown `w` long. The bands keep their length; the middle
stretches. -/
def slice (b w1 w x : Rat) : Rat :=
  if x ≤ b then x else if w1 - b ≤ x then x + (w - w1) else b + (x - b) * ((w - 2 * b) / (w1 - 2 * b))

/-- **The bands move rigidly**: the near band stays, the far band moves with
the far edge. -/
theorem slice_bands (b w1 w x : Rat) (hb : 2 * b < w1) :
    (x ≤ b → slice b w1 w x = x) ∧ (w1 - b ≤ x → slice b w1 w x = x + (w - w1)) := by
  refine ⟨fun h => by simp [slice, h], fun h => ?_⟩
  have : ¬x ≤ b := by grind
  simp [slice, this, h]

/-- **The stretched middle meets both bands**: at the seams it is where the
bands are. -/
theorem slice_seams (b w1 w : Rat) (hb : 2 * b < w1) :
    b + (b - b) * ((w - 2 * b) / (w1 - 2 * b)) = b ∧
      b + (w1 - b - b) * ((w - 2 * b) / (w1 - 2 * b)) = w1 - b + (w - w1) := by
  have hne : w1 - 2 * b ≠ 0 := by grind
  refine ⟨by grind, ?_⟩
  have e : (w1 - b - b) * ((w - 2 * b) / (w1 - 2 * b)) = w - 2 * b := by
    rw [show w1 - b - b = w1 - 2 * b by grind, Rat.mul_comm, Rat.div_mul_cancel hne]
  rw [e]; grind

/-- Coverage of a pixel where the new bitmap (ink `n`) shows at opacity `m`
and the old one (ink `o`) lies over it at opacity `g`, ordinary blending. -/
def layered (m g o n : Rat) : Rat := 1 - (1 - m * n) * (1 - g * o)

/-- **A stable region shows the new text throughout.** -/
theorem stable_steady (o n : Rat) : layered 1 0 o n = n := by
  simp only [layered]; grind

/-- **Shared ink stays full** while the old text fades over the new. -/
theorem ghost_shared (g : Rat) : layered 1 g 1 1 = 1 := by
  simp only [layered]; grind

/-- **Ink only the new text has shows at once.** -/
theorem ghost_new (g n : Rat) : layered 1 g 0 n = n := by
  simp only [layered]; grind

/-- **Ink only the old text had fades with the ghost.** -/
theorem ghost_old (m g o : Rat) : layered m g o 0 = g * o := by
  simp only [layered]; grind

/-- **Fading both dims shared ink**: the new in at `a`, the old out at
`1 - a`, full ink shows at `1 - a(1 - a)`, three quarters at mid-fade. -/
theorem both_dip (a : Rat) : layered a (1 - a) 1 1 = 1 - a * (1 - a) ∧ layered (1 / 2) (1 / 2) 1 1 = 3 / 4 := by
  refine ⟨by simp only [layered]; grind, by decide +kernel⟩

end UltraProofs.ListElastic
