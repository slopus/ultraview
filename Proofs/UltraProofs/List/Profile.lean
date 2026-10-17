/-!
# The keyboard's clamped overlap as a viewport profile

The chat's composer sits on the keyboard's top while that is above the
chat's resting edge and on the resting edge otherwise: its inset follows
`max(resting, keyboard)`, the keyboard's overlap clamped. The list's
viewport correction follows the same clamped height through a sampled
progress profile (`KeyboardViewportMotion.viewportCurve`), and the bar
copies the viewport's animation. This file states what the samples give.

* `profile_exact`: at every sample, the start plus the move times the
  profile is the clamped height, so the viewport and the bar are on the
  clamped keyboard edge there.
* `profile_unit`, `profile_mono`: with the keyboard's progress in `[0, 1]`
  and moving forward, every profile sample is in `[0, 1]` and they never go
  back, so the profile is a curve `Curves.Bounded` and coverage reads (the
  samples' hull) describe.
* `kink_bound`, `kink_bound_down`: between two samples the linear
  interpolation of the clamped height is never below the clamp of the
  keyboard's own interpolated edge, and above it by at most a quarter of
  that segment's travel, only in the segment where the keyboard crosses the
  resting edge.
-/

namespace UltraProofs.ListProfile

/-- `KeyboardViewportMotion.height(at:)`: the overlap at the keyboard's
progress `φ` from `b` to `e`, clamped to the resting height `r`. -/
def height (r b e φ : Rat) : Rat := max r (b + (e - b) * φ)

/-- One sample of `viewportCurve(physicalProgress:)`. -/
def prog (r b e φ : Rat) : Rat := (height r b e φ - height r b e 0) / (height r b e 1 - height r b e 0)

theorem max_mono {r x y : Rat} (h : x ≤ y) : max r x ≤ max r y := by
  simp only [Rat.max_def]; split <;> split <;> grind

/-- **On the clamped edge at every sample.** -/
theorem profile_exact (r b e φ : Rat) (hD : height r b e 1 - height r b e 0 ≠ 0) :
    height r b e 0 + (height r b e 1 - height r b e 0) * prog r b e φ = height r b e φ := by
  have := Rat.div_mul_cancel (a := height r b e φ - height r b e 0) hD
  simp only [prog]; grind

/-- The clamped height lies between its ends. -/
theorem height_between (r b e φ : Rat) (h0 : 0 ≤ φ) (h1 : φ ≤ 1) :
    (b ≤ e → height r b e 0 ≤ height r b e φ ∧ height r b e φ ≤ height r b e 1) ∧
      (e ≤ b → height r b e 1 ≤ height r b e φ ∧ height r b e φ ≤ height r b e 0) := by
  refine ⟨fun h => ⟨max_mono ?_, max_mono ?_⟩, fun h => ⟨max_mono ?_, max_mono ?_⟩⟩
  · have := Rat.mul_nonneg (show 0 ≤ e - b by grind) h0; grind
  · have := Rat.mul_le_mul_of_nonneg_left h1 (show 0 ≤ e - b by grind); grind
  · have := Rat.mul_le_mul_of_nonneg_left h1 (show 0 ≤ b - e by grind); grind
  · have := Rat.mul_nonneg (show 0 ≤ b - e by grind) h0; grind

theorem height_mono (r b e : Rat) {φ ψ : Rat} (h : φ ≤ ψ) :
    (b ≤ e → height r b e φ ≤ height r b e ψ) ∧ (e ≤ b → height r b e ψ ≤ height r b e φ) := by
  refine ⟨fun hb => max_mono ?_, fun hb => max_mono ?_⟩
  · have := Rat.mul_le_mul_of_nonneg_left h (show 0 ≤ e - b by grind); grind
  · have := Rat.mul_le_mul_of_nonneg_left h (show 0 ≤ b - e by grind); grind

theorem sq_pos {D : Rat} (h : D ≠ 0) : 0 < D * D := by
  by_cases hp : 0 < D
  · exact Rat.mul_pos hp hp
  · have := Rat.mul_pos (show 0 < -D by grind) (show 0 < -D by grind); grind

/-- A ratio is in `[0, 1]` when its numerator times the denominator is. -/
theorem ratio_unit {a D : Rat} (hD : D ≠ 0) (h0 : 0 ≤ a * D) (h1 : a * D ≤ D * D) : 0 ≤ a / D ∧ a / D ≤ 1 := by
  have e : a / D * D = a := Rat.div_mul_cancel hD
  have hp := sq_pos hD
  refine ⟨Rat.not_lt.mp fun hq => ?_, Rat.not_lt.mp fun hq => ?_⟩
  · have := Rat.mul_lt_mul_of_pos_right hq hp
    have : a * D = a / D * (D * D) := by rw [← e]; grind
    grind
  · have := Rat.mul_lt_mul_of_pos_right hq hp
    have : a * D = a / D * (D * D) := by rw [← e]; grind
    grind

/-- **Every sample is in `[0, 1]`.** -/
theorem profile_unit (r b e φ : Rat) (h0 : 0 ≤ φ) (h1 : φ ≤ 1) (hD : height r b e 1 - height r b e 0 ≠ 0) :
    0 ≤ prog r b e φ ∧ prog r b e φ ≤ 1 := by
  obtain ⟨up, down⟩ := height_between r b e φ h0 h1
  apply ratio_unit hD
  · by_cases h : b ≤ e
    · obtain ⟨a, c⟩ := up h; exact Rat.mul_nonneg (by grind) (by grind)
    · obtain ⟨a, c⟩ := down (by grind)
      have := Rat.mul_nonneg (show 0 ≤ -(height r b e φ - height r b e 0) by grind)
        (show 0 ≤ -(height r b e 1 - height r b e 0) by grind)
      grind
  · by_cases h : b ≤ e
    · obtain ⟨a, c⟩ := up h
      exact Rat.mul_le_mul_of_nonneg_right (by grind) (by grind)
    · obtain ⟨a, c⟩ := down (by grind)
      have := Rat.mul_le_mul_of_nonneg_right (show -(height r b e φ - height r b e 0) ≤
        -(height r b e 1 - height r b e 0) by grind) (show 0 ≤ -(height r b e 1 - height r b e 0) by grind)
      grind

/-- **The samples never go back** while the keyboard moves forward. -/
theorem profile_mono (r b e : Rat) {φ ψ : Rat} (h : φ ≤ ψ) (hD : height r b e 1 - height r b e 0 ≠ 0) :
    prog r b e φ ≤ prog r b e ψ := by
  have key : 0 ≤ (height r b e ψ - height r b e φ) * (height r b e 1 - height r b e 0) := by
    obtain ⟨up, down⟩ := height_mono r b e h
    obtain ⟨up1, down1⟩ := height_mono r b e (show (0 : Rat) ≤ 1 by decide)
    by_cases hb : b ≤ e
    · have := up hb; have := up1 hb
      exact Rat.mul_nonneg (by grind) (by grind)
    · have := down (by grind); have := down1 (by grind)
      have := Rat.mul_nonneg (show 0 ≤ -(height r b e ψ - height r b e φ) by grind)
        (show 0 ≤ -(height r b e 1 - height r b e 0) by grind)
      grind
  simp only [prog]
  generalize height r b e 1 - height r b e 0 = D at hD key ⊢
  generalize height r b e ψ = hψ at key ⊢
  generalize height r b e φ = hφ at key ⊢
  generalize height r b e 0 = h0
  have hm : (hψ - hφ) / D * D = hψ - hφ := Rat.div_mul_cancel hD
  have hq : 0 ≤ (hψ - hφ) / D := by
    refine Rat.not_lt.mp fun hn => ?_
    have := Rat.mul_lt_mul_of_pos_right hn (sq_pos hD)
    have : (hψ - hφ) * D = (hψ - hφ) / D * (D * D) := by rw [← hm]; grind
    grind
  have hsplit : (hψ - h0) / D - (hφ - h0) / D = (hψ - hφ) / D := by simp only [Rat.div_def]; grind
  grind

/-- Linear interpolation across a segment. -/
def interp (f0 f1 t : Rat) : Rat := (1 - t) * f0 + t * f1

theorem max_of_le {r x : Rat} (h : r ≤ x) : max r x = x := by simp [Rat.max_def, h]
theorem max_of_ge {r x : Rat} (h : x ≤ r) : max r x = r := by
  simp only [Rat.max_def]; split <;> grind

/-- **Between samples, rising**: across a segment where the keyboard's
interpolated edge rises by `Δ`, the interpolated clamp is never below the
clamped edge and above it by at most `Δ / 4`. -/
theorem kink_bound (r x0 Δ t : Rat) (hΔ : 0 ≤ Δ) (ht0 : 0 ≤ t) (ht1 : t ≤ 1) :
    max r (x0 + Δ * t) ≤ interp (max r x0) (max r (x0 + Δ)) t ∧
      4 * (interp (max r x0) (max r (x0 + Δ)) t - max r (x0 + Δ * t)) ≤ Δ := by
  have m0 : r ≤ max r x0 ∧ x0 ≤ max r x0 := by simp only [Rat.max_def]; split <;> grind
  have m1 : r ≤ max r (x0 + Δ) ∧ x0 + Δ ≤ max r (x0 + Δ) := by simp only [Rat.max_def]; split <;> grind
  refine ⟨?_, ?_⟩
  · have a1 := Rat.mul_le_mul_of_nonneg_left m0.1 (show 0 ≤ 1 - t by grind)
    have a2 := Rat.mul_le_mul_of_nonneg_left m1.1 ht0
    have b1 := Rat.mul_le_mul_of_nonneg_left m0.2 (show 0 ≤ 1 - t by grind)
    have b2 := Rat.mul_le_mul_of_nonneg_left m1.2 ht0
    simp only [interp, Rat.max_def]; split <;> grind
  · have dt : 0 ≤ Δ * t := Rat.mul_nonneg hΔ ht0
    have dt1 : Δ * t ≤ Δ := by have := Rat.mul_le_mul_of_nonneg_left ht1 hΔ; grind
    by_cases ha : r ≤ x0
    · rw [max_of_le ha, max_of_le (show r ≤ x0 + Δ by grind), max_of_le (show r ≤ x0 + Δ * t by grind)]
      simp only [interp]; grind
    by_cases hb : x0 + Δ ≤ r
    · rw [max_of_ge (show x0 ≤ r by grind), max_of_ge hb, max_of_ge (show x0 + Δ * t ≤ r by grind)]
      simp only [interp]; grind
    -- The keyboard crosses the resting edge inside the segment.
    rw [max_of_ge (show x0 ≤ r by grind), max_of_le (show r ≤ x0 + Δ by grind)]
    have hpos : 0 < Δ := by grind
    obtain ⟨a, rfl⟩ : ∃ a, r = x0 + a := ⟨r - x0, by grind⟩
    have sq : 0 ≤ (Δ - 2 * a) * (Δ - 2 * a) := by
      by_cases hs : 0 ≤ Δ - 2 * a
      · exact Rat.mul_nonneg hs hs
      · have := Rat.mul_nonneg (show 0 ≤ -(Δ - 2 * a) by grind) (show 0 ≤ -(Δ - 2 * a) by grind); grind
    have i2 : Δ * Δ - 4 * ((Δ - a) * a) = (Δ - 2 * a) * (Δ - 2 * a) := by grind
    -- `4 d ≤ Δ` from `Δ (4 d) ≤ Δ Δ`.
    have divide : ∀ d : Rat, Δ * (4 * d) ≤ Δ * Δ → 4 * d ≤ Δ := fun d hd =>
      Rat.not_lt.mp fun hn => by have := Rat.mul_lt_mul_of_pos_left hn hpos; grind
    by_cases hc : x0 + Δ * t ≤ x0 + a
    · rw [max_of_ge hc]
      have hd : interp (x0 + a) (x0 + Δ) t - (x0 + a) = t * (Δ - a) := by simp only [interp]; grind
      rw [hd]; apply divide
      have p1 := Rat.mul_le_mul_of_nonneg_left (show Δ * t ≤ a by grind) (show 0 ≤ Δ - a by grind)
      have i1 : Δ * (4 * (t * (Δ - a))) = 4 * ((Δ - a) * (Δ * t)) := by grind
      grind
    · rw [max_of_le (show x0 + a ≤ x0 + Δ * t by grind)]
      have hd : interp (x0 + a) (x0 + Δ) t - (x0 + Δ * t) = (1 - t) * a := by simp only [interp]; grind
      rw [hd]; apply divide
      have p1 := Rat.mul_le_mul_of_nonneg_left (show Δ - Δ * t ≤ Δ - a by grind) (show 0 ≤ a by grind)
      have i1 : Δ * (4 * ((1 - t) * a)) = 4 * (a * (Δ - Δ * t)) := by grind
      have i3 : a * (Δ - a) = (Δ - a) * a := by grind
      grind

/-- **Between samples, falling**: the same bound with the travel `-Δ`. -/
theorem kink_bound_down (r x0 Δ t : Rat) (hΔ : Δ ≤ 0) (ht0 : 0 ≤ t) (ht1 : t ≤ 1) :
    max r (x0 + Δ * t) ≤ interp (max r x0) (max r (x0 + Δ)) t ∧
      4 * (interp (max r x0) (max r (x0 + Δ)) t - max r (x0 + Δ * t)) ≤ -Δ := by
  have k := kink_bound r (x0 + Δ) (-Δ) (1 - t) (by grind) (by grind) (by grind)
  have e1 : x0 + Δ + -Δ * (1 - t) = x0 + Δ * t := by grind
  have e2 : x0 + Δ + -Δ = x0 := by grind
  have e3 : interp (max r (x0 + Δ)) (max r x0) (1 - t) = interp (max r x0) (max r (x0 + Δ)) t := by
    simp only [interp]; grind
  rw [e1, e2, e3] at k
  exact k

end UltraProofs.ListProfile
