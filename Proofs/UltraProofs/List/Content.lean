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

end UltraProofs.ListContent
