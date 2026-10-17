import UltraProofs.List.Insets

/-!
# The flight band covers the flight

Models `ScrollTrajectory.sample(at:)` and `extent(from:through:)`
(ScrollTrajectory.swift) and `ScrollFlight.coveredOffsets(at:horizon:)`
(ScrollCore.swift). A trajectory is a list of samples with strictly
increasing times, read as the piecewise-linear function through them,
constant before the first and after the last. `extent` takes the minimum and
maximum of the function at both ends of the interval and of every vertex
strictly inside it; `UltraListView.handleScroll` hands that range, shifted by
the flight's coordinate shift and summed with the viewport track's bounds, to
`ListWindow.rebalance`.

* `sample_in_extent`: at every time in the interval the trajectory lies in
  its extent, so the extent is a true envelope (it is also the tightest one,
  since its bounds are values the trajectory takes).
* `flight_in_band`: a flight's offset at every time in
  `[time, time + horizon]` lies in `coveredOffsets(at: time, horizon:)`.
* `flight_rows_kept`: with `ListInsets.sum_covers`, a rebalance around that
  band and the viewport track's bounds keeps every loaded row that the
  flight shows, under any viewport delta in those bounds, until the
  horizon.

The binary searches in `sample(at:)` and `extent` are modeled by their
results: the segment whose end is the first sample at or after the time,
and the samples strictly between the ends.
-/

namespace UltraProofs.ListFlight

open UltraProofs.ListWindow UltraProofs.ListInsets

/-- `ScrollTrajectory.Sample` (its velocity plays no part here). -/
structure Sample where
  time : Rat
  offset : Rat

/-- `ScrollTrajectory.init`'s precondition: times strictly increase. -/
def Sorted : List Sample → Prop
  | a :: b :: rest => a.time < b.time ∧ Sorted (b :: rest)
  | _ => True

/-- The segment from `a` to `b` at `t`: `a.offset + (b.offset - a.offset) * phase`. -/
def lerp (a b : Sample) (t : Rat) : Rat :=
  a.offset + (b.offset - a.offset) * ((t - a.time) / (b.time - a.time))

/-- `ScrollTrajectory.sample(at:).offset`. -/
def sampleAt : List Sample → Rat → Rat
  | [], _ => 0
  | [a], _ => a.offset
  | a :: b :: rest, t =>
    if t ≤ a.time then a.offset else if t ≤ b.time then lerp a b t else sampleAt (b :: rest) t

/-- The vertices `extent` folds in: strictly between the ends. -/
def inside (L : List Sample) (s e : Rat) : List Rat :=
  (L.filter fun x => decide (s < x.time ∧ x.time < e)).map (·.offset)

/-- `extent(from: s, through: e)`. -/
def extent (L : List Sample) (s e : Rat) : Rat × Rat :=
  ((inside L s e).foldl min (min (sampleAt L s) (sampleAt L e)),
   (inside L s e).foldl max (max (sampleAt L s) (sampleAt L e)))

/-! ## Folds and envelopes -/

theorem foldl_min_le : ∀ (vs : List Rat) (init : Rat),
    vs.foldl min init ≤ init ∧ ∀ v ∈ vs, vs.foldl min init ≤ v
  | [], init => ⟨Rat.le_refl, by simp⟩
  | x :: vs, init => by
    obtain ⟨h1, h2⟩ := foldl_min_le vs (min init x)
    refine ⟨by simp only [List.foldl_cons]; grind, fun v hv => ?_⟩
    simp only [List.foldl_cons]
    rcases List.mem_cons.mp hv with rfl | hv
    · grind
    · exact h2 v hv

theorem foldl_max_ge : ∀ (vs : List Rat) (init : Rat),
    init ≤ vs.foldl max init ∧ ∀ v ∈ vs, v ≤ vs.foldl max init
  | [], init => ⟨Rat.le_refl, by simp⟩
  | x :: vs, init => by
    obtain ⟨h1, h2⟩ := foldl_max_ge vs (max init x)
    refine ⟨by simp only [List.foldl_cons]; grind, fun v hv => ?_⟩
    simp only [List.foldl_cons]
    rcases List.mem_cons.mp hv with rfl | hv
    · grind
    · exact h2 v hv

/-- The values the extent takes the minimum and maximum of. -/
def vals (L : List Sample) (s e : Rat) : List Rat := sampleAt L s :: sampleAt L e :: inside L s e

/-- `x` lies between two of the values `V`. -/
def Btw (x : Rat) (V : List Rat) : Prop := (∃ v ∈ V, v ≤ x) ∧ ∃ w ∈ V, x ≤ w

theorem btw_self {x : Rat} {V : List Rat} (h : x ∈ V) : Btw x V := ⟨⟨x, h, Rat.le_refl⟩, ⟨x, h, Rat.le_refl⟩⟩

theorem btw_mono {x : Rat} {V W : List Rat} (h : ∀ v ∈ V, v ∈ W) (hb : Btw x V) : Btw x W :=
  ⟨let ⟨v, hv, h'⟩ := hb.1; ⟨v, h v hv, h'⟩, let ⟨w, hw, h'⟩ := hb.2; ⟨w, h w hw, h'⟩⟩

theorem extent_bounds (L : List Sample) (s e x : Rat) (h : Btw x (vals L s e)) :
    (extent L s e).1 ≤ x ∧ x ≤ (extent L s e).2 := by
  obtain ⟨⟨v, hv, hvx⟩, ⟨w, hw, hxw⟩⟩ := h
  have lo := foldl_min_le (inside L s e) (min (sampleAt L s) (sampleAt L e))
  have hi := foldl_max_ge (inside L s e) (max (sampleAt L s) (sampleAt L e))
  constructor
  · have : (extent L s e).1 ≤ v := by
      simp only [extent]
      rcases List.mem_cons.mp hv with rfl | hv
      · grind
      rcases List.mem_cons.mp hv with rfl | hv
      · grind
      exact lo.2 v hv
    grind
  · have : w ≤ (extent L s e).2 := by
      simp only [extent]
      rcases List.mem_cons.mp hw with rfl | hw
      · grind
      rcases List.mem_cons.mp hw with rfl | hw
      · grind
      exact hi.2 w hw
    grind

/-! ## One segment -/

theorem lerp_affine (a b : Sample) (t : Rat) :
    lerp a b t = a.offset + (b.offset - a.offset) / (b.time - a.time) * (t - a.time) := by
  simp only [lerp, Rat.div_def]; grind

theorem lerp_left (a b : Sample) : lerp a b a.time = a.offset := by
  rw [lerp_affine]; grind

theorem lerp_right (a b : Sample) (h : a.time < b.time) : lerp a b b.time = b.offset := by
  rw [lerp_affine, Rat.div_mul_cancel (by grind)]; grind

/-- **A segment between two of its points lies between their values.** -/
theorem lerp_between (a b : Sample) {u t w : Rat} (hu : u ≤ t) (hw : t ≤ w) :
    Btw (lerp a b t) [lerp a b u, lerp a b w] := by
  simp only [lerp_affine]
  generalize (b.offset - a.offset) / (b.time - a.time) = k
  have d1 : a.offset + k * (t - a.time) - (a.offset + k * (u - a.time)) = k * (t - u) := by grind
  have d2 : a.offset + k * (w - a.time) - (a.offset + k * (t - a.time)) = k * (w - t) := by grind
  rcases Rat.le_total (a := 0) (b := k) with hk | hk
  · have p1 := Rat.mul_nonneg hk (show 0 ≤ t - u by grind)
    have p2 := Rat.mul_nonneg hk (show 0 ≤ w - t by grind)
    exact ⟨⟨_, List.mem_cons_self .., by grind⟩, ⟨_, List.mem_cons_of_mem _ (List.mem_cons_self ..), by grind⟩⟩
  · have p1 := Rat.mul_nonneg (show 0 ≤ -k by grind) (show 0 ≤ t - u by grind)
    have p2 := Rat.mul_nonneg (show 0 ≤ -k by grind) (show 0 ≤ w - t by grind)
    have e1 : -k * (t - u) = -(k * (t - u)) := by grind
    have e2 : -k * (w - t) = -(k * (w - t)) := by grind
    exact ⟨⟨_, List.mem_cons_of_mem _ (List.mem_cons_self ..), by grind⟩, ⟨_, List.mem_cons_self .., by grind⟩⟩

/-! ## The envelope -/

theorem head_at (b : Sample) (rest : List Sample) {s : Rat} (h : s ≤ b.time) :
    sampleAt (b :: rest) s = b.offset := by
  cases rest with
  | nil => rfl
  | cons c rest => simp [sampleAt, h]

theorem sampleAt_seg (a b : Sample) (rest : List Sample) {t : Rat} (h1 : a.time < t) (h2 : t ≤ b.time) :
    sampleAt (a :: b :: rest) t = lerp a b t := by
  simp [sampleAt, Rat.not_le.mpr h1, h2]

theorem sampleAt_past (a b : Sample) (rest : List Sample) {t : Rat} (hab : a.time < b.time)
    (h : b.time < t) : sampleAt (a :: b :: rest) t = sampleAt (b :: rest) t := by
  simp [sampleAt, Rat.not_le.mpr (show a.time < t by grind), Rat.not_le.mpr h]

/-- **The trajectory lies in its extent** at every time of the interval. -/
theorem btw_vals : ∀ (L : List Sample), Sorted L → ∀ {s t e : Rat}, s ≤ t → t ≤ e →
    Btw (sampleAt L t) (vals L s e)
  | [], _, s, t, e, _, _ => btw_self (by simp [vals, sampleAt])
  | [a], _, s, t, e, _, _ => btw_self (by simp [vals, sampleAt])
  | a :: b :: rest, hs, s, t, e, hst, hte => by
    obtain ⟨hab, hs'⟩ := hs
    by_cases h1 : t ≤ a.time
    · have : sampleAt (a :: b :: rest) t = sampleAt (a :: b :: rest) s := by
        simp [sampleAt, h1, show s ≤ a.time by grind]
      rw [this]; exact btw_self (List.mem_cons_self ..)
    have h1 : a.time < t := Rat.not_le.mp h1
    by_cases h2 : t ≤ b.time
    · rw [sampleAt_seg a b rest h1 h2]
      -- The left end of the segment's part in `[s, e]`.
      have hl : lerp a b (max s a.time) ∈ vals (a :: b :: rest) s e := by
        by_cases hsa : s ≤ a.time
        · rw [show max s a.time = a.time by grind, lerp_left]
          have : sampleAt (a :: b :: rest) s = a.offset := by simp [sampleAt, hsa]
          rw [← this]; exact List.mem_cons_self ..
        · rw [show max s a.time = s by grind, ← sampleAt_seg a b rest (Rat.not_le.mp hsa) (by grind)]
          exact List.mem_cons_self ..
      by_cases hsb : s = b.time
      · subst hsb
        have : t = b.time := by grind
        subst this
        rw [← sampleAt_seg a b rest h1 Rat.le_refl]; exact btw_self (List.mem_cons_self ..)
      have hr : lerp a b (min e b.time) ∈ vals (a :: b :: rest) s e := by
        by_cases heb : e ≤ b.time
        · rw [show min e b.time = e by grind, ← sampleAt_seg a b rest (by grind) heb]
          exact List.mem_cons_of_mem _ (List.mem_cons_self ..)
        · rw [show min e b.time = b.time by grind, lerp_right a b hab]
          refine List.mem_cons_of_mem _ (List.mem_cons_of_mem _ ?_)
          simp only [inside, List.mem_map, List.mem_filter]
          exact ⟨b, ⟨by simp, by simp; constructor <;> grind⟩, rfl⟩
      exact btw_mono (fun v hv => by
        simp only [List.mem_cons, List.not_mem_nil, or_false] at hv
        rcases hv with rfl | rfl
        · exact hl
        · exact hr) (lerp_between a b (show max s a.time ≤ t by grind) (show t ≤ min e b.time by grind))
    · have h2 : b.time < t := Rat.not_le.mp h2
      rw [sampleAt_past a b rest hab h2]
      refine btw_mono (fun v hv => ?_) (btw_vals (b :: rest) hs' hst hte)
      simp only [vals, List.mem_cons] at hv ⊢
      rcases hv with rfl | rfl | hv
      · by_cases hsb : b.time < s
        · left; rw [sampleAt_past a b rest hab hsb]
        · rw [head_at b rest (Rat.not_lt.mp hsb)]
          by_cases hsb' : s = b.time
          · left; subst hsb'; rw [sampleAt_seg a b rest hab Rat.le_refl, lerp_right a b hab]
          · right; right
            simp only [inside, List.mem_map, List.mem_filter]
            exact ⟨b, ⟨by simp, by simp; constructor <;> grind⟩, rfl⟩
      · right; left; rw [sampleAt_past a b rest hab (by grind)]
      · right; right
        simp only [inside, List.mem_map, List.mem_filter] at hv ⊢
        obtain ⟨x, ⟨hx, hc⟩, rfl⟩ := hv
        exact ⟨x, ⟨List.mem_cons_of_mem _ hx, hc⟩, rfl⟩

/-- **`extent(from:through:)` is an envelope.** -/
theorem sample_in_extent (L : List Sample) (hs : Sorted L) {s t e : Rat} (hst : s ≤ t) (hte : t ≤ e) :
    (extent L s e).1 ≤ sampleAt L t ∧ sampleAt L t ≤ (extent L s e).2 :=
  extent_bounds L s e _ (btw_vals L hs hst hte)

/-! ## Flights -/

/-- `ScrollFlight`. -/
structure Flight where
  samples : List Sample
  begin : Rat
  shift : Rat

/-- `ScrollFlight.offset(at:)`. -/
def Flight.offset (f : Flight) (τ : Rat) : Rat := sampleAt f.samples (τ - f.begin) + f.shift

/-- `ScrollFlight.coveredOffsets(at:horizon:)`. -/
def Flight.covered (f : Flight) (time horizon : Rat) : Rat × Rat :=
  let x := extent f.samples (time - f.begin) (time - f.begin + max 0 horizon)
  (x.1 + f.shift, x.2 + f.shift)

/-- **The flight stays in its band** from `time` to `time + horizon`. -/
theorem flight_in_band (f : Flight) (hs : Sorted f.samples) {time horizon τ : Rat} (h0 : time ≤ τ)
    (h1 : τ ≤ time + max 0 horizon) :
    (f.covered time horizon).1 ≤ f.offset τ ∧ f.offset τ ≤ (f.covered time horizon).2 := by
  have := sample_in_extent f.samples hs (s := time - f.begin) (t := τ - f.begin)
    (e := time - f.begin + max 0 horizon) (by grind) (by grind)
  simp only [Flight.covered, Flight.offset]
  grind

/-- **Rows the flight shows stay loaded until the horizon.** Rebalancing
around the flight's band plus the viewport track's bounds `[vl, vh]`, as
`handleScroll` does, keeps every loaded row shown at the flight's offset at
any time up to the horizon under any viewport delta in those bounds. -/
theorem flight_rows_kept (f : Flight) (hs : Sorted f.samples) (count : Nat) (measure : Nat → Option Meas)
    (pf af : Nat) (w : Window) (offset time horizon τ vl vh v height margin : Rat) (hm : 0 ≤ margin)
    (h0 : time ≤ τ) (h1 : τ ≤ time + max 0 horizon) (hv : vl ≤ v ∧ v ≤ vh) (r : Row) (hr : r ∈ w)
    (hshown : Shown height (f.offset τ + v) r) :
    r ∈ rebalanceIn count (min offset ((f.covered time horizon).1 + vl) - margin)
      (max offset ((f.covered time horizon).2 + vh) + height + margin) measure pf af w :=
  sum_covers count measure pf af w offset _ _ vl vh _ v height margin hm (flight_in_band f hs h0 h1) hv r hr hshown

end UltraProofs.ListFlight
