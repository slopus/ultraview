import UltraProofs.List.Animation

/-!
# Content inside an animating row

A node row that animates its content moves each inner node's frame on the
timing of the row's own height animation, and moves every running inner
animation onto a new row timing when the list installs one, continuing from
its presented value toward its target. This file proves what that buys: a
node edge kept at a constant distance from the row's edge (a bubble's bottom
at `row.height - pad`) stays there at every frame, through any number of
retimings.

* `edge_lerp`: two tracks on one timing are `(1 - p)` of their start
  difference plus `p` of their end difference apart at every time, with the
  same `p`.
* `edge_constant`: equal differences at start and end give that difference
  at every time.
* `retime_keeps`, `retimes_keep`: restarting both tracks from their
  presented values toward their targets on a new timing, any number of
  times, keeps the difference at every time.
* `retime_unstarted`, `retime_same`: an animation added in the same
  transaction restarts from its start value, and one already on the new
  timing is unchanged, so the Swift's two special cases are this `retime`.
* `axes_keep`: x key paths on the row's width animation and y key paths on
  its height animation keep both insets through any interleaving.
  `last_wins_drifts`: moving everything onto the last one added does not.
* `shift_value`, `shift_keeps`: content replaced with no timing, each
  running animation moved by its own destination's change on the same
  timing (the list's moved-track rule), keeps the inset with the row moved
  the same way; `row_only_off`: moving only the row puts it off by the
  row's change.
* `join_jump`, `join_exact`: content joining a running animation at
  progress `p` from its snapshot jumps by `(T - s) p`; starting from
  `(s - T p) / (1 - p)` it is continuous. `joinStart_beyond`,
  `joinStart_inside_iff`, `clamped_is_snapshot`, `clamped_jump`: that start
  always lies beyond `s`, away from `T`, and inside `[s, T]` only when
  `p = 0` or `s = T`, so clamping it to `[s, T]` gives `s` and the full
  jump.
  `join_remap`, `join_within`: unclamped, it shows the remaining progress
  rescaled, within `[s, T]` for a forward, non-overshooting curve; an
  overshoot is magnified by `1 / (1 - p)` (`clamp_sample`).
* `valueProgress_eq`: the row's value progress `(shown - from) / (to - from)`
  is its curve progress. `bezier_mono`, `bezier_bounded`, `solved_mono`: a
  Bézier timing curve with control points in `[0, 1]` never moves backward
  in time and stays in `[0, 1]`, so `join_within` applies to it.
  `catchup_ends`: the catch-up starts at the snapshot and lands on the
  target when its own timing ends.
* `alone_drifts`: retiming the row alone (an inner animation left on the
  old timing) changes the difference mid-flight.
-/

namespace UltraProofs.ListContent

open UltraProofs.ListAnimation

/-- Same start and transition. -/
def Shared (a b : Track) : Prop := a.start = b.start ∧ a.transition = b.transition

theorem edge_lerp (C : Curves) {a b : Track} (h : Shared a b) (time : Rat) :
    ∃ p, a.value C time - b.value C time = (1 - p) * (a.src - b.src) + p * (a.dst - b.dst) := by
  refine ⟨b.progress C time, ?_⟩
  rw [lerp C a, lerp C b, progress_timing C h.1 h.2]
  grind

/-- **A constant inset stays constant.** -/
theorem edge_constant (C : Curves) {a b : Track} (h : Shared a b) {d : Rat} (h0 : a.src - b.src = d)
    (h1 : a.dst - b.dst = d) (time : Rat) : a.value C time - b.value C time = d := by
  obtain ⟨p, hp⟩ := edge_lerp C h time
  rw [hp, h0, h1]; grind

/-- Restart a track at `t0` from its presented value toward its target, on a
new start and transition: the row view's interception of a new height
animation. -/
def retime (C : Curves) (t0 s : Rat) (τ : Transition) (tr : Track) : Track :=
  { tr with src := tr.value C t0, start := s, transition := τ }

/-- **An animation not yet started restarts from where it starts**: the
Swift's `from = fromValue` for an animation added in the current transaction
(`beginTime == 0`), which begins at the same instant as the new timing. -/
theorem retime_unstarted (C : Curves) {tr : Track} {t0 : Rat} (h0 : tr.start = t0)
    (hd : 0 < tr.transition.duration) (s : Rat) (τ : Transition) :
    retime C t0 s τ tr = { tr with start := s, transition := τ } := by
  simp only [retime]; rw [← h0, value_start C tr hd]

/-- **An animation already on the new timing is left as it is**: retiming it
changes nothing, so the Swift's skipping it (`isTiming(of:)`) is the same
step. -/
theorem retime_same (C : Curves) {tr : Track} {t0 : Rat} {τ : Transition} (h0 : tr.start = t0)
    (hτ : tr.transition = τ) (hd : 0 < tr.transition.duration) : retime C t0 t0 τ tr = tr := by
  rw [retime_unstarted C h0 hd]
  cases tr; simp only at h0 hτ; subst h0; subst hτ; rfl

/-- Both tracks on one timing, a fixed distance apart at start and end. -/
def Keeps (a b : Track) (d : Rat) : Prop := Shared a b ∧ a.src - b.src = d ∧ a.dst - b.dst = d

theorem retime_keeps (C : Curves) {a b : Track} {d : Rat} (h : Keeps a b d) (t0 s : Rat) (τ : Transition) :
    Keeps (retime C t0 s τ a) (retime C t0 s τ b) d :=
  ⟨⟨rfl, rfl⟩, edge_constant C h.1 h.2.1 h.2.2 t0, h.2.2⟩

def retimes (C : Curves) : List (Rat × Rat × Transition) → Track → Track
  | [], tr => tr
  | (t0, s, τ) :: rs, tr => retimes C rs (retime C t0 s τ tr)

/-- **Through any number of retimings**, the inset is the same at every
frame. -/
theorem retimes_keep (C : Curves) : ∀ (rs : List (Rat × Rat × Transition)) {a b : Track} {d : Rat},
    Keeps a b d → ∀ time, (retimes C rs a).value C time - (retimes C rs b).value C time = d
  | [], _, _, _, h, time => edge_constant C h.1 h.2.1 h.2.2 time
  | (t0, s, τ) :: rs, _, _, _, h, time => retimes_keep C rs (retime_keeps C h t0 s τ) time

/-- A row growing 100 → 150 over a second with a bubble bottom 10 points
above it, retimed at 0.5 s onto a one-second timing. Retiming both keeps
the inset 10 at 1 s; retiming the row alone lets the bubble finish first,
2.5 points past the row's edge at 1 s (the inset off by 12.5). -/
def rowH : Track := ⟨1, 100, 150, 0, oneSecond⟩
def bubble : Track := ⟨1, 90, 140, 0, oneSecond⟩

theorem alone_drifts :
    (retime linear (1 / 2) (1 / 2) oneSecond rowH).value linear 1 -
        (retime linear (1 / 2) (1 / 2) oneSecond bubble).value linear 1 = 10 ∧
      (retime linear (1 / 2) (1 / 2) oneSecond rowH).value linear 1 - bubble.value linear 1 = 10 - 25 / 2 := by
  decide +kernel

/-! ## Width and height on their own timings

A row whose width and height animate on different timings reports both.
Moving all content onto whichever came last puts one axis off its row's
timing; moving each axis's key paths onto its own row animation keeps both
insets. -/

inductive Axis
  | x
  | y
deriving DecidableEq

/-- The retimings that reach an axis: those of its own row animation. -/
def onAxis (ax : Axis) (rs : List (Axis × Rat × Rat × Transition)) : List (Rat × Rat × Transition) :=
  (rs.filter (·.1 = ax)).map (·.2)

/-- **Each axis on its own row animation keeps both insets**, through any
interleaving of width and height retimings. -/
theorem axes_keep (C : Curves) (rs : List (Axis × Rat × Rat × Transition)) {ax ay bx byy : Track} {dx dy : Rat}
    (hx : Keeps ax bx dx) (hy : Keeps ay byy dy) (time : Rat) :
    (retimes C (onAxis .x rs) ax).value C time - (retimes C (onAxis .x rs) bx).value C time = dx ∧
      (retimes C (onAxis .y rs) ay).value C time - (retimes C (onAxis .y rs) byy).value C time = dy :=
  ⟨retimes_keep C _ hx time, retimes_keep C _ hy time⟩

def twoSeconds : Transition := ⟨2, 0, 1⟩

/-- The row's height grows 100 → 150 over a second while its width animates
over two, both added at 0. Content moved onto the last one added (the
width's) leaves the bubble's bottom 35 points above the row's edge at 1 s,
not 10; on the height's timing it stays at 10. -/
theorem last_wins_drifts :
    rowH.value linear 1 - (retime linear 0 0 twoSeconds bubble).value linear 1 = 35 ∧
      rowH.value linear 1 - (retime linear 0 0 oneSecond bubble).value linear 1 = 10 := by
  decide +kernel

/-! ## Content replaced with no timing

When a pass replaces a row's content with no timing of its own (an
immediate pass, or one whose time is up), the row's running height
animation is moved: the same timing, toward the new destination, from its
old start plus the destination's change. Each running inner animation is
moved the same way, from its old view onto its match. -/

/-- The moved-track rule: same timing, start shifted by the destination's
change, new destination `T`. -/
def shift (tr : Track) (T : Rat) : Track := { tr with src := tr.src + (T - tr.dst), dst := T }

/-- **A moved track is the old one plus its destination's change**, at
every time. -/
theorem shift_value (C : Curves) (tr : Track) (T time : Rat) :
    (shift tr T).value C time = tr.value C time + (T - tr.dst) := by
  have hp : (shift tr T).progress C time = tr.progress C time := progress_timing C rfl rfl time
  unfold Track.value; rw [hp]; simp only [shift]; grind

/-- **Moving both keeps the inset**: when the new destinations keep the
inset, the moved row and the moved content keep it at every frame. -/
theorem shift_keeps {a b : Track} {d : Rat} (h : Keeps a b d) {Ta Tb : Rat} (hT : Ta - Tb = d) :
    Keeps (shift a Ta) (shift b Tb) d := by
  refine ⟨⟨h.1.1, h.1.2⟩, ?_, hT⟩
  simp only [shift]; have := h.2.1; have := h.2.2; grind

/-- **Moving only the row puts the inset off by its change**: content left
on its old animation is `T - a.dst` off at every frame. -/
theorem row_only_off (C : Curves) {a b : Track} {d : Rat} (h : Keeps a b d) (T time : Rat) :
    (shift a T).value C time - b.value C time = d + (T - a.dst) := by
  rw [shift_value, ← edge_constant C h.1 h.2.1 h.2.2 time]; grind

/-! ## Content that joins a running animation

Content that arrives after its pass joins the row's running height
animation at its phase: at the join the timing is already at progress `p`.
Starting from the snapshot `s` shows `s + (T - s) p` there, a jump of
`(T - s) p`; starting from `(s - T p) / (1 - p)` shows `s`. -/

/-- **Joining from the snapshot jumps** by `(T - s) p` at the join. -/
theorem join_jump (C : Curves) (tr : Track) (s time : Rat) :
    ({ tr with src := s } : Track).value C time - s = (tr.dst - s) * tr.progress C time := by
  have hp : ({ tr with src := s } : Track).progress C time = tr.progress C time := progress_timing C rfl rfl time
  simp only [Track.value, hp]; grind

/-- **Joining from the corrected start is continuous**: with progress `p`
short of 1 at the join, a start of `(s - T p) / (1 - p)` shows `s` there and
still ends at `T`. -/
theorem join_exact (C : Curves) (tr : Track) (s time : Rat) (hp : tr.progress C time ≠ 1) :
    ({ tr with src := (s - tr.dst * tr.progress C time) / (1 - tr.progress C time) } : Track).value C time = s := by
  have hq : ({ tr with src := (s - tr.dst * tr.progress C time) / (1 - tr.progress C time) } : Track).progress C time =
      tr.progress C time := progress_timing C rfl rfl time
  simp only [Track.value, hq]
  generalize tr.progress C time = p at hp ⊢
  have hne : 1 - p ≠ 0 := by grind
  have e : (s - tr.dst * p) / (1 - p) * (1 - p) = s - tr.dst * p := Rat.div_mul_cancel hne
  grind

/-! ### Clamping the corrected start

The corrected start `(s - T p) / (1 - p)` always lies on the far side of `s`
from `T`, so clamping it to the range between `s` and `T` always gives `s`:
the clamp is the snapshot start, with the full jump. What the corrected
start shows from the join on is `s + (T - s) (P - p) / (1 - p)` at progress
`P`: the row's remaining progress rescaled, within `[s, T]` for a curve that
moves forward without overshooting; an overshoot past the end is magnified
by `1 / (1 - p)`. -/

def joinStart (s T p : Rat) : Rat := (s - T * p) / (1 - p)

def clampTo (lo hi x : Rat) : Rat := max lo (min hi x)

/-- **The corrected start lies beyond the snapshot**, away from the target. -/
theorem joinStart_beyond {s T p : Rat} (hp0 : 0 ≤ p) (hp1 : p < 1) :
    (s ≤ T → joinStart s T p ≤ s) ∧ (T ≤ s → s ≤ joinStart s T p) := by
  have hq : 0 < 1 - p := by grind
  have e : joinStart s T p * (1 - p) = s - T * p := Rat.div_mul_cancel (by grind)
  have tp : ∀ {a b : Rat}, a ≤ b → a * p ≤ b * p := fun h => by
    have := Rat.mul_le_mul_of_nonneg_left h hp0; grind
  refine ⟨fun h => ?_, fun h => ?_⟩
  · refine Rat.not_lt.mp fun hlt => ?_
    have := Rat.mul_lt_mul_of_pos_right hlt hq
    have := tp h; grind
  · refine Rat.not_lt.mp fun hlt => ?_
    have := Rat.mul_lt_mul_of_pos_right hlt hq
    have := tp h; grind

/-- **The corrected start is inside `[s, T]` only when there is nothing to
correct**: at the start of the animation (`p = 0`) or with nothing to move
(`s = T`). So a clamp that keeps it whenever it is inside never keeps it
otherwise. -/
theorem joinStart_inside_iff {s T p : Rat} (hp0 : 0 ≤ p) (hp1 : p < 1) :
    (min s T ≤ joinStart s T p ∧ joinStart s T p ≤ max s T) ↔ (p = 0 ∨ s = T) := by
  have hq : 0 < 1 - p := by grind
  have e : joinStart s T p * (1 - p) = s - T * p := Rat.div_mul_cancel (by grind)
  obtain ⟨h1, h2⟩ := joinStart_beyond (s := s) (T := T) hp0 hp1
  constructor
  · intro ⟨lo, hi⟩
    have hs : joinStart s T p = s := by
      simp only [Rat.min_def, Rat.max_def] at lo hi
      by_cases h : s ≤ T
      · have := h1 h; simp only [h, ite_true] at lo; grind
      · have := h2 (by grind); simp only [h, ite_false] at hi; grind
    rw [hs] at e
    have : p * (T - s) = 0 := by grind
    rcases Rat.mul_eq_zero.mp this with h | h
    · exact Or.inl h
    · exact Or.inr (by grind)
  · intro h
    have hs : joinStart s T p = s := by
      rcases h with rfl | rfl
      · simp only [joinStart]; grind
      · have := Rat.div_mul_cancel (a := s - s * p) (show 1 - p ≠ 0 by grind)
        simp only [joinStart]
        have e2 : s - s * p = s * (1 - p) := by grind
        rw [e2, Rat.mul_div_cancel (show 1 - p ≠ 0 by grind)] at *
    rw [hs]; simp only [Rat.min_def, Rat.max_def]; constructor <;> split <;> grind

/-- **Clamped, the corrected start is the snapshot**: for any progress short
of 1 at the join. -/
theorem clamped_is_snapshot {s T p : Rat} (hp0 : 0 ≤ p) (hp1 : p < 1) :
    clampTo (min s T) (max s T) (joinStart s T p) = s := by
  obtain ⟨h1, h2⟩ := joinStart_beyond (s := s) (T := T) hp0 hp1
  simp only [clampTo, Rat.min_def, Rat.max_def]
  by_cases h : s ≤ T
  · have := h1 h; repeat (first | split | grind)
  · have := h2 (by grind); repeat (first | split | grind)

/-- **So the clamped join jumps by the whole `(T - s) p`**, as the snapshot
start does. -/
theorem clamped_jump (C : Curves) (tr : Track) (s time : Rat) (hp0 : 0 ≤ tr.progress C time)
    (hp1 : tr.progress C time < 1) :
    ({ tr with src := clampTo (min s tr.dst) (max s tr.dst) (joinStart s tr.dst (tr.progress C time)) } :
      Track).value C time - s = (tr.dst - s) * tr.progress C time := by
  rw [clamped_is_snapshot hp0 hp1]; exact join_jump C tr s time

/-- **The corrected start shows the remaining progress rescaled**: at any
time it is `s + (T - s) (P - p) / (1 - p)`, with `p` the progress at the join
and `P` the progress then. -/
theorem join_remap (C : Curves) (tr : Track) (s join time : Rat) (hp : tr.progress C join ≠ 1) :
    ({ tr with src := joinStart s tr.dst (tr.progress C join) } : Track).value C time =
      s + (tr.dst - s) * (tr.progress C time - tr.progress C join) / (1 - tr.progress C join) := by
  have hq : ({ tr with src := joinStart s tr.dst (tr.progress C join) } : Track).progress C time =
      tr.progress C time := progress_timing C rfl rfl time
  unfold Track.value; rw [hq]; simp only [joinStart]
  have : 1 - tr.progress C join ≠ 0 := by grind
  grind

/-- **From the join on, it stays between the snapshot and the target** while
the progress moves forward and doesn't overshoot. -/
theorem join_within {s T p P : Rat} (hp1 : p < 1) (hpP : p ≤ P) (hP1 : P ≤ 1) :
    min s T ≤ s + (T - s) * (P - p) / (1 - p) ∧ s + (T - s) * (P - p) / (1 - p) ≤ max s T := by
  have hq : 0 < 1 - p := by grind
  generalize hr : (P - p) / (1 - p) = r
  have e : r * (1 - p) = P - p := by rw [← hr]; exact Rat.div_mul_cancel (by grind)
  have r0 : 0 ≤ r := Rat.not_lt.mp fun h => by
    have := Rat.mul_lt_mul_of_pos_right h hq; grind
  have r1 : r ≤ 1 := Rat.not_lt.mp fun h => by
    have := Rat.mul_lt_mul_of_pos_right h hq; grind
  have hm : (T - s) * (P - p) / (1 - p) = (T - s) * r := by rw [← hr]; grind
  rw [hm]
  simp only [Rat.min_def, Rat.max_def]
  by_cases h : s ≤ T
  · have a := Rat.mul_le_mul_of_nonneg_left r0 (show 0 ≤ T - s by grind)
    have b := Rat.mul_le_mul_of_nonneg_left r1 (show 0 ≤ T - s by grind)
    constructor <;> split <;> grind
  · have a := Rat.mul_le_mul_of_nonneg_left r0 (show 0 ≤ s - T by grind)
    have b := Rat.mul_le_mul_of_nonneg_left r1 (show 0 ≤ s - T by grind)
    constructor <;> split <;> grind

/-- The sample: a bubble's bottom 90 → 140 joining at progress 0.5 corrects
to a start of 40, outside `[90, 140]`; clamped it is 90 and shows 115 at the
join. Joining at 0.9 under a spring 5% past its end, the corrected start
shows 165, 25 past the target, where the row (100 → 150) is 2.5 past. -/
theorem clamp_sample :
    joinStart 90 140 (1 / 2) = 40 ∧ clampTo 90 140 (joinStart 90 140 (1 / 2)) = 90 ∧
      (90 : Rat) + (140 - 90) * (21 / 20 - 9 / 10) / (1 - 9 / 10) = 165 ∧
      (100 : Rat) + (150 - 100) * (21 / 20) = 305 / 2 := by
  refine ⟨by unfold joinStart; decide +kernel, by unfold clampTo joinStart; decide +kernel,
    by decide +kernel, by decide +kernel⟩

/-! ### The planned late join: remap where the row can't overshoot

Content arriving late joins the row's running size animation with the
corrected start when that animation can't overshoot, taking `p` from the
row's value, `(presented - from) / (to - from)`; otherwise it catches up on
a short timing of its own. -/

/-- **The row's value progress is its curve progress**: reading `p` from the
presented value gives the `progress` `join_remap` uses. -/
theorem valueProgress_eq (C : Curves) (tr : Track) (time : Rat) (h : tr.dst ≠ tr.src) :
    (tr.value C time - tr.src) / (tr.dst - tr.src) = tr.progress C time := by
  have hne : tr.dst - tr.src ≠ 0 := by grind
  have e : tr.value C time - tr.src = tr.progress C time * (tr.dst - tr.src) := by
    simp only [Track.value]; grind
  rw [e, Rat.div_def, Rat.mul_assoc, Rat.mul_inv_cancel _ hne, Rat.mul_one]

/-- A cubic Bézier timing curve's progress at parameter `u`, with control
points' `y` values `y1` and `y2` (ends at 0 and 1). -/
def bezierY (y1 y2 u : Rat) : Rat := 3 * y1 * u * (1 - u) * (1 - u) + 3 * y2 * u * u * (1 - u) + u * u * u

/-- Its slope over 3, in Bernstein form. -/
def bezierSlope (y1 y2 u : Rat) : Rat :=
  (1 - u) * (1 - u) * y1 + 2 * u * (1 - u) * (y2 - y1) + u * u * (1 - y2)

/-- **With control `y` values in `[0, 1]` the slope is never negative**: as
`(y1 - y2)(1 - 2u)² + y2 (1 - u)² + (1 - y1) u²` when `y2 < y1`, and term by
term otherwise. -/
theorem bezierSlope_nonneg {y1 y2 u : Rat} (h1 : 0 ≤ y1 ∧ y1 ≤ 1) (h2 : 0 ≤ y2 ∧ y2 ≤ 1) (hu : 0 ≤ u ∧ u ≤ 1) :
    0 ≤ bezierSlope y1 y2 u := by
  have a := Rat.mul_nonneg (Rat.mul_nonneg (show 0 ≤ 1 - u by grind) (show 0 ≤ 1 - u by grind)) h1.1
  have c := Rat.mul_nonneg (Rat.mul_nonneg hu.1 hu.1) (show 0 ≤ 1 - y2 by grind)
  by_cases h : y1 ≤ y2
  · have b := Rat.mul_nonneg (Rat.mul_nonneg (Rat.mul_nonneg (show (0 : Rat) ≤ 2 by decide) hu.1)
      (show 0 ≤ 1 - u by grind)) (show 0 ≤ y2 - y1 by grind)
    simp only [bezierSlope]; grind
  · have sq : 0 ≤ (1 - 2 * u) * (1 - 2 * u) := by
      by_cases hs : 0 ≤ 1 - 2 * u
      · exact Rat.mul_nonneg hs hs
      · have : 0 ≤ -(1 - 2 * u) := by grind
        have := Rat.mul_nonneg this this; grind
    have d' := Rat.mul_nonneg (show 0 ≤ y1 - y2 by grind) sq
    have e := Rat.mul_nonneg (Rat.mul_nonneg (show 0 ≤ 1 - u by grind) (show 0 ≤ 1 - u by grind)) h2.1
    have f := Rat.mul_nonneg (Rat.mul_nonneg hu.1 hu.1) (show 0 ≤ 1 - y1 by grind)
    have id : bezierSlope y1 y2 u = (y1 - y2) * ((1 - 2 * u) * (1 - 2 * u)) + (1 - u) * (1 - u) * y2 +
        u * u * (1 - y1) := by simp only [bezierSlope]; grind
    rw [id]; grind

/-- Simpson's rule is exact for a cubic: the rise over `[a, b]` is the width
times the slope's weighted mean at the ends and the middle. -/
theorem bezier_rise (y1 y2 a b : Rat) :
    2 * (bezierY y1 y2 b - bezierY y1 y2 a) =
      (b - a) * (bezierSlope y1 y2 a + 4 * bezierSlope y1 y2 ((a + b) / 2) + bezierSlope y1 y2 b) := by
  simp only [bezierY, bezierSlope]; grind

/-- **A Bézier curve with control `y` values in `[0, 1]` never moves
backward**, and so stays within `[0, 1]`. -/
theorem bezier_mono {y1 y2 a b : Rat} (h1 : 0 ≤ y1 ∧ y1 ≤ 1) (h2 : 0 ≤ y2 ∧ y2 ≤ 1) (ha : 0 ≤ a) (hab : a ≤ b)
    (hb : b ≤ 1) : bezierY y1 y2 a ≤ bezierY y1 y2 b := by
  have s1 := bezierSlope_nonneg h1 h2 ⟨ha, by grind⟩
  have s2 := bezierSlope_nonneg h1 h2 (u := (a + b) / 2) ⟨by grind, by grind⟩
  have s3 := bezierSlope_nonneg h1 h2 ⟨by grind, hb⟩
  have := Rat.mul_nonneg (show 0 ≤ b - a by grind) (show 0 ≤ bezierSlope y1 y2 a +
    4 * bezierSlope y1 y2 ((a + b) / 2) + bezierSlope y1 y2 b by grind)
  have := bezier_rise y1 y2 a b
  grind

theorem bezier_bounded {y1 y2 u : Rat} (h1 : 0 ≤ y1 ∧ y1 ≤ 1) (h2 : 0 ≤ y2 ∧ y2 ≤ 1) (hu : 0 ≤ u ∧ u ≤ 1) :
    0 ≤ bezierY y1 y2 u ∧ bezierY y1 y2 u ≤ 1 := by
  have lo := bezier_mono h1 h2 (Rat.le_refl) hu.1 hu.2
  have hi := bezier_mono h1 h2 hu.1 hu.2 (Rat.le_refl)
  simp only [bezierY] at lo hi ⊢; grind

/-- **Solved for time, it still never moves backward**: Core Animation
finds the parameter whose `x` is the phase; with `x` nondecreasing (its
control `x` values in `[0, 1]`, the same lemma), a later phase has a later
parameter, so a later progress. -/
theorem solved_mono {x y : Rat → Rat} (hx : ∀ a b, 0 ≤ a → a ≤ b → b ≤ 1 → x a ≤ x b)
    (hy : ∀ a b, 0 ≤ a → a ≤ b → b ≤ 1 → y a ≤ y b) (solve : Rat → Rat) (hs : ∀ φ, x (solve φ) = φ)
    (hr : ∀ φ, 0 ≤ solve φ ∧ solve φ ≤ 1) {φ1 φ2 : Rat} (h : φ1 ≤ φ2) : y (solve φ1) ≤ y (solve φ2) := by
  rcases Rat.le_iff_lt_or_eq.mp h with hl | he
  · have : solve φ1 ≤ solve φ2 := Rat.not_lt.mp fun hlt => by
      have := hx _ _ (hr φ2).1 (Rat.le_of_lt hlt) (hr φ1).2
      rw [hs, hs] at this; grind
    exact hy _ _ (hr φ1).1 this (hr φ2).2
  · rw [he]; exact Rat.le_refl

/-- **The catch-up starts where the content is and lands on the target**:
its own track from the snapshot `s` to `T`, begun at the join. -/
theorem catchup_ends (C : Curves) (s T join d : Rat) (c f : Nat) (hd : 0 < d) :
    let tr : Track := ⟨0, s, T, join, ⟨d, c, f⟩⟩
    tr.value C join = s ∧ ∀ time, join + d ≤ time → tr.value C time = T := by
  refine ⟨value_start C _ hd, fun time ht => value_at_rest C _ fun h => ?_⟩
  have := h.2; simp only [Track.deadline] at this
  have : max 0 d = d := by simp only [Rat.max_def]; split <;> grind
  grind

/-- The sample: a row 100 → 150 over a second, a bubble 10 above its edge.
At 0.5 s an immediate pass grows the row's destination to 170. Moving both
keeps the inset 10 at 0.75 s; moving only the row leaves it 30. Content
joining at 0.5 s from a snapshot of 90 toward 140 shows 115 there. -/
theorem shift_sample :
    (shift rowH 170).value linear (3 / 4) - (shift bubble 160).value linear (3 / 4) = 10 ∧
      (shift rowH 170).value linear (3 / 4) - bubble.value linear (3 / 4) = 30 ∧
      ({ bubble with src := 90 } : Track).value linear (1 / 2) = 115 := by
  decide +kernel

end UltraProofs.ListContent
