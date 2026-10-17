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
  `(s - T p) / (1 - p)` it is continuous.
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
