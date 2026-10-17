/-!
# List animation tracks: are animations in sync?

Models `AnimationTrack` and `ListAnimationModel` (ListAnimation.swift), and
what `AnimationController` sends to Core Animation (AnimationController.swift).

A track runs from `from` to `to`. Its value at `time` is
`from + (to - from) * progress`, where `progress` depends only on the
track's *timing*: its start time and its transition (duration, curve,
duration factor). A pass captures one `time` and passes one transition to
every `transition`/`replace` call, so every track a pass starts has the same
timing. Additive properties (row and attachment `positionY`/`positionX`, the
viewport offset) animate a delta from `old + current - new` to 0 on top of the
new settled value; size and opacity animate the value itself.

* `replace_starts_at_from`, `transition_continuous`: retargeting never jumps;
  the presented value at the pass time is the one before the pass.
* `lerp_sync`, `affine_sync`: tracks with one timing are one interpolation.
  Every presented value is `(1 - p) * start + p * end` with the same `p`, so
  any linear relation between presented values (two rows touching, a ghost
  welded to a row, content keeping its distance from an input) that holds at
  the start and at the end holds at every frame in between, for any curve,
  springs included.
* `order_sync`: with a curve that stays within `[0, 1]`, order and
  non-overlap are kept too.
* `finish_rejects_stale`: a completion from a replaced track cannot end the
  newer track (generations).
* `pass_sync`: a pass in which every key either restarts or is at rest is in
  sync.
* `kept_track_desyncs` (the gap in the Swift before `retime`): `transition` keeps an in-flight
  track when the key's settled value did not change ("a settled no-op keeps
  the old track's phase"). That track stays on the previous pass's timeline
  while its neighbours restart on the new one, so rows that touch before and
  after the pass overlap in between. Concretely: two rows slide together, and
  mid-slide the upper one grows; 0.5 s later they overlap by 25 points.
* Two fixes. Retiming every older in-flight track whenever an animated pass
  starts one (`fixedPass`, what the Swift now does in
  `AnimationController.retime`) keeps a single timeline
  (`fixed_one_timeline`), so every pass is in sync (`fixed_pass_sync`), and
  the same scenario stays touching (`fixed_scenario_touches`). Retiming
  accepts row geometry only: the viewport offset is common mode
  (`common_mode_cancels`) and keeps its own timing, and fades keep their
  deadlines (`fixed_keeps_excluded`). Or stacking: each pass adds its own additive
  delta tracks instead of replacing, and any relation every pass keeps holds
  on screen throughout (`stacked_sync`), with no velocity reset.
* `immediate_desyncs` (the gap before `transitionNow`): an immediate change
  mid-slide landed the keys it changed and left the others sliding, 50
  points apart. `now_shifts`, `now_keeps_relations`: keeping each key's
  remaining motion on top of its new value shifts what is shown by exactly
  the settled change, so settled relations hold throughout. `now_nonneg`: a
  moved size stays at least zero.
-/

namespace UltraProofs.ListAnimation

/-- `ListTransition`. Curves are named by a number; `Curves` evaluates them. -/
structure Transition where
  duration : Rat
  curve : Nat
  factor : Rat
deriving DecidableEq

/-- `ListCurve.value(at:duration:)` for each curve, at a phase already
clamped to `[0, 1]` and a logical duration. The proofs use only that every
curve starts at 0; `UltraListTests.AnimationTests.curvesAreContinuous` pins
that for the Swift curves. -/
structure Curves where
  value : Nat → Rat → Rat → Rat
  start : ∀ c d, value c 0 d = 0

/-- Curves that stay within `[0, 1]` (no overshoot). The built-in curves do
(`curvesAreContinuous` checks they are monotone from 0 to 1); a `.bezier`
with control points outside `[0, 1]` need not. -/
def Curves.Bounded (C : Curves) : Prop := ∀ c x d, 0 ≤ C.value c x d ∧ C.value c x d ≤ 1

def clamp01 (x : Rat) : Rat := min 1 (max 0 x)

/-- `AnimationTrack`. -/
structure Track where
  generation : Nat
  src : Rat
  dst : Rat
  start : Rat
  transition : Transition
deriving DecidableEq

def Track.deadline (tr : Track) : Rat := tr.start + max 0 tr.transition.duration

/-- How far along the track is at `time`: 1 once it is immediate or past its
deadline, the curve at the clamped phase before. -/
def Track.progress (C : Curves) (tr : Track) (time : Rat) : Rat :=
  if tr.transition.duration ≤ 0 ∨ time ≥ tr.deadline then 1
  else C.value tr.transition.curve (clamp01 ((time - tr.start) / tr.transition.duration))
    (tr.transition.duration / tr.transition.factor)

/-- `AnimationTrack.value(at:)`. -/
def Track.value (C : Curves) (tr : Track) (time : Rat) : Rat :=
  tr.src + (tr.dst - tr.src) * tr.progress C time

/-- A track is in flight at `time` until its deadline. -/
def Track.inFlight (tr : Track) (time : Rat) : Prop :=
  0 < tr.transition.duration ∧ time < tr.deadline

instance (tr : Track) (time : Rat) : Decidable (tr.inFlight time) := by
  unfold Track.inFlight; infer_instance

/-- **Progress depends only on the timing.** -/
theorem progress_timing (C : Curves) {a b : Track} (hs : a.start = b.start)
    (ht : a.transition = b.transition) (time : Rat) : a.progress C time = b.progress C time := by
  unfold Track.progress Track.deadline
  rw [hs, ht]

/-- A track is the interpolation of its endpoints by its progress. -/
theorem lerp (C : Curves) (tr : Track) (time : Rat) :
    tr.value C time = (1 - tr.progress C time) * tr.src + tr.progress C time * tr.dst := by
  simp only [Track.value]; grind

theorem progress_start (C : Curves) (tr : Track) (h : 0 < tr.transition.duration) :
    tr.progress C tr.start = 0 := by
  simp only [Track.progress, Track.deadline]
  have h1 : ¬tr.transition.duration ≤ 0 := by grind
  have h2 : ¬tr.start ≥ tr.start + max 0 tr.transition.duration := by grind
  simp only [h1, h2, or_self, ite_false, clamp01]
  have : min (1 : Rat) (max 0 ((tr.start - tr.start) / tr.transition.duration)) = 0 := by
    rw [show (tr.start - tr.start) / tr.transition.duration = 0 by grind]; decide +kernel
  rw [this, C.start]

theorem value_start (C : Curves) (tr : Track) (h : 0 < tr.transition.duration) :
    tr.value C tr.start = tr.src := by
  simp only [Track.value, progress_start C tr h]; grind

theorem not_inFlight {tr : Track} {time : Rat} (h : ¬tr.inFlight time) :
    tr.transition.duration ≤ 0 ∨ time ≥ tr.deadline := by
  unfold Track.inFlight at h
  by_cases h1 : 0 < tr.transition.duration
  · right; have : ¬time < tr.deadline := fun h2 => h ⟨h1, h2⟩; grind
  · left; grind

theorem not_inFlight_later {tr : Track} {t t' : Rat} (h : ¬tr.inFlight t) (ht : t ≤ t') :
    ¬tr.inFlight t' := by
  intro f
  rcases not_inFlight h with h | h
  · have := f.1; grind
  · have := f.2; grind

theorem value_at_rest (C : Curves) (tr : Track) {time : Rat} (h : ¬tr.inFlight time) :
    tr.value C time = tr.dst := by
  simp only [Track.value, Track.progress, not_inFlight h, ite_true]; grind

/-! ## Sync -/

/-- One term of a linear relation between presented values: a coefficient, a
base (the settled value under an additive track, 0 under an absolute one)
and the track. -/
structure Term where
  coeff : Rat
  base : Rat
  track : Track

def presented (C : Curves) (time : Rat) (e : Term) : Rat := e.base + e.track.value C time

def startSum (es : List Term) : Rat := (es.map fun e => e.coeff * (e.base + e.track.src)).sum
def endSum (es : List Term) : Rat := (es.map fun e => e.coeff * (e.base + e.track.dst)).sum
def nowSum (C : Curves) (time : Rat) (es : List Term) : Rat :=
  (es.map fun e => e.coeff * presented C time e).sum

theorem nowSum_lerp (C : Curves) (time p : Rat) :
    ∀ (es : List Term), (∀ e ∈ es, e.track.progress C time = p) →
      nowSum C time es = (1 - p) * startSum es + p * endSum es
  | [], _ => by simp only [nowSum, startSum, endSum, List.map_nil, List.sum_nil]; grind
  | e :: es, h => by
    have ih := nowSum_lerp C time p es (fun e he => h e (List.mem_cons_of_mem _ he))
    simp only [nowSum, startSum, endSum, List.map_cons, List.sum_cons] at ih ⊢
    rw [ih]
    have he := h e (List.mem_cons_self ..)
    simp only [presented, Track.value, he]
    grind

/-- Tracks that share a timing. -/
def OneTiming (es : List Term) (s : Rat) (τ : Transition) : Prop :=
  ∀ e ∈ es, e.track.start = s ∧ e.track.transition = τ

/-- **Tracks with one timing are one interpolation.** Each presented value is
`(1 - p) * start + p * end` with the same `p` at every time. -/
theorem lerp_sync (C : Curves) {es : List Term} {s : Rat} {τ : Transition} (h : OneTiming es s τ)
    (time : Rat) : ∃ p, ∀ e ∈ es,
      presented C time e = (1 - p) * (e.base + e.track.src) + p * (e.base + e.track.dst) := by
  refine ⟨(⟨0, 0, 0, s, τ⟩ : Track).progress C time, fun e he => ?_⟩
  rw [presented, lerp, progress_timing C (b := ⟨0, 0, 0, s, τ⟩) (h e he).1 (h e he).2 time]
  grind

/-- **Linear relations survive the whole animation.** A linear relation
between presented values that holds when the tracks start and when they end
holds at every time, whatever the curve. -/
theorem affine_sync (C : Curves) {es : List Term} {s : Rat} {τ : Transition}
    (h : OneTiming es s τ) {d : Rat} (h0 : startSum es = d) (h1 : endSum es = d) (time : Rat) :
    nowSum C time es = d := by
  rw [nowSum_lerp C time ((⟨0, 0, 0, s, τ⟩ : Track).progress C time) es
    (fun e he => progress_timing C (b := ⟨0, 0, 0, s, τ⟩) (h e he).1 (h e he).2 time), h0, h1]
  grind

theorem progress_bounded (C : Curves) (hC : C.Bounded) (tr : Track) (time : Rat) :
    0 ≤ tr.progress C time ∧ tr.progress C time ≤ 1 := by
  simp only [Track.progress]
  split
  · exact ⟨by decide, by decide⟩
  · exact hC _ _ _

/-- **Inequalities survive too, when the curve does not overshoot**: an
order or a non-overlap that holds at the start and at the end holds
throughout. -/
theorem order_sync (C : Curves) (hC : C.Bounded) {es : List Term} {s : Rat} {τ : Transition}
    (h : OneTiming es s τ) {d : Rat} (h0 : startSum es ≤ d) (h1 : endSum es ≤ d) (time : Rat) :
    nowSum C time es ≤ d := by
  have hp := progress_bounded C hC (⟨0, 0, 0, s, τ⟩ : Track) time
  rw [nowSum_lerp C time _ es
    (fun e he => progress_timing C (b := ⟨0, 0, 0, s, τ⟩) (h e he).1 (h e he).2 time)]
  generalize (⟨0, 0, 0, s, τ⟩ : Track).progress C time = p at hp
  have a : (1 - p) * startSum es ≤ (1 - p) * d := Rat.mul_le_mul_of_nonneg_left h0 (by grind)
  have b : p * endSum es ≤ p * d := Rat.mul_le_mul_of_nonneg_left h1 hp.1
  grind

/-- Two rows that touch (the upper row's bottom on the lower row's top): the
upper row's additive `positionY` over settled `ya`, its `height` track, and
the lower row's `positionY` over settled `yb`. -/
def touching (ya yb : Rat) (ay ah by_ : Track) : List Term :=
  [⟨1, ya, ay⟩, ⟨1, 0, ah⟩, ⟨-1, yb, by_⟩]

/-- **Touching rows keep touching** through a pass that animates them on one
timing, for any curve. -/
theorem touching_sync (C : Curves) {ya yb s : Rat} {τ : Transition} {ay ah by_ : Track}
    (h : OneTiming (touching ya yb ay ah by_) s τ)
    (h0 : ya + ay.src + ah.src = yb + by_.src) (h1 : ya + ay.dst + ah.dst = yb + by_.dst)
    (time : Rat) :
    ya + ay.value C time + ah.value C time = yb + by_.value C time := by
  have := affine_sync C h (d := 0) (by simp [startSum, touching]; grind)
    (by simp [endSum, touching]; grind) time
  simp [nowSum, touching, presented] at this
  grind

/-! ## The model -/

/-- What `ListAnimationModel` knows about a key: whether its property is
additive, and its resting value (1 for opacity, 0 otherwise). -/
structure Keys (K : Type) where
  additive : K → Bool
  rest : K → Rat

def set {K α : Type} [DecidableEq K] (f : K → α) (k : K) (a : α) : K → α :=
  fun k' => if k' = k then a else f k'

/-- `ListAnimationModel`'s state. -/
structure Model (K : Type) where
  tracks : K → Option Track
  stored : K → Option Rat
  generation : Nat

variable {K : Type} [DecidableEq K]

def Model.empty : Model K := ⟨fun _ => none, fun _ => none, 0⟩

/-- `value(_:_:at:)`. -/
def Model.value (C : Curves) (Ks : Keys K) (M : Model K) (k : K) (time : Rat) : Rat :=
  match M.tracks k with
  | some tr => tr.value C time
  | none => (M.stored k).getD (Ks.rest k)

/-- `replace(_:_:from:to:at:transition:)`. -/
def Model.replace (M : Model K) (k : K) (src dst time : Rat) (τ : Transition) :
    Model K × Option Track :=
  let g := M.generation + 1
  let stored := set M.stored k (some dst)
  if τ.duration ≤ 0 then ({ tracks := set M.tracks k none, stored, generation := g }, none)
  else
    let tr : Track := ⟨g, src, dst, time, τ⟩
    ({ tracks := set M.tracks k (some tr), stored, generation := g }, some tr)

/-- `transition(_:_:old:new:resume:at:transition:)`, with the Swift's `1e-6`
as `eps`. -/
def Model.transition (C : Curves) (Ks : Keys K) (eps : Rat) (M : Model K) (k : K)
    (old new : Rat) (resume : Option Rat) (time : Rat) (τ : Transition) :
    Model K × Option Track :=
  if max (new - old) (old - new) ≤ eps then (M, M.tracks k)
  else
    let current := resume.getD (M.value C Ks k time)
    let src := if Ks.additive k then old + current - new
      else if M.stored k = none then old else current
    let dst := if Ks.additive k then 0 else new
    M.replace k src dst time τ

/-- `finish(_:generation:)`. -/
def Model.finish (M : Model K) (k : K) (g : Nat) : Model K :=
  match M.tracks k with
  | some tr => if tr.generation = g then { M with tracks := set M.tracks k none } else M
  | none => M

/-- What is on screen for a key: the settled value plus the delta for an
additive property, the value itself otherwise. -/
def Model.shown (C : Curves) (Ks : Keys K) (M : Model K) (k : K) (settled time : Rat) : Rat :=
  (if Ks.additive k then settled else 0) + M.value C Ks k time

@[simp] theorem set_same {α : Type} (f : K → α) (k : K) (a : α) : set f k a k = a := by simp [set]
@[simp] theorem set_other {α : Type} (f : K → α) {k k' : K} (a : α) (h : k' ≠ k) :
    set f k a k' = f k' := by simp [set, h]

/-- A replaced animated key starts exactly at `src`. -/
theorem replace_starts_at_from (C : Curves) (Ks : Keys K) (M : Model K) (k : K)
    (src dst time : Rat) {τ : Transition} (hτ : 0 < τ.duration) :
    (M.replace k src dst time τ).1.value C Ks k time = src := by
  have : ¬τ.duration ≤ 0 := by grind
  simp only [Model.replace, this, ite_false, Model.value, set_same]
  exact value_start C ⟨_, src, dst, time, τ⟩ hτ

/-- **Retargeting never jumps.** At the pass time, what is on screen after
`transition` is what was on screen before: exactly when the key restarts,
and within `eps` when the Swift keeps its track. `resume` must be the current
value (the presentation snapshot agreeing with the model) or absent; an
absolute key must have a stored value (rows and attachments are seeded when
they are bound). -/
theorem transition_continuous (C : Curves) (Ks : Keys K) {eps : Rat} (M : Model K) (k : K)
    (old new time : Rat) {τ : Transition} (hτ : 0 < τ.duration) (resume : Option Rat)
    (hr : resume = none ∨ resume = some (M.value C Ks k time))
    (hs : Ks.additive k = false → M.stored k ≠ none) :
    let M' := (M.transition C Ks eps k old new resume time τ).1
    max (M'.shown C Ks k new time - M.shown C Ks k old time)
      (M.shown C Ks k old time - M'.shown C Ks k new time) ≤
      (if max (new - old) (old - new) ≤ eps then (if Ks.additive k then eps else 0) else 0) := by
  intro M'
  have hcur : resume.getD (M.value C Ks k time) = M.value C Ks k time := by
    rcases hr with hr | hr <;> simp [hr]
  simp only [M', Model.transition]
  split
  · rename_i hle
    simp only [Model.shown]
    cases Ks.additive k <;> simp <;> grind
  · rename_i hgt
    simp only [hcur, Model.shown]
    rw [replace_starts_at_from C Ks M k _ _ time hτ]
    cases ha : Ks.additive k
    · have := hs ha
      simp only [this, ite_false, Bool.false_eq_true]; grind
    · simp only [ite_true]; grind

/-- Every track's generation is at most the model's counter. -/
def Model.GenInv (M : Model K) : Prop := ∀ k tr, M.tracks k = some tr → tr.generation ≤ M.generation

theorem replace_genInv (M : Model K) (h : M.GenInv) (k : K) (src dst time : Rat) (τ : Transition) :
    (M.replace k src dst time τ).1.GenInv := by
  intro k' tr hk
  unfold Model.replace at hk ⊢
  by_cases hd : τ.duration ≤ 0
  · simp only [hd, ite_true] at hk ⊢
    by_cases e : k' = k
    · subst e; simp at hk
    · rw [set_other _ _ e] at hk; have := h k' tr hk; omega
  · simp only [hd, ite_false] at hk ⊢
    by_cases e : k' = k
    · subst e; simp at hk; subst hk; simp
    · rw [set_other _ _ e] at hk; have := h k' tr hk; omega

/-- **A stale completion cannot end a newer track.** After `replace`, a
completion carrying any generation issued before it leaves the new track in
place (`AnimationController.finalize` checks the same generation). -/
theorem finish_rejects_stale (M : Model K) (k : K) (src dst time : Rat) {τ : Transition}
    (hτ : 0 < τ.duration) {g : Nat} (hg : g ≤ M.generation) :
    let M' := (M.replace k src dst time τ).1
    (M'.finish k g).tracks k = M'.tracks k := by
  have : ¬τ.duration ≤ 0 := by grind
  simp only [Model.replace, this, ite_false, Model.finish, set_same]
  have : ¬M.generation + 1 = g := by omega
  simp [this]

/-! ## A pass -/

/-- One `transition` call of a pass: the key, its old and new settled values. -/
structure Req (K : Type) where
  key : K
  old : Rat
  new : Rat

/-- The pass in the Swift: the same `time` and transition for every call,
each resuming from the current value. -/
def swiftPass (C : Curves) (Ks : Keys K) (eps time : Rat) (τ : Transition) (M : Model K) :
    List (Req K) → Model K
  | [] => M
  | r :: rs => swiftPass C Ks eps time τ
      (M.transition C Ks eps r.key r.old r.new none time τ).1 rs

/-- A key is at rest at `time` when it has no track in flight. -/
def Model.AtRest (M : Model K) (k : K) (time : Rat) : Prop :=
  ∀ tr, M.tracks k = some tr → ¬tr.inFlight time

/-- **A pass is in sync when every key in it restarts or is at rest**: each
key then either has a track with the pass's timing or shows a constant.
(`kept_track_desyncs` shows the Swift does not guarantee this.) -/
theorem pass_sync (C : Curves) (Ks : Keys K) (eps time : Rat) (τ : Transition) (M : Model K)
    (k : K) (old new : Rat)
    (hrest : max (new - old) (old - new) ≤ eps → M.AtRest k time) :
    let M' := (M.transition C Ks eps k old new none time τ).1
    (∃ tr, M'.tracks k = some tr ∧ tr.start = time ∧ tr.transition = τ) ∨
      (∀ t, time ≤ t → M'.value C Ks k t = M'.value C Ks k time) := by
  intro M'
  simp only [M', Model.transition]
  split
  · rename_i hle
    right; intro t ht
    simp only [Model.value]
    cases e : M.tracks k with
    | none => rfl
    | some tr =>
      have r1 := hrest hle tr e
      simp only [value_at_rest C tr r1, value_at_rest C tr (not_inFlight_later r1 ht)]
  · simp only [Model.replace]
    split
    · right; intro t _; simp [Model.value]
    · left; exact ⟨_, set_same .., rfl, rfl⟩

/-! ## The gap: a kept track desyncs -/

/-- Three keys: the upper row's `positionY` and `height`, the lower row's
`positionY`. -/
inductive Demo
  | ay
  | ah
  | by_
deriving DecidableEq

def demoKeys : Keys Demo := ⟨fun k => k != .ah, fun _ => 0⟩

/-- A linear curve. -/
def linear : Curves := ⟨fun _ x _ => x, fun _ _ => rfl⟩

def oneSecond : Transition := ⟨1, 0, 1⟩

def eps : Rat := 1 / 1000000

/-- Pass 1 at 0 s: both rows move down by 100 (an insertion above them),
the upper row's height 100 seeded. -/
def demoPass1 : Model Demo :=
  swiftPass linear demoKeys eps 0 oneSecond
    (Model.empty.replace .ah 100 100 0 ⟨0, 0, 1⟩).1
    [⟨.ay, -100, 0⟩, ⟨.by_, 0, 100⟩]

/-- Pass 2 at 0.5 s, mid-slide: the upper row grows to 150. Its own `y`
does not change, so its slide keeps the pass-1 track; its height and the
lower row restart. -/
def demoPass2 : Model Demo :=
  swiftPass linear demoKeys eps (1 / 2) oneSecond demoPass1
    [⟨.ay, 0, 0⟩, ⟨.ah, 100, 150⟩, ⟨.by_, 100, 150⟩]

/-- The lower row's top minus the upper row's bottom at `t` (0 is touching). -/
def demoGap (M : Model Demo) (ya yb t : Rat) : Rat :=
  (yb + M.value linear demoKeys .by_ t) -
    (ya + M.value linear demoKeys .ay t + M.value linear demoKeys .ah t)

/-- **Kept tracks desync (Swift).** The rows touch before pass 2 and right
after it, and touch again once everything settles, but at 1 s the upper row
overlaps the lower one by 25 points: its slide ended on the pass-1 timeline
while its growth and the lower row's slide are halfway along pass 2's. -/
theorem kept_track_desyncs :
    demoGap demoPass1 0 100 (1 / 2) = 0 ∧
    demoGap demoPass2 0 150 (1 / 2) = 0 ∧
    demoGap demoPass2 0 150 1 = -25 ∧
    demoGap demoPass2 0 150 2 = 0 := by
  decide +kernel

/-! ## The fix: one timeline -/

/-- `ListAnimationModel.retime(since:at:transition:including:)` for one key:
restart a track the pass did not start (generation at most `since`, the
counter before the pass) that is still in flight and that `incl` accepts,
from its current value toward the same destination, on the pass's timing.
`AnimationController.retime` accepts bound row, carry and block geometry: not
the viewport offset, which moves everything in the content view alike
(`common_mode_cancels`) and must keep an input's timing (`ListPass.lockstep_iff`),
and not opacity, whose fades no geometry relation involves. -/
def Model.retime (C : Curves) (M : Model K) (incl : K → Bool) (since : Nat) (time : Rat)
    (τ : Transition) (k : K) : Option Track :=
  match M.tracks k with
  | some tr => if incl k ∧ tr.generation ≤ since ∧ tr.inFlight time then
      some { tr with src := tr.value C time, start := time, transition := τ } else some tr
  | none => none

/-- The fixed pass (`applyChanges` ending in `AnimationController.retime`):
the Swift pass, then, if it started a track and is animated, every older
in-flight track `incl` accepts retimed onto the pass's timing. Retiming keeps
each key's current value, so nothing jumps (`retime_continuous`). -/
def fixedPass (C : Curves) (Ks : Keys K) (incl : K → Bool) (eps time : Rat) (τ : Transition)
    (M : Model K) (rs : List (Req K)) : Model K :=
  let M' := swiftPass C Ks eps time τ M rs
  if M'.generation = M.generation ∨ τ.duration ≤ 0 then M'
  else { M' with tracks := M'.retime C incl M.generation time τ }

omit [DecidableEq K] in
theorem retime_continuous (C : Curves) (Ks : Keys K) (M : Model K) (incl : K → Bool) (since : Nat)
    (time : Rat) {τ : Transition} (hτ : 0 < τ.duration) (k : K) :
    ({ M with tracks := M.retime C incl since time τ } : Model K).value C Ks k time =
      M.value C Ks k time := by
  simp only [Model.value, Model.retime]
  cases M.tracks k with
  | none => rfl
  | some tr =>
    by_cases hf : incl k = true ∧ tr.generation ≤ since ∧ tr.inFlight time
    · simp only [hf, and_self, ite_true]
      exact value_start C { tr with src := tr.value C time, start := time, transition := τ } hτ
    · simp only [hf, ite_false]

/-- All tracks in flight at `time` that `incl` accepts share one timing. -/
def Model.OneTimeline (M : Model K) (incl : K → Bool) (time : Rat) : Prop :=
  ∀ k k' a b, incl k → incl k' → M.tracks k = some a → M.tracks k' = some b →
    a.inFlight time → b.inFlight time → a.start = b.start ∧ a.transition = b.transition

omit [DecidableEq K] in
theorem oneTimeline_later (M : Model K) (incl : K → Bool) {t t' : Rat} (ht : t ≤ t')
    (h : M.OneTimeline incl t) : M.OneTimeline incl t' := by
  intro k k' a b ik ik' ha hb fa fb
  exact h k k' a b ik ik' ha hb ⟨fa.1, by have := fa.2; grind⟩ ⟨fb.1, by have := fb.2; grind⟩

/-- A track the Swift pass leaves is either one it started (at `time` with
`τ`) or one it found. -/
theorem swiftPass_tracks (C : Curves) (Ks : Keys K) (eps time : Rat) (τ : Transition) :
    ∀ (M : Model K) (rs : List (Req K)) (k : K) (tr : Track),
      (swiftPass C Ks eps time τ M rs).tracks k = some tr →
      (tr.start = time ∧ tr.transition = τ) ∨ M.tracks k = some tr
  | M, [], k, tr, h => Or.inr h
  | M, r :: rs, k, tr, h => by
    rcases swiftPass_tracks C Ks eps time τ _ rs k tr h with h | h
    · exact Or.inl h
    · simp only [Model.transition] at h
      split at h
      · exact Or.inr h
      · simp only [Model.replace] at h
        split at h
        · by_cases e : k = r.key
          · subst e; simp at h
          · simp [set_other _ _ e] at h; exact Or.inr h
        · by_cases e : k = r.key
          · subst e; simp at h; subst h; exact Or.inl ⟨rfl, rfl⟩
          · simp [set_other _ _ e] at h; exact Or.inr h

theorem swiftPass_generation (C : Curves) (Ks : Keys K) (eps time : Rat) (τ : Transition) :
    ∀ (M : Model K) (rs : List (Req K)), M.generation ≤ (swiftPass C Ks eps time τ M rs).generation
  | M, [] => Nat.le_refl _
  | M, r :: rs => by
    have := swiftPass_generation C Ks eps time τ
      (M.transition C Ks eps r.key r.old r.new none time τ).1 rs
    simp only [swiftPass]
    refine Nat.le_trans ?_ this
    simp only [Model.transition]
    split
    · exact Nat.le_refl _
    · simp only [Model.replace]; split <;> simp

/-- A Swift pass that restarts nothing leaves the tracks alone. -/
theorem swiftPass_unchanged (C : Curves) (Ks : Keys K) (eps time : Rat) (τ : Transition) :
    ∀ (M : Model K) (rs : List (Req K)),
      (swiftPass C Ks eps time τ M rs).generation = M.generation →
      (swiftPass C Ks eps time τ M rs).tracks = M.tracks
  | M, [], _ => rfl
  | M, r :: rs, h => by
    simp only [swiftPass] at h ⊢
    generalize hR : M.transition C Ks eps r.key r.old r.new none time τ = R at h ⊢
    have hle := swiftPass_generation C Ks eps time τ R.1 rs
    unfold Model.transition at hR
    split at hR
    · subst hR; exact swiftPass_unchanged C Ks eps time τ M rs h
    · have : R.1.generation = M.generation + 1 := by
        rw [← hR]; simp only [Model.replace]; split <;> rfl
      omega

/-- With an animated transition, a pass that advanced the counter left a
track carrying the final generation. -/
theorem swiftPass_fresh (C : Curves) (Ks : Keys K) (eps time : Rat) {τ : Transition}
    (hτ : 0 < τ.duration) :
    ∀ (M : Model K) (rs : List (Req K)),
      (swiftPass C Ks eps time τ M rs).generation = M.generation ∨
      ∃ k tr, (swiftPass C Ks eps time τ M rs).tracks k = some tr ∧
        tr.generation = (swiftPass C Ks eps time τ M rs).generation
  | M, [] => Or.inl rfl
  | M, r :: rs => by
    simp only [swiftPass]
    generalize hR : M.transition C Ks eps r.key r.old r.new none time τ = R
    rcases swiftPass_fresh C Ks eps time hτ R.1 rs with hg | h
    · rw [swiftPass_unchanged C Ks eps time τ R.1 rs hg, hg]
      unfold Model.transition at hR
      split at hR
      · subst hR; exact Or.inl rfl
      · have hd : ¬τ.duration ≤ 0 := by grind
        subst hR
        simp only [Model.replace, hd, ite_false]
        exact Or.inr ⟨r.key, _, set_same .., rfl⟩
    · exact Or.inr h

/-- **`retime(since:)`'s guard is the model's.** With an animated
transition, the pass left a track newer than the counter before it exactly
when it advanced the counter. -/
theorem swiftPass_started (C : Curves) (Ks : Keys K) (eps time : Rat) {τ : Transition}
    (hτ : 0 < τ.duration) (M : Model K) (rs : List (Req K)) (hM : M.GenInv) :
    (∃ k tr, (swiftPass C Ks eps time τ M rs).tracks k = some tr ∧ M.generation < tr.generation) ↔
      (swiftPass C Ks eps time τ M rs).generation ≠ M.generation := by
  constructor
  · rintro ⟨k, tr, hk, hlt⟩ hg
    rw [swiftPass_unchanged C Ks eps time τ M rs hg] at hk
    have := hM k tr hk; omega
  · intro hg
    rcases swiftPass_fresh C Ks eps time hτ M rs with h | ⟨k, tr, hk, he⟩
    · exact absurd h hg
    · have := swiftPass_generation C Ks eps time τ M rs
      exact ⟨k, tr, hk, by omega⟩

/-- What the fixed pass's retiming leaves in flight for an accepted key is on
the pass's timing: retimed, or started by the pass (newer than `M`'s counter). -/
theorem fixed_retimed (C : Curves) (Ks : Keys K) (incl : K → Bool) (eps time : Rat)
    (τ : Transition) (M : Model K) (rs : List (Req K)) (hM : M.GenInv) {k : K} {c : Track}
    (ik : incl k) (hc : (swiftPass C Ks eps time τ M rs).retime C incl M.generation time τ k = some c)
    (fc : c.inFlight time) : c.start = time ∧ c.transition = τ := by
  simp only [Model.retime] at hc
  split at hc
  · rename_i tr e
    split at hc
    · cases hc; exact ⟨rfl, rfl⟩
    · rename_i nr
      cases hc
      rcases swiftPass_tracks C Ks eps time τ M rs k c e with h | h
      · exact h
      · exact absurd ⟨ik, hM k c h, fc⟩ nr
  · cases hc

/-- **The fixed pass keeps one timeline** over the keys it accepts. If every
accepted track in flight shared one timing before the pass, they all do after
it, so the invariant holds over any sequence of passes. -/
theorem fixed_one_timeline (C : Curves) (Ks : Keys K) (incl : K → Bool) (eps time : Rat)
    (τ : Transition) (M : Model K) (rs : List (Req K)) (hM : M.GenInv)
    (h : M.OneTimeline incl time) :
    (fixedPass C Ks incl eps time τ M rs).OneTimeline incl time := by
  simp only [fixedPass]
  split
  · rename_i hc
    intro k k' a b ik ik' ha hb fa fb
    have old : ∀ {k c}, (swiftPass C Ks eps time τ M rs).tracks k = some c → c.inFlight time →
        M.tracks k = some c := by
      intro k c hk fc
      rcases hc with hg | hd
      · rwa [swiftPass_unchanged C Ks eps time τ M rs hg] at hk
      · rcases swiftPass_tracks C Ks eps time τ M rs k c hk with ⟨_, ht⟩ | hk
        · have := fc.1; rw [ht] at this; grind
        · exact hk
    exact h k k' a b ik ik' (old ha fa) (old hb fb) fa fb
  · intro k k' a b ik ik' ha hb fa fb
    have := fixed_retimed C Ks incl eps time τ M rs hM ik ha fa
    have := fixed_retimed C Ks incl eps time τ M rs hM ik' hb fb
    grind

/-- **The fixed pass is in sync** over the keys it accepts. Every accepted key
either shows a constant from the pass time on, or has a track on the pass's
timing. -/
theorem fixed_pass_sync (C : Curves) (Ks : Keys K) (incl : K → Bool) (eps time : Rat)
    (τ : Transition) (M : Model K) (rs : List (Req K)) (k : K) (ik : incl k) (hM : M.GenInv)
    (hτ : 0 < τ.duration) (hstart : (swiftPass C Ks eps time τ M rs).generation ≠ M.generation) :
    let M' := fixedPass C Ks incl eps time τ M rs
    (∃ tr, M'.tracks k = some tr ∧ tr.start = time ∧ tr.transition = τ) ∨
      (∀ t, time ≤ t → M'.value C Ks k t = M'.value C Ks k time) := by
  intro M'
  have hc : ¬((swiftPass C Ks eps time τ M rs).generation = M.generation ∨ τ.duration ≤ 0) := by
    grind
  simp only [M', fixedPass, hc, ite_false]
  cases e : (swiftPass C Ks eps time τ M rs).retime C incl M.generation time τ k with
  | none => right; intro _ _; simp only [Model.value, e]
  | some c =>
    by_cases fc : c.inFlight time
    · left; exact ⟨c, rfl, fixed_retimed C Ks incl eps time τ M rs hM ik e fc⟩
    · right; intro t ht
      simp only [Model.value, e, value_at_rest C c fc, value_at_rest C c (not_inFlight_later fc ht)]

/-- **Retiming leaves the keys it does not accept alone**: a running viewport
spring keeps its curve, duration and start, and a fade keeps its deadline. -/
theorem fixed_keeps_excluded (C : Curves) (Ks : Keys K) (incl : K → Bool) (eps time : Rat)
    (τ : Transition) (M : Model K) (rs : List (Req K)) (k : K) (ik : incl k = false) :
    (fixedPass C Ks incl eps time τ M rs).tracks k = (swiftPass C Ks eps time τ M rs).tracks k := by
  simp only [fixedPass]
  split
  · rfl
  · simp only [Model.retime]
    split <;> simp_all

/-- **The viewport is common mode.** Everything in the content view is drawn
at its own position minus the viewport offset, so a relation between content
positions with coefficients summing to zero (a row touching the next, a block
welded to a row) does not depend on the viewport's delta, whatever its
timing. -/
theorem sum_mul_sub_const (v : Rat) :
    ∀ (cs ys : List Rat), cs.length = ys.length →
      (List.zipWith (fun c y => c * (y - v)) cs ys).sum =
        (List.zipWith (· * ·) cs ys).sum - v * cs.sum
  | [], _, _ => by simp; grind
  | _ :: _, [], hl => by simp at hl
  | c :: cs, y :: ys, hl => by
    have ih := sum_mul_sub_const v cs ys (by simpa using hl)
    simp only [List.zipWith_cons_cons, List.sum_cons, ih]
    grind

theorem common_mode_cancels (v : Rat) (cs ys : List Rat) (hl : cs.length = ys.length)
    (hs : cs.sum = 0) :
    (List.zipWith (fun c y => c * (y - v)) cs ys).sum = (List.zipWith (· * ·) cs ys).sum := by
  rw [sum_mul_sub_const v cs ys hl, hs]; grind

def demoFixed : Model Demo :=
  fixedPass linear demoKeys (fun _ => true) eps (1 / 2) oneSecond demoPass1
    [⟨.ay, 0, 0⟩, ⟨.ah, 100, 150⟩, ⟨.by_, 100, 150⟩]

/-- **The same scenario with the fix stays touching**, before, during and
after the animation. -/
theorem fixed_scenario_touches :
    demoGap demoFixed 0 150 (1 / 2) = 0 ∧ demoGap demoFixed 0 150 (3 / 4) = 0 ∧
    demoGap demoFixed 0 150 1 = 0 ∧ demoGap demoFixed 0 150 (5 / 4) = 0 ∧
    demoGap demoFixed 0 150 2 = 0 := by
  decide +kernel

/-! ## Immediate passes

`ListAnimationModel.transition` with an immediate transition. Before, every
key whose settled value changed lost its track and landed at once, while a
key whose settled value did not change kept its track: mid-slide, an
immediate growth snapped the row below into place while the growing row
still slid (`immediate_desyncs`). Now a key still in flight keeps what remains
of its motion on top of its new value (`now_shifts`), so every relation the
settled values keep holds on screen throughout (`now_keeps_relations`). -/

/-- `transition(...)` under an immediate transition. `fades` marks opacity,
which lands at once; an absolute track moves with its destination only if
neither end goes below zero. Otherwise it is the earlier behaviour: the key
lands at once. -/
def Model.transitionNow (C : Curves) (Ks : Keys K) (fades : K → Bool) (eps : Rat)
    (M : Model K) (k : K) (old new time : Rat) : Model K × Option Track :=
  if max (new - old) (old - new) ≤ eps then (M, M.tracks k)
  else match M.tracks k with
    | some tr =>
      if fades k = false ∧ time < tr.deadline then
        if Ks.additive k then (M, some tr)
        else if 0 ≤ min (tr.src + new - tr.dst) new then
          let moved : Track := ⟨M.generation + 1, tr.src + new - tr.dst, new, tr.start, tr.transition⟩
          ({ tracks := set M.tracks k (some moved), stored := set M.stored k (some new),
             generation := M.generation + 1 }, some moved)
        else M.transition C Ks eps k old new none time ⟨0, 0, 1⟩
      else M.transition C Ks eps k old new none time ⟨0, 0, 1⟩
    | none => M.transition C Ks eps k old new none time ⟨0, 0, 1⟩

/-- **An immediate change shifts what is shown by exactly the change**, at
every time from the pass on, for a key still in flight: an additive delta
rides on the new settled value, and a moved absolute track carries the
change at both ends. `old` is the key's settled value, which for an absolute
key is its track's destination. -/
theorem now_shifts (C : Curves) (Ks : Keys K) (fades : K → Bool) {eps : Rat} (M : Model K)
    (k : K) (old new time : Rat) (tr : Track) (htr : M.tracks k = some tr)
    (hf : fades k = false) (hd : time < tr.deadline) (hch : eps < max (new - old) (old - new))
    (habs : Ks.additive k = false → tr.dst = old ∧ 0 ≤ min (tr.src + new - tr.dst) new) (t : Rat) :
    (M.transitionNow C Ks fades eps k old new time).1.shown C Ks k new t =
      M.shown C Ks k old t + (new - old) := by
  have hle : ¬max (new - old) (old - new) ≤ eps := by grind
  simp only [Model.transitionNow, hle, ite_false, htr, hf, hd, and_self, ite_true]
  cases ha : Ks.additive k
  · obtain ⟨hdst, hmin⟩ := habs ha
    simp only [hmin, ite_true, Bool.false_eq_true, ite_false, Model.shown, ha, Model.value,
      set_same, htr]
    have hp := progress_timing C (a := ⟨M.generation + 1, tr.src + new - tr.dst, new, tr.start,
      tr.transition⟩) (b := tr) rfl rfl t
    simp only [Track.value, hp]
    rw [hdst]; grind
  · simp only [ite_true, Model.shown, ha]; grind

theorem shift_sum : ∀ (es : List (Rat × Rat × Rat)),
    (es.map fun e => e.1 * (e.2.1 + e.2.2)).sum =
      (es.map fun e => e.1 * e.2.1).sum + (es.map fun e => e.1 * e.2.2).sum
  | [] => by simp; grind
  | e :: es => by simp only [List.map_cons, List.sum_cons, shift_sum es]; grind

/-- **Relations survive an immediate pass.** Each entry is a coefficient, a
key's shown value before the pass and its settled change. If the settled
values keep a linear relation (`Σ c * old = Σ c * new`, so the changes sum to
zero), the shown values after the pass (before plus change, `now_shifts`)
satisfy whatever the shown values before it did, at every time. -/
theorem now_keeps_relations (es : List (Rat × Rat × Rat))
    (h : (es.map fun e => e.1 * e.2.2).sum = 0) :
    (es.map fun e => e.1 * (e.2.1 + e.2.2)).sum = (es.map fun e => e.1 * e.2.1).sum := by
  rw [shift_sum, h]; grind

/-- **A moved size never goes below zero** with a curve that does not
overshoot: both ends are at least zero. (An overshooting spring can still dip
past its destination.) -/
theorem now_nonneg (C : Curves) (hC : C.Bounded) (tr : Track) (h : 0 ≤ min tr.src tr.dst)
    (t : Rat) : 0 ≤ tr.value C t := by
  rw [lerp]
  have hp := progress_bounded C hC tr t
  have a : 0 ≤ (1 - tr.progress C t) * tr.src := Rat.mul_nonneg (by grind) (by grind)
  have b : 0 ≤ tr.progress C t * tr.dst := Rat.mul_nonneg hp.1 (by grind)
  grind

/-- The Swift's immediate pass, before and after: the same calls as
`swiftPass`, with `transition` or `transitionNow`. -/
def nowPass (C : Curves) (Ks : Keys K) (fades : K → Bool) (eps time : Rat) (M : Model K) :
    List (Req K) → Model K
  | [] => M
  | r :: rs => nowPass C Ks fades eps time (M.transitionNow C Ks fades eps r.key r.old r.new time).1 rs

/-- Pass 2 of the demo made immediate: at 0.5 s, mid-slide, the upper row
grows to 150 at once. -/
def demoImmediate : Model Demo :=
  swiftPass linear demoKeys eps (1 / 2) ⟨0, 0, 1⟩ demoPass1
    [⟨.ay, 0, 0⟩, ⟨.ah, 100, 150⟩, ⟨.by_, 100, 150⟩]

def demoNow : Model Demo :=
  nowPass linear demoKeys (fun _ => false) eps (1 / 2) demoPass1
    [⟨.ay, 0, 0⟩, ⟨.ah, 100, 150⟩, ⟨.by_, 100, 150⟩]

/-- **An immediate change mid-slide desynced (Swift before `transitionNow`).**
The lower row landed while the upper one kept sliding: they are 50 points
apart at the pass and 25 at 0.75 s, as the simulator shows. With the
remaining motion kept, they touch throughout. -/
theorem immediate_desyncs :
    demoGap demoImmediate 0 150 (1 / 2) = 50 ∧ demoGap demoImmediate 0 150 (3 / 4) = 25 ∧
    demoGap demoNow 0 150 (1 / 2) = 0 ∧ demoGap demoNow 0 150 (3 / 4) = 0 ∧
    demoGap demoNow 0 150 1 = 0 ∧ demoGap demoNow 0 150 2 = 0 := by
  decide +kernel

/-! ## The other fix: stacking additive passes

Instead of replacing a key's track, each pass could add its own additive
delta track (from `old - new` to 0) on top of the ones still running, for
sizes as well as positions. What is on screen is then the settled value plus
the sum of every pass's remaining delta. -/

theorem sum_mul_sub : ∀ (cs olds news : List Rat), cs.length = olds.length →
    cs.length = news.length →
    (List.zipWith (· * ·) cs (List.zipWith (· - ·) olds news)).sum =
      (List.zipWith (· * ·) cs olds).sum - (List.zipWith (· * ·) cs news).sum
  | [], _, _, _, _ => by simp only [List.zipWith_nil_left, List.sum_nil]; grind
  | c :: cs, o :: os, n :: ns, hl, hl' => by
    have := sum_mul_sub cs os ns (by simpa using hl) (by simpa using hl')
    simp only [List.zipWith_cons_cons, List.sum_cons]
    grind

/-- The deltas a pass adds keep a linear relation that holds before and after
it: if `Σ c * old = d` and `Σ c * new = d`, the deltas `old - new` sum to 0. -/
theorem pass_deltas (cs olds news : List Rat) (d : Rat) (hl : cs.length = olds.length)
    (hl' : cs.length = news.length)
    (h0 : (List.zipWith (· * ·) cs olds).sum = d) (h1 : (List.zipWith (· * ·) cs news).sum = d) :
    (List.zipWith (· * ·) cs (List.zipWith (· - ·) olds news)).sum = 0 := by
  rw [sum_mul_sub cs olds news hl hl', h0, h1]; grind

/-- **Stacked passes stay in sync, without retiming.** If each pass's deltas
satisfy the homogeneous relation (`pass_deltas`) and share that pass's
timing, then the sum of all remaining deltas satisfies it at every time, so
the relation between the settled values holds on screen throughout, however
the passes overlap. -/
theorem stacked_sync (C : Curves) (time : Rat) :
    ∀ (passes : List (List Term)),
      (∀ ps ∈ passes, (∃ s τ, OneTiming ps s τ) ∧ startSum ps = 0 ∧ endSum ps = 0) →
      (passes.map (nowSum C time)).sum = 0
  | [], _ => by simp
  | ps :: rest, h => by
    obtain ⟨⟨s, τ, ht⟩, h0, h1⟩ := h ps (List.mem_cons_self ..)
    have := affine_sync C ht h0 h1 time
    have ih := stacked_sync C time rest (fun q hq => h q (List.mem_cons_of_mem _ hq))
    simp only [List.map_cons, List.sum_cons, this, ih]
    grind

end UltraProofs.ListAnimation
