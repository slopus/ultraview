import UltraProofs.List.Animation

/-!
# Independent size and position motion

Retiming (`ListAnimation.fixed_pass_sync`) keeps rows in sync by putting
every in-flight geometry track on the newest pass's timing, so a row that is
still growing gives up its own timing when a later pass moves rows. Keeping
each motion on its own timing instead needs each presented value to be its
base plus a sum of additive layers, one per timing, as stacked additive
layer animations are.

* `superpose`: if the terms of a linear relation split into groups, each
  on one timing and each keeping the relation's share at its start and end,
  the relation holds at every frame, whatever the timings and curves.
* `layered_touches`: a row growing from 100 to 150 over a second, and both
  it and the row below it moving up 40 points in a pass half a second in.
  With the lower row following the growth on a layer with the growth's
  timing and the move on a layer with the pass's, the rows touch at every
  frame, and the growth keeps its timing.
* `single_layer_opens`: folding the lower row's remaining growth delta into
  the move's single track, while the height keeps the growth's timing,
  opens a 12.5-point overlap at 1 s that closes when both settle.
* `follower_exact`: a follower layer that copies a height track's start and
  transition, from `src - dst` to 0, is the height's remaining change at
  every time.
* `prefix_seam`, `prefix_anchor`, `prefix_rest`: rows of a linked window,
  each following every height above it and none above the anchor (the
  coefficient of source `s` on row `i` is `[s < i] - [s < anchor]`), with
  their own move layers on top: the gap between rows `i` and `i + 1` is row
  `i`'s presented height plus the difference of their moves, whatever each
  height's timing; the anchor row moves only by its own move; at rest each
  row is at its settled `y` plus its move. So rows touch at every frame
  exactly when adjacent moves agree, however many heights animate on
  however many timings.
* `common_seam`, `position_top`, `anchor_common`: the seam holds with any
  term every row shares. A coefficient of `common s + [s < i] + own·[s = i]`
  on source `s`'s follower, less `own` times the row's presented height,
  is the shared-term form; `common s = -[s < anchor]` is the prefix form.
* `pinned_ends`, `pinned_left`, `pinned_right`, `pinned_kink`,
  `kink_bound`: a pinned anchor's common coefficient is the chord of the
  boundary `max 0 (h - half) - h` between the old and new heights. Both ends
  are exact; on one side of `half` every height is; across it the chord is
  above the boundary by at most `(half - lo)(hi - half) / (hi - lo)`.
* `residual_exact`, `composed_seam`: a follower that is a height track's
  residual scaled by its coefficient, on the height's clock, is the
  coefficient times the height's remaining change; so rows composed of a
  settled place, a move, those followers and a shared layout layer touch
  at every frame up to their moves.
-/

namespace UltraProofs.ListLayers

open UltraProofs.ListAnimation

/-- Terms on one timing, and the share of the relation they keep. -/
structure Group where
  terms : List Term
  start : Rat
  timing : Transition
  share : Rat

def Group.Keeps (g : Group) : Prop :=
  OneTiming g.terms g.start g.timing ∧ startSum g.terms = g.share ∧ endSum g.terms = g.share

theorem nowSum_append (C : Curves) (time : Rat) (a b : List Term) :
    nowSum C time (a ++ b) = nowSum C time a + nowSum C time b := by
  simp [nowSum, List.map_append, List.sum_append]

/-- **Layers on their own timings keep every linear relation.** -/
theorem superpose (C : Curves) (time : Rat) : ∀ gs : List Group, (∀ g ∈ gs, g.Keeps) →
    nowSum C time (gs.flatMap (·.terms)) = (gs.map (·.share)).sum
  | [], _ => by simp [nowSum]
  | g :: gs, h => by
    have hg := h g (List.mem_cons_self ..)
    rw [List.flatMap_cons, nowSum_append, affine_sync C hg.1 hg.2.1 hg.2.2 time,
      superpose C time gs (fun g' hg' => h g' (List.mem_cons_of_mem _ hg'))]
    simp

/-! ## A growing row moved mid-growth -/

/-- The growth: one second from 0. The move: one second from 0.5. -/
def growth : Transition := oneSecond
def moveAt : Rat := 1 / 2

/-- The upper row's height, 100 to 150, absolute. -/
def height : Track := ⟨1, 100, 150, 0, growth⟩
/-- The lower row's layer following the growth: −50 to 0. -/
def follow : Track := ⟨1, -50, 0, 0, growth⟩
/-- Both rows' move layers: +40 to 0 under bases moved up by 40. -/
def moveA : Track := ⟨2, 40, 0, moveAt, oneSecond⟩
def moveB : Track := ⟨2, 40, 0, moveAt, oneSecond⟩

/-- The lower row's top minus the upper row's bottom, layered: upper row at
`-40 + moveA`, height `height`; lower row at `110 + follow + moveB`. -/
def layeredGap (t : Rat) : Rat :=
  (110 + follow.value linear t + moveB.value linear t) -
    (-40 + moveA.value linear t + height.value linear t)

/-- **Layered, the rows touch at every frame.** -/
theorem layered_touches (t : Rat) : layeredGap t = 0 := by
  have h := superpose linear t
    [⟨[⟨-1, 0, height⟩, ⟨1, 0, follow⟩], 0, growth, -150⟩,
     ⟨[⟨-1, -40, moveA⟩, ⟨1, 110, moveB⟩], moveAt, oneSecond, 150⟩]
    (by
      intro g hg
      simp only [List.mem_cons, List.not_mem_nil, or_false] at hg
      rcases hg with rfl | rfl <;>
        refine ⟨fun e he => ?_, ?_, ?_⟩ <;>
        first
        | (simp only [List.mem_cons, List.not_mem_nil, or_false] at he
           rcases he with rfl | rfl <;> exact ⟨rfl, rfl⟩)
        | (simp [startSum, endSum, height, follow, moveA, moveB]; decide +kernel))
  simp only [List.flatMap_cons, List.flatMap_nil, List.append_nil, List.cons_append, List.nil_append,
    nowSum, presented, List.map_cons, List.map_nil, List.sum_cons, List.sum_nil] at h
  simp only [layeredGap]
  grind

/-- Before the move the rows touch: upper at 0 with `height`, lower at 150
with `follow`. -/
theorem touches_before (t : Rat) : 150 + follow.value linear t - height.value linear t = 0 := by
  have := layered_touches t
  have hm : moveA.value linear t = moveB.value linear t := rfl
  simp only [layeredGap] at this
  grind

/-- The move pass with one track per key: the lower row's track restarts
from its presented delta at 0.5 s (`110 + 15` is where it was, 125) on the
move's timing, while the height keeps the growth's. -/
def single : Track := ⟨2, 15, 0, moveAt, oneSecond⟩

def singleGap (t : Rat) : Rat :=
  (110 + single.value linear t) - (-40 + moveA.value linear t + height.value linear t)

/-- **One track per key opens a gap.** The rows touch when the move starts
and once both settle, but at 1 s the lower row overlaps the upper one by
12.5 points. -/
theorem single_layer_opens :
    singleGap moveAt = 0 ∧ singleGap 1 = -25 / 2 ∧ singleGap (3 / 2) = 0 := by
  decide +kernel

/-! ## Followers of every height above -/

/-- **A follower copying a height's timing is its remaining change.** -/
theorem follower_exact (C : Curves) (h : Track) (g : Nat) (time : Rat) :
    (⟨g, h.src - h.dst, 0, h.start, h.transition⟩ : Track).value C time = h.value C time - h.dst := by
  rw [lerp C, lerp C h, progress_timing C (a := ⟨g, h.src - h.dst, 0, h.start, h.transition⟩) (b := h) rfl rfl time]
  grind

/-- `Σ_{s < n} f s`. -/
def pre (f : Nat → Rat) (n : Nat) : Rat := ((List.range n).map f).sum

theorem pre_succ (f : Nat → Rat) (n : Nat) : pre f (n + 1) = pre f n + f n := by
  simp [pre, List.range_succ, List.map_append, List.sum_append, Rat.add_zero]

/-- Row `i`'s presented top: its settled `y` in a window linked from `Y`
with settled heights `dst`, plus the followers of the heights above it less
those above the anchor `a` (each `h s - dst s`, the height's remaining
change), plus its own move `m i`. -/
def top (Y : Rat) (dst h m : Nat → Rat) (a i : Nat) : Rat :=
  (Y + pre dst i) + (pre (fun s => h s - dst s) i - pre (fun s => h s - dst s) a) + m i

/-- **Row `i + 1` starts where row `i` ends, up to their moves**, whatever
the presented heights `h` are, so whatever their timings. -/
theorem prefix_seam (Y : Rat) (dst h m : Nat → Rat) (a i : Nat) :
    top Y dst h m a (i + 1) - top Y dst h m a i = h i + (m (i + 1) - m i) := by
  simp only [top, pre_succ]; grind

/-- **The anchor moves only by its own move.** -/
theorem prefix_anchor (Y : Rat) (dst h m : Nat → Rat) (a : Nat) :
    top Y dst h m a a = Y + pre dst a + m a := by
  simp only [top]; grind

/-- **At rest every row is at its settled place plus its move.** -/
theorem prefix_rest (Y : Rat) (dst m : Nat → Rat) (a i : Nat) :
    top Y dst dst m a i = Y + pre dst i + m i := by
  have z : ∀ n, pre (fun s => dst s - dst s) n = 0 := by
    intro n; induction n with
    | zero => rfl
    | succ n ih => rw [pre_succ, ih]; grind
  simp only [top, z]; grind

/-- **Touching at every frame**: with every height on its own track and its
followers copying it, adjacent rows with equal moves touch at every time. -/
theorem prefix_touch (C : Curves) (Y : Rat) (hs : Nat → Track) (m : Nat → Rat → Rat) (a i : Nat)
    (hm : ∀ t, m (i + 1) t = m i t) (time : Rat) :
    top Y (fun s => (hs s).dst) (fun s => (hs s).value C time) (fun j => m j time) a (i + 1) =
      top Y (fun s => (hs s).dst) (fun s => (hs s).value C time) (fun j => m j time) a i +
        (hs i).value C time := by
  have := prefix_seam Y (fun s => (hs s).dst) (fun s => (hs s).value C time) (fun j => m j time) a i
  rw [hm time] at this; grind

/-! ## A term every row shares, and the coefficient form -/

/-- Row `i`'s presented top with the followers of the heights above it and a
term `common` every row shares: the anchor's compensation, or the pinned
boundary's secant. -/
def topWith (Y : Rat) (dst h m : Nat → Rat) (common : Rat) (i : Nat) : Rat :=
  (Y + pre dst i) + pre (fun s => h s - dst s) i + common + m i

theorem top_eq_topWith (Y : Rat) (dst h m : Nat → Rat) (a i : Nat) :
    top Y dst h m a i = topWith Y dst h m (-pre (fun s => h s - dst s) a) i := by
  simp only [top, topWith]; grind

/-- **The seam holds whatever the common term**: a term shared by every row
cancels between adjacent rows. -/
theorem common_seam (Y : Rat) (dst h m : Nat → Rat) (common : Rat) (i : Nat) :
    topWith Y dst h m common (i + 1) - topWith Y dst h m common i = h i + (m (i + 1) - m i) := by
  simp only [topWith, pre_succ]; grind

theorem pre_add (f g : Nat → Rat) (n : Nat) : pre (fun s => f s + g s) n = pre f n + pre g n := by
  induction n with
  | zero => simp [pre, Rat.add_zero]
  | succ n ih => rw [pre_succ, pre_succ, pre_succ, ih]; grind

theorem pre_below (x : Nat → Rat) (i : Nat) :
    ∀ n, pre (fun s => (if s < i then 1 else 0) * x s) n = pre x (min n i)
  | 0 => by simp [pre]
  | n + 1 => by
    rw [pre_succ, pre_below x i n]
    by_cases h : n < i
    · rw [Nat.min_eq_left (by omega), Nat.min_eq_left (by omega), pre_succ]; simp [h, Rat.one_mul]
    · rw [Nat.min_eq_right (by omega), Nat.min_eq_right (by omega)]; simp [h, Rat.add_zero]

theorem pre_at (x : Nat → Rat) (own : Rat) (i : Nat) :
    ∀ n, pre (fun s => (if s = i then own else 0) * x s) n = if i < n then own * x i else 0
  | 0 => by simp [pre]
  | n + 1 => by
    rw [pre_succ, pre_at x own i n]
    by_cases h : i < n
    · have : n ≠ i := by omega
      simp [h, this, show i < n + 1 by omega, Rat.add_zero]
    · by_cases e : n = i
      · subst e; simp [Rat.zero_add]
      · simp [h, e, show ¬i < n + 1 by omega, Rat.add_zero]

/-- Source `s`'s coefficient on row `i`: the shared `common s`, one for every
height above the row, and `own` for its own height (1 for a row placed by
its bottom edge, as an inverted list's rows are). -/
def coef (common : Nat → Rat) (own : Rat) (s i : Nat) : Rat :=
  common s + (if s < i then 1 else 0) + (if s = i then own else 0)

/-- Row `i`'s presented position among `n` rows: its settled place (its top,
plus `own` times its height), plus every source's follower `h s - dst s`
times its coefficient, plus its own move. -/
def position (Y : Rat) (dst h m common : Nat → Rat) (own : Rat) (n i : Nat) : Rat :=
  Y + pre dst i + own * dst i + pre (fun s => coef common own s i * (h s - dst s)) n + m i

/-- **The coefficient form is the shared-term form.** Less `own` times its
presented height, row `i`'s position is its top with the common term
`Σ common s · (h s - dst s)`, so `common_seam` covers it: rows touch at
every frame whatever `common` is, and each source's share of it is on that
source's height timing. -/
theorem position_top (Y : Rat) (dst h m common : Nat → Rat) (own : Rat) {n i : Nat} (hi : i < n) :
    position Y dst h m common own n i - own * h i =
      topWith Y dst h m (pre (fun s => common s * (h s - dst s)) n) i := by
  have split : (fun s => coef common own s i * (h s - dst s)) =
      fun s => (common s * (h s - dst s) + (if s < i then 1 else 0) * (h s - dst s)) +
        (if s = i then own else 0) * (h s - dst s) := by
    funext s; simp only [coef, Rat.add_mul]
  simp only [position, topWith, split, pre_add, pre_below, pre_at, hi, ite_true,
    Nat.min_eq_right (Nat.le_of_lt hi)]
  grind

/-- **The anchor's common term is the prefix form.** `common s = -[s < a]`
gives `top`. -/
theorem anchor_common (Y : Rat) (dst h m : Nat → Rat) {n a : Nat} (ha : a ≤ n) (i : Nat) :
    topWith Y dst h m (pre (fun s => -(if s < a then 1 else 0) * (h s - dst s)) n) i =
      top Y dst h m a i := by
  have neg : (fun s => -(if s < a then 1 else 0) * (h s - dst s)) =
      fun s => -1 * ((if s < a then 1 else 0) * (h s - dst s)) := by
    funext s; grind
  have scale : ∀ (c : Rat) (f : Nat → Rat) k, pre (fun s => c * f s) k = c * pre f k := by
    intro c f k; induction k with
    | zero => simp [pre]
    | succ k ih => rw [pre_succ, pre_succ, ih]; grind
  rw [top_eq_topWith, neg, scale, pre_below, Nat.min_eq_right ha]
  grind

/-! ## The pinned boundary's secant -/

/-- How far the rows shift for a pinned anchor of height `x`, in a viewport
of height `2 * half`. -/
def boundary (half x : Rat) : Rat := max 0 (x - half) - x

/-- The common coefficient on the pinned anchor's follower, its height going
from `a` to `b`. -/
def secant (half a b : Rat) : Rat :=
  if a = b then (if b > half then 0 else -1) else (boundary half b - boundary half a) / (b - a)

/-- The common term at the anchor's presented height `x`: the settled
boundary plus the coefficient times the follower `x - b`. -/
def pinned (half a b x : Rat) : Rat := boundary half b + secant half a b * (x - b)

/-- **The endpoints are exact**: at the start the term is the old boundary,
at rest the new one. -/
theorem pinned_ends (half a b : Rat) (hab : a ≠ b) :
    pinned half a b a = boundary half a ∧ pinned half a b b = boundary half b := by
  have hd : b - a ≠ 0 := fun h => hab (by grind)
  refine ⟨?_, by simp [pinned, Rat.sub_self, Rat.mul_zero, Rat.add_zero]⟩
  simp only [pinned, secant, hab, ite_false]
  have : (boundary half b - boundary half a) / (b - a) * (a - b) = -(boundary half b - boundary half a) := by
    rw [show a - b = -(b - a) by grind, Rat.mul_neg, Rat.div_mul_cancel hd]
  rw [this]; grind

theorem boundary_left {half x : Rat} (h : x ≤ half) : boundary half x = -x := by
  simp only [boundary]; rw [Rat.max_def]; split <;> grind

theorem boundary_right {half x : Rat} (h : half ≤ x) : boundary half x = -half := by
  simp only [boundary]; rw [Rat.max_def]; split <;> grind

/-- **On one side of the kink the secant is the boundary at every height**:
heights all at most `half`, or all at least `half`. -/
theorem pinned_left {half a b x : Rat} (ha : a ≤ half) (hb : b ≤ half) (hx : x ≤ half) :
    pinned half a b x = boundary half x := by
  have hs : secant half a b = -1 := by
    unfold secant
    by_cases e : a = b
    · simp only [e, ite_true, gt_iff_lt, Rat.not_lt.mpr hb, ite_false]
    · simp only [e, ite_false, boundary_left ha, boundary_left hb]
      have hd : b - a ≠ 0 := fun h => e (by grind)
      rw [show -b - -a = -1 * (b - a) by grind, Rat.div_def, Rat.mul_assoc, Rat.mul_inv_cancel _ hd,
        Rat.mul_one]
  simp only [pinned, hs, boundary_left hb, boundary_left hx]; grind

theorem pinned_right {half a b x : Rat} (hab : a ≠ b) (ha : half ≤ a) (hb : half ≤ b) (hx : half ≤ x) :
    pinned half a b x = boundary half x := by
  have hs : secant half a b = 0 := by
    simp only [secant, hab, ite_false, boundary_right ha, boundary_right hb, Rat.sub_self, Rat.div_def,
      Rat.zero_mul]
  simp only [pinned, hs, boundary_right hb, boundary_right hx]; grind

/-- **Across the kink it is not**: an anchor growing from 50 to 150 in a
200-point viewport puts the common term 25 points off the boundary at 100,
though both ends are exact. Rows still touch (`common_seam`); the path the
window takes is the chord, not the pinned rule. -/
theorem pinned_kink :
    pinned 100 50 150 50 = boundary 100 50 ∧ pinned 100 50 150 150 = boundary 100 150 ∧
      pinned 100 50 150 100 - boundary 100 100 = 25 := by
  decide +kernel

theorem secant_mul {half a b : Rat} (hab : a ≠ b) :
    secant half a b * (b - a) = boundary half b - boundary half a := by
  have hd : b - a ≠ 0 := fun h => hab (by grind)
  simp only [secant, hab, ite_false]; exact Rat.div_mul_cancel hd

theorem secant_symm {half a b : Rat} (hab : a ≠ b) : secant half a b = secant half b a := by
  have h1 := secant_mul (half := half) hab
  have h2 := secant_mul (half := half) (Ne.symm hab)
  have z : (secant half a b - secant half b a) * (b - a) = 0 := by grind
  rcases Rat.mul_eq_zero.mp z with h | h
  · grind
  · exact absurd (by grind) hab

/-- A growth and the matching shrink take the same chord. -/
theorem pinned_symm {half a b : Rat} (hab : a ≠ b) (x : Rat) :
    pinned half a b x = pinned half b a x := by
  have h2 := secant_mul (half := half) (Ne.symm hab)
  simp only [pinned, secant_symm hab]; grind

theorem kink_secant {half lo hi : Rat} (hl : lo ≤ half) (hh : half ≤ hi) (hne : lo ≠ hi) :
    (hi - lo) * secant half lo hi = lo - half := by
  rw [Rat.mul_comm, secant_mul hne, boundary_left hl, boundary_right hh]; grind

/-- **How far the chord leaves the boundary across the kink**: for heights
between `lo ≤ half ≤ hi`, growing or shrinking, the common term is above the
boundary by `(x - lo)(hi - half) / (hi - lo)` below the kink and
`(half - lo)(hi - x) / (hi - lo)` above it, so by at most
`(half - lo)(hi - half) / (hi - lo)`, reached at the kink. -/
theorem kink_bound {half lo hi a b x : Rat} (hl : lo ≤ half) (hh : half ≤ hi) (hlt : lo < hi)
    (hab : (a = lo ∧ b = hi) ∨ (a = hi ∧ b = lo)) (hx : lo ≤ x) (hxh : x ≤ hi) :
    0 ≤ (hi - lo) * (pinned half a b x - boundary half x) ∧
      (hi - lo) * (pinned half a b x - boundary half x) ≤ (half - lo) * (hi - half) := by
  have hne : lo ≠ hi := fun e => by grind
  have hp : pinned half a b x = pinned half lo hi x := by
    rcases hab with ⟨rfl, rfl⟩ | ⟨rfl, rfl⟩
    · rfl
    · exact pinned_symm (Ne.symm hne) x
  have hs : (hi - lo) * (secant half lo hi * (x - hi)) = (lo - half) * (x - hi) := by
    rw [← Rat.mul_assoc, kink_secant hl hh hne]
  rw [hp]
  by_cases hk : x ≤ half
  · have e : (hi - lo) * (pinned half lo hi x - boundary half x) = (x - lo) * (hi - half) := by
      simp only [pinned, boundary_left hk, boundary_right hh]; grind
    rw [e]
    exact ⟨Rat.mul_nonneg (by grind) (by grind),
      Rat.mul_le_mul_of_nonneg_right (by grind) (by grind)⟩
  · have hk' : half ≤ x := Rat.le_of_lt (Rat.not_le.mp hk)
    have e : (hi - lo) * (pinned half lo hi x - boundary half x) = (half - lo) * (hi - x) := by
      simp only [pinned, boundary_right hk', boundary_right hh]; grind
    rw [e]
    exact ⟨Rat.mul_nonneg (by grind) (by grind),
      Rat.mul_le_mul_of_nonneg_left (by grind) (by grind)⟩

/-! ## The list's composition -/

/-- `AnimationTrack.residual(multipliedBy:)`: the height track's remaining
change times `c`, on the height's own start and transition. -/
def residual (h : Track) (c : Rat) : Track := ⟨h.generation, (h.src - h.dst) * c, 0, h.start, h.transition⟩

/-- **A scaled follower is its coefficient times the height's remaining
change**, at every time, whatever the curve. -/
theorem residual_exact (C : Curves) (h : Track) (c time : Rat) :
    (residual h c).value C time = c * (h.value C time - h.dst) := by
  rw [lerp C, lerp C h, progress_timing C (a := residual h c) (b := h) rfl rfl time]
  simp only [residual]; grind

/-- Row `i`'s presented position as the list composes it at `time`: its
settled place (its top plus `own i` times its settled height), its own move
`m i`, one follower per height (source `s`'s residual with coefficient
`coef common (own i) s i`), and the layout layer `L` every row carries. -/
def composed (C : Curves) (Y : Rat) (hs : Nat → Track) (common own m : Nat → Rat) (L : Rat)
    (n i : Nat) (time : Rat) : Rat :=
  Y + pre (fun s => (hs s).dst) i + own i * (hs i).dst + m i + L +
    pre (fun s => (residual (hs s) (coef common (own i) s i)).value C time) n

theorem composed_position (C : Curves) (Y : Rat) (hs : Nat → Track) (common own m : Nat → Rat) (L : Rat)
    (n i : Nat) (time : Rat) :
    composed C Y hs common own m L n i time =
      position (Y + L) (fun s => (hs s).dst) (fun s => (hs s).value C time) m common (own i) n i := by
  have e : (fun s => (residual (hs s) (coef common (own i) s i)).value C time) =
      fun s => coef common (own i) s i * ((hs s).value C time - (hs s).dst) := by
    funext s; exact residual_exact C (hs s) _ time
  simp only [composed, position, e]; grind

/-- **Rows the list composes touch at every frame, up to their moves**: for
adjacent loaded rows, row `i + 1`'s top (its position less `own` times its
presented height) is row `i`'s top plus row `i`'s presented height plus the
difference of their moves. That holds at every time, for every height
clock, every common coefficient (anchor, pinned secant or none), and every
layout layer they share. -/
theorem composed_seam (C : Curves) (Y : Rat) (hs : Nat → Track) (common own m : Nat → Rat) (L : Rat)
    {n i : Nat} (hi : i + 1 < n) (time : Rat) :
    (composed C Y hs common own m L n (i + 1) time - own (i + 1) * (hs (i + 1)).value C time) -
      (composed C Y hs common own m L n i time - own i * (hs i).value C time) =
      (hs i).value C time + (m (i + 1) - m i) := by
  rw [composed_position, composed_position, position_top _ _ _ _ _ _ hi,
    position_top _ _ _ _ _ _ (Nat.lt_of_succ_lt hi)]
  exact common_seam _ _ _ _ _ i

end UltraProofs.ListLayers
