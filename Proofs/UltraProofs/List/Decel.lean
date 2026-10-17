/-!
# Deceleration and bounce, frame by frame

Models `ScrollAxis.step(milliseconds:)` (ScrollMath.swift) away from the
moment the motion crosses an edge. Inside the edges a step of `dt`
milliseconds coasts: the offset moves by `v · r · (1 - q) / (1 - r) · m` and
the velocity becomes `v · q`, with `r` the rate, `m` the multiplier and
`q = r ^ dt`. Outside, `spring` pulls the offset toward the boundary `b` with
stiffness `k = 0.99 ^ dt`. The stepped engine steps once per display frame
(`1/120` s or longer), while the keyframe engine and the stepped engine's
coverage prediction bake the same axis in `1/120` s steps
(`ScrollTrajectory(baking:)`). That `pow` turns sums of times into products
is the hypothesis `Decay`, a fact about real powers.

* `coast_compose`, `spring_compose`: two steps are one step of their total
  time, so `coast_frames`, `spring_frames`: any frames with the same total
  time give the same offset and velocity. `engines_agree`,
  `springs_agree`, `sixty_is_two_onetwenty`: a 60 Hz engine and a 120 Hz
  baking agree exactly at every frame they share, while both coast inside
  the edges or both spring toward the same boundary.
* `coast_between`: a coast moves monotonically from its start toward its
  end, so when one step's destination is inside the edges, the
  intermediate frames of a split step are too: splitting never changes
  which branch a step takes while it coasts.
* `coast_monotone`, `coast_rest`: a coast never reverses or speeds up, and
  never passes `o + v · r · m / (1 - r)`.

The step that crosses an edge interpolates its coast time linearly and so
depends on the frame length, as does the frame on which the axis settles
(`|v| < 0.01`, then a snap of at most half a point). Those are outside these
theorems.
-/

namespace UltraProofs.ListDecel

/-- `pow(base, ·)` on nonnegative times: one at zero, sums to products,
and in `(0, 1]`. -/
structure Decay where
  f : Rat → Rat
  zero : f 0 = 1
  add : ∀ a b, 0 ≤ a → 0 ≤ b → f (a + b) = f a * f b
  pos : ∀ t, 0 ≤ t → 0 < f t
  le_one : ∀ t, 0 ≤ t → f t ≤ 1

/-- An offset and a velocity (points per millisecond). -/
structure S where
  offset : Rat
  velocity : Rat
deriving DecidableEq

/-- The coast branch of `step`, with `q = rate ^ dt`. -/
def coast (r m q : Rat) (s : S) : S :=
  ⟨s.offset + s.velocity * r * (1 - q) / (1 - r) * m, s.velocity * q⟩

/-- `spring(milliseconds:)` toward `b`, with `q = rate ^ dt` and
`k = 0.99 ^ dt`. -/
def spring (r b q k : Rat) (s : S) : S :=
  ⟨b + k * (s.offset - b) + s.velocity * r * k * (1 - q) / (1 - r), s.velocity * q * k⟩

theorem coast_compose {r : Rat} (hr : r ≠ 1) (m q1 q2 : Rat) (s : S) :
    coast r m q2 (coast r m q1 s) = coast r m (q1 * q2) s := by
  have h : 1 - r ≠ 0 := fun e => hr (by grind)
  simp only [coast, S.mk.injEq]; constructor <;> grind

theorem spring_compose {r : Rat} (hr : r ≠ 1) (b q1 k1 q2 k2 : Rat) (s : S) :
    spring r b q2 k2 (spring r b q1 k1 s) = spring r b (q1 * q2) (k1 * k2) s := by
  have h : 1 - r ≠ 0 := fun e => hr (by grind)
  simp only [spring, S.mk.injEq]; constructor <;> grind

/-- Frames of the given lengths, coasting. -/
def coasts (D : Decay) (r m : Rat) (s : S) (dts : List Rat) : S :=
  dts.foldl (fun s dt => coast r m (D.f dt) s) s

/-- Frames of the given lengths, springing toward `b`. -/
def springs (D K : Decay) (r b : Rat) (s : S) (dts : List Rat) : S :=
  dts.foldl (fun s dt => spring r b (D.f dt) (K.f dt) s) s

theorem sum_nonneg : ∀ dts : List Rat, (∀ t ∈ dts, 0 ≤ t) → 0 ≤ dts.sum
  | [], _ => by simp
  | t :: ts, h => by
    simp only [List.sum_cons]
    have := h t (List.mem_cons_self ..)
    have := sum_nonneg ts fun x hx => h x (List.mem_cons_of_mem _ hx)
    grind

/-- **Coasting frames are one step of their total time.** -/
theorem coast_frames (D : Decay) {r : Rat} (hr : r ≠ 1) (m : Rat) :
    ∀ (dts : List Rat) (s : S), (∀ t ∈ dts, 0 ≤ t) → coasts D r m s dts = coast r m (D.f dts.sum) s
  | [], s, _ => by
    simp only [coasts, List.foldl_nil, List.sum_nil, D.zero]
    cases s; simp only [coast, S.mk.injEq]; constructor <;> grind
  | t :: ts, s, h => by
    have ht := h t (List.mem_cons_self ..)
    have hts : ∀ x ∈ ts, 0 ≤ x := fun x hx => h x (List.mem_cons_of_mem _ hx)
    have ih := coast_frames D hr m ts (coast r m (D.f t) s) hts
    simp only [coasts, List.foldl_cons] at ih ⊢
    rw [ih, coast_compose hr, List.sum_cons, D.add t ts.sum ht (sum_nonneg ts hts)]

/-- **Springing frames are one step of their total time.** -/
theorem spring_frames (D K : Decay) {r : Rat} (hr : r ≠ 1) (b : Rat) :
    ∀ (dts : List Rat) (s : S), (∀ t ∈ dts, 0 ≤ t) →
      springs D K r b s dts = spring r b (D.f dts.sum) (K.f dts.sum) s
  | [], s, _ => by
    simp only [springs, List.foldl_nil, List.sum_nil, D.zero, K.zero]
    cases s; simp only [spring, S.mk.injEq]; constructor <;> grind
  | t :: ts, s, h => by
    have ht := h t (List.mem_cons_self ..)
    have hts : ∀ x ∈ ts, 0 ≤ x := fun x hx => h x (List.mem_cons_of_mem _ hx)
    have ih := spring_frames D K hr b ts (spring r b (D.f t) (K.f t) s) hts
    simp only [springs, List.foldl_cons] at ih ⊢
    rw [ih, spring_compose hr, List.sum_cons,
      D.add t ts.sum ht (sum_nonneg ts hts), K.add t ts.sum ht (sum_nonneg ts hts)]

/-- **Any two frame sequences of the same length in time agree**: a 60 Hz
engine and a 120 Hz baking land on the same offset and velocity. -/
theorem engines_agree (D : Decay) {r : Rat} (hr : r ≠ 1) (m : Rat) (s : S) (a b : List Rat)
    (ha : ∀ t ∈ a, 0 ≤ t) (hb : ∀ t ∈ b, 0 ≤ t) (hs : a.sum = b.sum) :
    coasts D r m s a = coasts D r m s b := by
  rw [coast_frames D hr m a s ha, coast_frames D hr m b s hb, hs]

theorem springs_agree (D K : Decay) {r : Rat} (hr : r ≠ 1) (bd : Rat) (s : S) (a b : List Rat)
    (ha : ∀ t ∈ a, 0 ≤ t) (hb : ∀ t ∈ b, 0 ≤ t) (hs : a.sum = b.sum) :
    springs D K r bd s a = springs D K r bd s b := by
  rw [spring_frames D K hr bd a s ha, spring_frames D K hr bd b s hb, hs]

/-- Two 1/120 s frames are one 1/60 s frame (in milliseconds). -/
theorem sixty_is_two_onetwenty (D : Decay) {r : Rat} (hr : r ≠ 1) (m : Rat) (s : S) :
    coasts D r m s [1000 / 60] = coasts D r m s [1000 / 120, 1000 / 120] :=
  engines_agree D hr m s _ _ (by simp; decide +kernel) (by simp; decide +kernel) (by decide +kernel)

/-! ## A coast is monotone -/

theorem travel_nonneg {r m v q : Rat} (hr0 : 0 < r) (hr1 : r < 1) (hm : 0 ≤ m) (hv : 0 ≤ v) (hq : q ≤ 1) :
    0 ≤ v * r * (1 - q) / (1 - r) * m := by
  have h1 : 0 < 1 - r := by grind
  rw [Rat.div_def]
  exact Rat.mul_nonneg (Rat.mul_nonneg (Rat.mul_nonneg (Rat.mul_nonneg hv (Rat.le_of_lt hr0)) (by grind))
    (Rat.le_of_lt (Rat.inv_pos.mpr h1))) hm

/-- **A coast never reverses or speeds up**: moving forward, the offset
does not decrease and the velocity stays in `[0, v]`. (Backward motion is
the mirror image.) -/
theorem coast_monotone {r m q : Rat} (hr0 : 0 < r) (hr1 : r < 1) (hm : 0 ≤ m) (hq0 : 0 ≤ q) (hq : q ≤ 1)
    (s : S) (hv : 0 ≤ s.velocity) :
    s.offset ≤ (coast r m q s).offset ∧ 0 ≤ (coast r m q s).velocity ∧ (coast r m q s).velocity ≤ s.velocity := by
  have := travel_nonneg (v := s.velocity) (q := q) hr0 hr1 hm hv hq
  refine ⟨by simp only [coast]; grind, Rat.mul_nonneg hv hq0, ?_⟩
  simp only [coast]
  have := Rat.mul_le_mul_of_nonneg_left hq hv
  grind

/-- **A coast never passes its rest**, `o + v · r · m / (1 - r)`. -/
theorem coast_rest {r m q : Rat} (hr0 : 0 < r) (hr1 : r < 1) (hm : 0 ≤ m) (hq0 : 0 ≤ q)
    (s : S) (hv : 0 ≤ s.velocity) :
    (coast r m q s).offset ≤ s.offset + s.velocity * r / (1 - r) * m := by
  have h1 : 0 < 1 - r := by grind
  have hk : 0 ≤ s.velocity * r / (1 - r) * m := by
    have := travel_nonneg (v := s.velocity) (q := 0) hr0 hr1 hm hv (by decide)
    have e : s.velocity * r * (1 - 0) / (1 - r) * m = s.velocity * r / (1 - r) * m := by grind
    rw [e] at this; exact this
  have e : s.velocity * r * (1 - q) / (1 - r) * m = s.velocity * r / (1 - r) * m * (1 - q) := by
    simp only [Rat.div_def]; grind
  simp only [coast, e]
  have := Rat.mul_le_mul_of_nonneg_left (show 1 - q ≤ 1 by grind) hk
  grind

/-- **A split coast stays between its ends**: the frame after `q1` of a
coast to `q1 · q2` lies between the start and the end. So when the whole
step's destination is inside the (interval of the) edges, so is every
intermediate frame, and the split takes the same branch. -/
theorem coast_between {r m q1 q2 : Rat} (hr0 : 0 < r) (hr1 : r < 1) (hm : 0 ≤ m)
    (hq1 : 0 ≤ q1) (hq1' : q1 ≤ 1) (hq2 : 0 ≤ q2) (hq2' : q2 ≤ 1) (s : S) (hv : 0 ≤ s.velocity) :
    s.offset ≤ (coast r m q1 s).offset ∧ (coast r m q1 s).offset ≤ (coast r m (q1 * q2) s).offset := by
  have hne : r ≠ 1 := by grind
  refine ⟨(coast_monotone hr0 hr1 hm hq1 hq1' s hv).1, ?_⟩
  rw [← coast_compose hne]
  exact (coast_monotone hr0 hr1 hm hq2 hq2' _ (Rat.mul_nonneg hv hq1)).1

end UltraProofs.ListDecel
