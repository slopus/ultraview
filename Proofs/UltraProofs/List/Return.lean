/-!
# A cancelled keyboard dismissal

Models how the chat resolves an interactive keyboard dismissal
(`KeyboardInsetGesture` in the demo's chat screen). A drag snapshots the
composer inset and keyboard height it starts with. While the finger is down
the content is not compensated (`ListMomentum.tracking_never_writes`); the
gesture records the latest inset the finger tracked, and a keyboard
animation with a duration (a will-change notification or an animated guide
target) records where the keyboard is heading, the last one winning. A
tracked height that matches that target is the system animating, not the
finger, and is not recorded. Notifications never record an inset. On
release the gesture resolves with the recorded target, or the keyboard
guide's height when no notification came. A height within half a point of
the starting height is the keyboard returning open: the content moves back
by `start - latest`, the inset the finger took away, once, through the
inset-only path. A height at most half a point above the resting height
is a dismissal: nothing moves. Anything in between waits for a later
notification or layout. Once resolved, the gesture is gone, so later
notifications and layouts do nothing.

* `resolution`: for every order of tracked samples, notifications before
  the release (any number), the release, and notifications and layouts
  after it (any number, duplicated or not), the shifts are exactly
  `verdict`: one shift of `start - latest` if the first conclusive height
  (the last target before release or the guide at release, then each
  later height in order) is open, none if it is closed or none is
  conclusive.
* `open_once`, `closed_never`, `missing_recovers`: an open outcome returns
  exactly once; a closed one never shifts; with no notification and the
  keyboard mid-way at release, the first layout that sees it open returns.
* `at_most_once`: a run never shifts more often than it begins gestures
  (plus one for a gesture already running), so duplicates never return
  twice. `begin_fresh`: a new drag replaces the whole snapshot.
* `notify_keeps_latest`: notifications, layouts and the release never change
  the recorded inset, so the shift is the finger's, not the animation's.

The shift itself goes through the inset-only path with compensation, which
`ListMomentum.keyboard_keeps_velocity` and `follows_moves_by_inset` cover.
-/

namespace UltraProofs.ListReturn

/-- The gesture's snapshot: starting inset and height, the resting height,
the latest tracked inset, the recorded target height, and whether the
finger has lifted. -/
structure G where
  start : Rat
  startHeight : Rat
  resting : Rat
  latest : Rat
  pending : Option Rat
  released : Bool

/-- The chat's gesture, and the returns it has applied, oldest first. -/
structure C where
  gesture : Option G
  shifts : List Rat

/-- Within half a point. -/
def near (a b : Rat) : Bool := decide (a - b ≤ 1 / 2) && decide (b - a ≤ 1 / 2)

def G.isOpen (g : G) (h : Rat) : Bool := near h g.startHeight
def G.isClosed (g : G) (h : Rat) : Bool := decide (h ≤ g.resting + 1 / 2)

inductive Ev
  /-- A drag begins with the composer inset, keyboard height and resting
  height. -/
  | begin (start height resting : Rat)
  /-- A tracked sample: the inset and keyboard height the finger set. -/
  | track (inset height : Rat)
  /-- A keyboard animation with a duration, heading for `height`. -/
  | outcome (height : Rat)
  /-- The finger lifts; `guide` is the keyboard guide's height. -/
  | release (guide : Rat)
  /-- A layout after the release, with the guide's height. -/
  | layout (guide : Rat)

/-- Resolving at height `h`. -/
def resolve (c : C) (g : G) (h : Rat) : C :=
  if g.isOpen h then ⟨none, c.shifts ++ [g.start - g.latest]⟩
  else if g.isClosed h then ⟨none, c.shifts⟩
  else ⟨some { g with released := true }, c.shifts⟩

def matchesTarget (g : G) (h : Rat) : Bool := match g.pending with
  | some p => near h p
  | none => false

def step (c : C) : Ev → C
  | .begin s h r => ⟨some ⟨s, h, r, s, none, false⟩, c.shifts⟩
  | .track i h => match c.gesture with
    | some g => if g.released || matchesTarget g h then c else ⟨some { g with latest := i }, c.shifts⟩
    | none => c
  | .outcome h => match c.gesture with
    | some g => if g.released then resolve c g h else ⟨some { g with pending := some h }, c.shifts⟩
    | none => c
  | .release gd => match c.gesture with
    | some g => if g.released then c else resolve c g (g.pending.getD gd)
    | none => c
  | .layout gd => match c.gesture with
    | some g => if g.released then resolve c g gd else c
    | none => c

def run (c : C) (evs : List Ev) : C := evs.foldl step c

def Ev.isBegin : Ev → Bool
  | .begin .. => true
  | _ => false

def Ev.isRelease : Ev → Bool
  | .release _ => true
  | _ => false

/-- The heights a released gesture resolves with. -/
def Ev.height : Ev → Option Rat
  | .outcome h => some h
  | .layout h => some h
  | _ => none

/-- The returns a released gesture `g` makes from the heights it sees, in
order. -/
def verdict (g : G) : List Rat → List Rat
  | [] => []
  | h :: hs => if g.isOpen h then [g.start - g.latest] else if g.isClosed h then [] else verdict g hs

/-! ## No gesture, no return -/

theorem cleared_quiet : ∀ (evs : List Ev) (c : C), c.gesture = none → (∀ e ∈ evs, e.isBegin = false) →
    run c evs = c
  | [], _, _, _ => rfl
  | e :: evs, c, hg, hb => by
    have he := hb e (List.mem_cons_self ..)
    have hs : step c e = c := by
      cases e with
      | begin => simp [Ev.isBegin] at he
      | _ => simp [step, hg]
    simp only [run, List.foldl_cons] at *
    rw [hs]; exact cleared_quiet evs c hg fun x hx => hb x (List.mem_cons_of_mem _ hx)

/-! ## After the release -/

theorem resolve_released (c : C) (g : G) (h : Rat) (hr : g.released = true) :
    resolve c g h = if g.isOpen h then ⟨none, c.shifts ++ [g.start - g.latest]⟩
      else if g.isClosed h then ⟨none, c.shifts⟩ else ⟨some g, c.shifts⟩ := by
  have : { g with released := true } = g := by cases g; simp_all
  simp only [resolve, this]

/-- **A released gesture resolves on the first conclusive height.** -/
theorem awaiting : ∀ (post : List Ev) (c : C) (g : G), c.gesture = some g → g.released = true →
    (∀ e ∈ post, e.isBegin = false) → (run c post).shifts = c.shifts ++ verdict g (post.filterMap Ev.height)
  | [], c, _, _, _, _ => by simp [run, verdict]
  | e :: post, c, g, hg, hr, hb => by
    have he := hb e (List.mem_cons_self ..)
    have hb' : ∀ x ∈ post, x.isBegin = false := fun x hx => hb x (List.mem_cons_of_mem _ hx)
    -- A height `h` resolves as `verdict` does.
    have conclude : ∀ h, (run (resolve c g h) post).shifts = c.shifts ++ verdict g (h :: post.filterMap Ev.height) := by
      intro h
      rw [resolve_released c g h hr]
      simp only [verdict]
      split
      · rw [cleared_quiet post _ rfl hb']
      · split
        · rw [cleared_quiet post _ rfl hb']; simp
        · exact awaiting post _ g rfl hr hb'
    cases e with
    | begin => simp [Ev.isBegin] at he
    | track i h =>
      have : step c (.track i h) = c := by simp [step, hg, hr]
      simp only [run, List.foldl_cons, this, List.filterMap_cons, Ev.height] at *
      exact awaiting post c g hg hr hb'
    | release gd =>
      have : step c (.release gd) = c := by simp [step, hg, hr]
      simp only [run, List.foldl_cons, this, List.filterMap_cons, Ev.height] at *
      exact awaiting post c g hg hr hb'
    | outcome h =>
      have : step c (.outcome h) = resolve c g h := by simp [step, hg, hr]
      simp only [run, List.foldl_cons, this, List.filterMap_cons, Ev.height]
      exact conclude h
    | layout h =>
      have : step c (.layout h) = resolve c g h := by simp [step, hg, hr]
      simp only [run, List.foldl_cons, this, List.filterMap_cons, Ev.height]
      exact conclude h

/-! ## Before the release -/

/-- The target recorded by the last notification, if any. -/
def lastOutcome (p : Option Rat) : List Ev → Option Rat
  | [] => p
  | .outcome h :: evs => lastOutcome (some h) evs
  | _ :: evs => lastOutcome p evs

/-- **While the finger is down nothing returns**, the snapshot keeps its
start, and the recorded target is the last notification's. -/
theorem tracking : ∀ (pre : List Ev) (c : C) (g : G), c.gesture = some g → g.released = false →
    (∀ e ∈ pre, e.isBegin = false ∧ e.isRelease = false) →
    (run c pre).shifts = c.shifts ∧ ∃ g', (run c pre).gesture = some g' ∧ g'.released = false ∧
      g'.start = g.start ∧ g'.startHeight = g.startHeight ∧ g'.resting = g.resting ∧
      g'.pending = lastOutcome g.pending pre
  | [], c, g, hg, hr, _ => ⟨rfl, g, hg, hr, rfl, rfl, rfl, rfl⟩
  | e :: pre, c, g, hg, hr, hb => by
    have he := hb e (List.mem_cons_self ..)
    have hb' := fun x hx => hb x (List.mem_cons_of_mem _ hx)
    cases e with
    | begin => simp [Ev.isBegin] at he
    | release => simp [Ev.isRelease] at he
    | track i h =>
      by_cases hm : matchesTarget g h = true
      · have : step c (.track i h) = c := by simp [step, hg, hr, hm]
        simp only [run, List.foldl_cons, this, lastOutcome] at *
        exact tracking pre c g hg hr hb'
      · have : step c (.track i h) = ⟨some { g with latest := i }, c.shifts⟩ := by simp [step, hg, hr, hm]
        simp only [run, List.foldl_cons, this, lastOutcome] at *
        exact tracking pre _ { g with latest := i } rfl hr hb'
    | outcome h =>
      have : step c (.outcome h) = ⟨some { g with pending := some h }, c.shifts⟩ := by simp [step, hg, hr]
      simp only [run, List.foldl_cons, this, lastOutcome] at *
      exact tracking pre _ { g with pending := some h } rfl hr hb'
    | layout gd =>
      have : step c (.layout gd) = c := by simp [step, hg, hr]
      simp only [run, List.foldl_cons, this, lastOutcome] at *
      exact tracking pre c g hg hr hb'

/-! ## The whole gesture -/

/-- **An open outcome returns exactly once**, by the inset the finger took
away. -/
theorem open_once (g : G) (h : Rat) (hs : List Rat) (ho : g.isOpen h = true) :
    verdict g (h :: hs) = [g.start - g.latest] := by
  simp [verdict, ho]

/-- **A closed outcome never shifts.** -/
theorem closed_never (g : G) (h : Rat) (hs : List Rat) (ho : g.isOpen h = false) (hc : g.isClosed h = true) :
    verdict g (h :: hs) = [] := by
  simp [verdict, ho, hc]

theorem verdict_released (g : G) (b : Bool) : verdict { g with released := b } = verdict g := by
  funext hs; induction hs with
  | nil => rfl
  | cons h t ih => simp [verdict, G.isOpen, G.isClosed, ih]


/-- **Every order resolves the same way**: whatever the tracked samples and
notifications before the release, and the notifications and layouts after
it, the gesture returns by `verdict` on the last target before release (or
the guide at release) followed by every later height in order. -/
theorem resolution (c : C) (g : G) (hg : c.gesture = some g) (hr : g.released = false) (pre post : List Ev)
    (hpre : ∀ e ∈ pre, e.isBegin = false ∧ e.isRelease = false) (hpost : ∀ e ∈ post, e.isBegin = false)
    (gd : Rat) :
    ∃ g', (run c pre).gesture = some g' ∧ g'.start = g.start ∧ g'.startHeight = g.startHeight ∧
      g'.resting = g.resting ∧ g'.pending = lastOutcome g.pending pre ∧
      (run c (pre ++ .release gd :: post)).shifts =
        c.shifts ++ verdict g' ((g'.pending.getD gd) :: post.filterMap Ev.height) := by
  obtain ⟨hs, g', hg', hr', h1, h2, h3, h4⟩ := tracking pre c g hg hr hpre
  refine ⟨g', hg', h1, h2, h3, h4, ?_⟩
  have hrun : run c (pre ++ .release gd :: post) = run (step (run c pre) (.release gd)) post := by
    simp [run, List.foldl_append]
  rw [hrun]
  generalize hc : run c pre = c' at hs hg'
  have hrel : step c' (.release gd) = resolve c' g' (g'.pending.getD gd) := by simp [step, hg', hr']
  rw [hrel, ← hs]
  by_cases ho : g'.isOpen (g'.pending.getD gd) = true
  · have : resolve c' g' (g'.pending.getD gd) = ⟨none, c'.shifts ++ [g'.start - g'.latest]⟩ := by
      simp [resolve, ho]
    rw [this, cleared_quiet post _ rfl hpost, open_once g' _ _ ho]
  · by_cases hcl : g'.isClosed (g'.pending.getD gd) = true
    · have : resolve c' g' (g'.pending.getD gd) = ⟨none, c'.shifts⟩ := by simp [resolve, ho, hcl]
      rw [this, cleared_quiet post _ rfl hpost, closed_never g' _ _ (by simpa using ho) hcl]; simp
    · have : resolve c' g' (g'.pending.getD gd) = ⟨some { g' with released := true }, c'.shifts⟩ := by
        simp [resolve, ho, hcl]
      rw [this, awaiting post _ { g' with released := true } rfl rfl hpost, verdict_released]
      simp only [verdict, ho, hcl]; simp

/-- **A missing notification is recovered from the guide**: with no target
recorded and the keyboard mid-way at release, the first layout that sees
it open returns. -/
theorem missing_recovers (g : G) (gd h : Rat) (hs : List Rat) (hp : g.pending = none)
    (hmo : g.isOpen gd = false) (hmc : g.isClosed gd = false) (ho : g.isOpen h = true) :
    verdict g ((g.pending.getD gd) :: h :: hs) = [g.start - g.latest] := by
  simp [hp, verdict, hmo, hmc, ho]

/-! ## At most once, and fresh snapshots -/

def Q (c : C) : Nat := c.shifts.length + (if c.gesture.isSome then 1 else 0)

theorem resolve_Q (c : C) (g : G) (h : Rat) (hg : c.gesture = some g) : Q (resolve c g h) ≤ Q c := by
  unfold resolve Q; rw [hg]
  split
  · simp
  · split <;> simp

theorem step_Q (c : C) (e : Ev) : Q (step c e) ≤ Q c + (if e.isBegin then 1 else 0) := by
  cases e with
  | begin s h r => simp only [Q, step, Ev.isBegin, Option.isSome_some, ite_true]; split <;> omega
  | track i h =>
    simp only [step, Ev.isBegin, Bool.false_eq_true, ite_false, Nat.add_zero]
    cases hg : c.gesture with
    | none => exact Nat.le_refl _
    | some g =>
      simp only []
      split
      · exact Nat.le_refl _
      · simp [Q, hg]
  | outcome h =>
    simp only [step, Ev.isBegin, Bool.false_eq_true, ite_false, Nat.add_zero]
    cases hg : c.gesture with
    | none => exact Nat.le_refl _
    | some g =>
      simp only []
      split
      · exact resolve_Q c g h hg
      · simp [Q, hg]
  | release gd =>
    simp only [step, Ev.isBegin, Bool.false_eq_true, ite_false, Nat.add_zero]
    cases hg : c.gesture with
    | none => exact Nat.le_refl _
    | some g =>
      simp only []
      split
      · exact Nat.le_refl _
      · exact resolve_Q c g _ hg
  | layout gd =>
    simp only [step, Ev.isBegin, Bool.false_eq_true, ite_false, Nat.add_zero]
    cases hg : c.gesture with
    | none => exact Nat.le_refl _
    | some g =>
      simp only []
      split
      · exact resolve_Q c g gd hg
      · exact Nat.le_refl _

/-- **Never more returns than gestures**: a run adds at most one return per
gesture it begins, plus one for a gesture already running. With no new
drag, duplicated notifications and layouts return at most once. -/
theorem at_most_once : ∀ (evs : List Ev) (c : C),
    (run c evs).shifts.length ≤ Q c + (evs.filter Ev.isBegin).length
  | [], c => by simp [run, Q]
  | e :: evs, c => by
    have h1 := at_most_once evs (step c e)
    have h2 := step_Q c e
    simp only [run, List.foldl_cons, List.filter_cons] at *
    split <;> simp_all <;> omega

/-- **A new drag replaces the whole snapshot.** -/
theorem begin_fresh (c : C) (s h r : Rat) :
    (step c (.begin s h r)).gesture = some ⟨s, h, r, s, none, false⟩ ∧ (step c (.begin s h r)).shifts = c.shifts :=
  ⟨rfl, rfl⟩

/-- **Only a tracked sample records an inset**: notifications, layouts and
the release never change the recorded inset of a gesture that remains. -/
theorem notify_keeps_latest (c : C) (g g' : G) (e : Ev) (hg : c.gesture = some g)
    (he : ∀ i h, e ≠ .track i h) (hb : e.isBegin = false) (hg' : (step c e).gesture = some g') :
    g'.latest = g.latest := by
  cases e with
  | begin => simp [Ev.isBegin] at hb
  | track i h => exact absurd rfl (he i h)
  | outcome h =>
    simp only [step, hg] at hg'
    split at hg'
    · unfold resolve at hg'
      split at hg'
      · simp at hg'
      · split at hg'
        · simp at hg'
        · simp only [Option.some.injEq] at hg'; subst hg'; rfl
    · simp only [Option.some.injEq] at hg'; subst hg'; rfl
  | release gd =>
    simp only [step, hg] at hg'
    split at hg'
    · rw [hg, Option.some.injEq] at hg'; subst hg'; rfl
    · unfold resolve at hg'
      split at hg'
      · simp at hg'
      · split at hg'
        · simp at hg'
        · simp only [Option.some.injEq] at hg'; subst hg'; rfl
  | layout gd =>
    simp only [step, hg] at hg'
    split at hg'
    · unfold resolve at hg'
      split at hg'
      · simp at hg'
      · split at hg'
        · simp at hg'
        · simp only [Option.some.injEq] at hg'; subst hg'; rfl
    · rw [hg, Option.some.injEq] at hg'; subst hg'; rfl

end UltraProofs.ListReturn
