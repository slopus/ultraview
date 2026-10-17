import UltraProofs.List.Insets

/-!
# Momentum and the keyboard

Models how a gesture's release, the engine's flight and keyboard (inset)
changes interleave in the list (UltraListView.swift, ScrollEngine.swift,
ScrollCore.swift) and in the chat screen that drives the composer inset
(ListChatController.swift).

A release hands the axis the release decision's velocity (`endDrag`) and
the engine bakes a flight from it (`startMotion`). A keyboard change runs
the inset-only path (`updateViewportInsets`): it reads the flight's current
offset (`engine.sync`), works out a shift and calls `engine.shift(by:)`,
which moves the flight's `coordinateShift` and the axis, and never
`setOffset` or `halt`. The chat passes `compensatesInsetChange` as
`!isTracking && followsComposer`. It sets `followsComposer` when a drag
begins, when the keyboard grows with the finger up, on the hide button, a
text change and Send; it clears it when the keyboard guide moves during a
drag (an interactive dismissal), and a release keeps it cleared while the
guide is still away from where the drag found it. The list clears
`holdsPinnedRow` on a touch and when a drag begins; only a scroll target to
the pinned row sets it.

Events are arbitrary: the theorems hold for every order.

* `release_hands_velocity`: the flight a release starts has the release
  decision's velocity at its first instant, dismissal or not.
* `keyboard_keeps_velocity`, `run_keeps_velocity`: keyboard changes during
  a flight translate it and leave its velocity at every time unchanged;
  `rebake_continuous`: re-baking keeps the offset and the velocity at the
  splice. `edges_keep_finiteness`: an inset change never makes an edge
  finite or infinite, so it never triggers the edge-discovery rebake in
  `setEdges`.
* `grows_compensates`, `explicit_compensates`, `run_follows`: with the finger
  up and no pinned row held, a keyboard that grows compensates at any scroll
  position; after the hide button, a text change or Send every inset change
  does; and compensation stays on through any events but an interactive
  dismissal.
* `follows_moves_by_inset`: a compensated change moves the offset by exactly
  the screen move (inset plus slack change) whenever that destination lies
  within the new edges, so the content keeps its distance to the composer.
  `follows_rides_edge`: content at or past the top edge always does. With
  `ListPass.lockstep_iff` the viewport track then moves it with the composer
  at every frame when both use the keyboard's timing.
* `no_write_unless_following`, `tracking_never_writes`: a keyboard change
  writes neither the offset nor the flight unless the pinned row is held or
  the chat compensates, and while the finger is down it never does.
* `dismissal_latches`, `dismissed_never_moved`, `dismissal_then_quiet`: a
  release after an interactive dismissal keeps compensation off and the
  release's velocity, and no later keyboard shrink, rebake or landing writes
  the offset or the flight: the hide that finishes the dismissal does not
  snap the content. `untouched_drag_resumes`: a drag that leaves the
  keyboard alone turns compensation back on.
* `touch_unpins`, `run_unpinned`: after a touch, no event but a scroll
  target to the pinned row sets `holdsPinnedRow`, so the pinned-row branch
  never re-pins content the user moved.
-/

namespace UltraProofs.ListMomentum

open UltraProofs.ListInsets

/-- `ScrollFlight`: a baked trajectory (offset and velocity by elapsed time),
its begin time and its coordinate shift. -/
structure Flight where
  offsetAt : Rat → Rat
  velocityAt : Rat → Rat
  begin : Rat
  shift : Rat

def Flight.offset (f : Flight) (t : Rat) : Rat := f.offsetAt (t - f.begin) + f.shift
def Flight.velocity (f : Flight) (t : Rat) : Rat := f.velocityAt (t - f.begin)
def Flight.shiftBy (f : Flight) (d : Rat) : Flight := { f with shift := f.shift + d }

/-- `ScrollTrajectory(baking:)` with `FlightState(core:time:)`: baking an
axis at offset `o` and velocity `v` at time `t`. Its first sample is the
axis' own (a structure field, so an assumption about the physics). -/
structure Baker where
  bake : Rat → Rat → Rat → Flight
  begins : ∀ o v t, (bake o v t).begin = t ∧ (bake o v t).shift = 0
  first : ∀ o v t, (bake o v t).offsetAt 0 = o ∧ (bake o v t).velocityAt 0 = v

/-- The engine, the list's `holdsPinnedRow` and the chat's `followsComposer`. -/
structure St where
  tracking : Bool
  holds : Bool
  follows : Bool
  offset : Rat
  flight : Option Flight
  edges : Edges

/-- The offset at `t`: the flight's when one runs (`engine.sync`). -/
def St.now (s : St) (t : Rat) : Rat := match s.flight with
  | some f => f.offset t
  | none => s.offset

inductive Ev
  /-- `touchDown`: catches a flight where it is (`catchMotion`) and clears
  `holdsPinnedRow` (`didTouchDown`). -/
  | touch (t : Rat)
  /-- `willBeginDragging`: the chat records the keyboard guide and sets
  `followsComposer`. -/
  | dragBegin
  /-- A drag sample to offset `o` (or a layout while tracking), with whether
  the keyboard guide is more than a point from where the drag found it. -/
  | drag (o : Rat) (moved : Bool)
  /-- The finger lifts. `u` is the release decision's velocity, `none` when
  it does not decelerate and the offset is inside the edges; `stayed` is the
  chat's `didEndDragging` reading of the guide. -/
  | release (u : Option Rat) (t : Rat) (stayed : Bool)
  /-- A keyboard or composer inset change at `t`, with the new edges, the
  screen move (inset plus slack change), the pinned row's boundary shift and
  whether a keyboard notification grows the overlap. -/
  | keyboard (t : Rat) (e' : Edges) (mv pin : Rat) (grows : Bool)
  /-- The hide button, a text change or Send. -/
  | explicit
  /-- A tick re-bakes the flight's future from its current state. -/
  | rebake (t : Rat)
  /-- The flight ends at its settled offset `o`. -/
  | land (o : Rat)
  /-- `applyChanges(scrollTo:)` to the pinned row. -/
  | pinTarget

/-- The chat's `followsComposer` after a keyboard notification:
`if !isTracking, overlap grows { followsComposer = true }`. -/
def keyboardFollows (s : St) (grows : Bool) : Bool :=
  if !s.tracking && grows then true else s.follows

/-- `updateViewportInsets`'s shift: the pinned row's boundary when it holds
it, otherwise the compensated destination (`cheapFixed`) when the chat asks
for compensation, otherwise none. -/
def kbShift (s : St) (t : Rat) (e' : Edges) (mv pin : Rat) (grows : Bool) : Rat :=
  if s.holds then pin
  else if !s.tracking && keyboardFollows s grows then cheapFixed s.edges e' (s.now t) mv - s.now t
  else 0

def step (B : Baker) (s : St) : Ev → St
  | .touch t => { s with holds := false, offset := s.now t, flight := none }
  | .dragBegin => { s with tracking := true, holds := false, follows := true }
  | .drag o moved =>
    if s.tracking then { s with offset := o, follows := if moved then false else s.follows }
    else s
  | .release u t stayed =>
    if s.tracking then
      { s with tracking := false, follows := stayed, flight := u.map fun v => B.bake s.offset v t }
    else s
  | .keyboard t e' mv pin grows =>
    let d := kbShift s t e' mv pin grows
    { s with follows := keyboardFollows s grows, offset := s.offset + d,
             flight := s.flight.map (·.shiftBy d), edges := e' }
  | .explicit => { s with follows := true }
  | .rebake t => match s.flight with
    | some f => { s with flight := some (B.bake (f.offset t) (f.velocity t) t) }
    | none => s
  | .land o => { s with offset := o, flight := none }
  | .pinTarget => { s with holds := true }

def run (B : Baker) (s : St) (evs : List Ev) : St := evs.foldl (step B) s

/-! ## The release's velocity reaches the flight -/

/-- **A release hands the flight its velocity.** -/
theorem release_hands_velocity (B : Baker) (s : St) (ht : s.tracking = true) (u t : Rat)
    (stayed : Bool) : ∃ f, (step B s (.release (some u) t stayed)).flight = some f ∧
      f.velocity t = u ∧ f.offset t = s.offset := by
  have h0 : t - t = 0 := by grind
  refine ⟨B.bake s.offset u t, by simp [step, ht], ?_, ?_⟩
  · simp [Flight.velocity, (B.begins _ _ _).1, h0, (B.first _ _ _).2]
  · simp [Flight.offset, (B.begins _ _ _).1, (B.begins _ _ _).2, h0, (B.first _ _ _).1, Rat.add_zero]

/-- **A keyboard change keeps the flight's velocity** at every time and
translates its offsets by the shift. -/
theorem keyboard_keeps_velocity (B : Baker) (s : St) (f : Flight) (hf : s.flight = some f)
    (t : Rat) (e' : Edges) (mv pin : Rat) (grows : Bool) :
    ∃ f', (step B s (.keyboard t e' mv pin grows)).flight = some f' ∧
      (∀ τ, f'.velocity τ = f.velocity τ) ∧
      ∀ τ, f'.offset τ = f.offset τ + kbShift s t e' mv pin grows := by
  refine ⟨f.shiftBy (kbShift s t e' mv pin grows), by simp [step, hf], fun τ => rfl, fun τ => ?_⟩
  simp only [Flight.offset, Flight.shiftBy]; grind

/-- Keyboard changes only. -/
def Ev.IsKeyboard : Ev → Prop
  | .keyboard .. => True
  | _ => False

/-- **However many keyboard changes arrive during a flight, its velocity at
every time is the one it was baked with.** -/
theorem run_keeps_velocity (B : Baker) : ∀ (evs : List Ev), (∀ e ∈ evs, e.IsKeyboard) →
    ∀ (s : St) (f : Flight), s.flight = some f →
      ∃ f', (run B s evs).flight = some f' ∧ ∀ τ, f'.velocity τ = f.velocity τ
  | [], _, s, f, hf => ⟨f, hf, fun _ => rfl⟩
  | e :: evs, hk, s, f, hf => by
    have he := hk e (by simp)
    cases e with
    | keyboard t e' mv pin grows =>
      obtain ⟨f1, h1, v1, _⟩ := keyboard_keeps_velocity B s f hf t e' mv pin grows
      obtain ⟨f', h', v'⟩ := run_keeps_velocity B evs (fun e h => hk e (by simp [h])) _ f1 h1
      exact ⟨f', h', fun τ => (v' τ).trans (v1 τ)⟩
    | _ => exact he.elim

/-- **Re-baking is continuous**: the new flight starts at the old one's
offset and velocity at the splice. -/
theorem rebake_continuous (B : Baker) (s : St) (f : Flight) (hf : s.flight = some f) (t : Rat) :
    ∃ f', (step B s (.rebake t)).flight = some f' ∧ f'.offset t = f.offset t ∧ f'.velocity t = f.velocity t := by
  have h0 : t - t = 0 := by grind
  refine ⟨B.bake (f.offset t) (f.velocity t) t, by simp [step, hf], ?_, ?_⟩
  · rw [Flight.offset, (B.begins _ _ _).1, (B.begins _ _ _).2, h0, (B.first _ _ _).1]; grind
  · rw [Flight.velocity, (B.begins _ _ _).1, h0, (B.first _ _ _).2]

/-- **An inset change keeps which edges are finite**: `ListWindow.edges`
makes an edge finite when the window reaches that end, whatever the insets,
so `setEdges` after an inset-only change never discovers an edge and never
forces a rebake. -/
theorem edges_keep_finiteness (w : ListWindow.Window) (base : Rat) (count : Nat)
    (vp vp' : ListWindow.Viewport) (pinned : Option Nat) :
    (edgesAt w base count vp pinned).minimum.isSome = (edgesAt w base count vp' pinned).minimum.isSome ∧
    (edgesAt w base count vp pinned).maximum.isSome = (edgesAt w base count vp' pinned).maximum.isSome := by
  unfold edgesAt
  split
  · exact ⟨rfl, rfl⟩
  · by_cases hl : w.lower = 0 <;> by_cases hu : w.upper = count <;> simp [hl, hu]

/-! ## Programmatic changes compensate everywhere -/

/-- **A keyboard that grows compensates**, at any scroll position, with the
finger up and no pinned row held. -/
theorem grows_compensates (s : St) (ht : s.tracking = false) (hh : s.holds = false) (t : Rat)
    (e' : Edges) (mv pin : Rat) :
    kbShift s t e' mv pin true = cheapFixed s.edges e' (s.now t) mv - s.now t := by
  simp [kbShift, keyboardFollows, ht, hh]

/-- **After the hide button, a text change or Send, every inset change
compensates** while the finger is up and no pinned row is held, growing or
not. -/
theorem explicit_compensates (B : Baker) (s : St) (ht : s.tracking = false) (hh : s.holds = false)
    (t : Rat) (e' : Edges) (mv pin : Rat) (grows : Bool) :
    kbShift (step B s .explicit) t e' mv pin grows =
      cheapFixed s.edges e' (s.now t) mv - s.now t := by
  simp [kbShift, keyboardFollows, step, ht, hh, St.now]

/-- An interactive dismissal: the guide moves during a drag, or has moved
when the finger lifts. -/
def Ev.Dismisses : Ev → Prop
  | .drag _ moved => moved = true
  | .release _ _ stayed => stayed = false
  | _ => False

theorem step_follows (B : Baker) (s : St) (e : Ev) (he : ¬e.Dismisses) (hf : s.follows = true) :
    (step B s e).follows = true := by
  cases e with
  | drag o moved =>
    simp only [Ev.Dismisses] at he
    simp only [step]; split <;> simp_all
  | release u t stayed =>
    simp only [Ev.Dismisses] at he
    simp only [step]; split <;> simp_all
  | keyboard t e' mv pin grows => simp [step, keyboardFollows, hf]
  | rebake t => simp only [step]; split <;> simp_all
  | _ => simp_all [step]

/-- **Compensation stays on until an interactive dismissal**: after any run of
events without one, the chat still follows the composer. -/
theorem run_follows (B : Baker) : ∀ (evs : List Ev), (∀ e ∈ evs, ¬e.Dismisses) →
    ∀ s : St, s.follows = true → (run B s evs).follows = true
  | [], _, _, h => h
  | e :: evs, hd, s, h =>
    run_follows B evs (fun e' h' => hd e' (by simp [h'])) _ (step_follows B s e (hd e (by simp)) h)

/-- While following, with the finger up and no pinned row held, every inset
change compensates. -/
theorem follows_compensates (s : St) (ht : s.tracking = false) (hh : s.holds = false)
    (hf : s.follows = true) (t : Rat) (e' : Edges) (mv pin : Rat) (grows : Bool) :
    kbShift s t e' mv pin grows = cheapFixed s.edges e' (s.now t) mv - s.now t := by
  simp [kbShift, keyboardFollows, ht, hh, hf]

theorem now_after (B : Baker) (s : St) (t : Rat) (e' : Edges) (mv pin : Rat) (grows : Bool) :
    (step B s (.keyboard t e' mv pin grows)).now t = s.now t + kbShift s t e' mv pin grows := by
  simp only [step, St.now]
  cases s.flight <;> simp [Flight.shiftBy, Flight.offset] <;> grind

/-- **Compensated content keeps its distance to the composer**: the offset
moves by exactly the screen move whenever that destination lies within the
new edges, wherever the content is scrolled to. -/
theorem follows_moves_by_inset (B : Baker) (s : St) (ht : s.tracking = false) (hh : s.holds = false)
    (hf : s.follows = true) (t : Rat) (e' : Edges) (mv pin : Rat) (grows : Bool)
    (hin : clamp e' (clamp s.edges (s.now t) - mv) = clamp s.edges (s.now t) - mv) :
    (step B s (.keyboard t e' mv pin grows)).now t = s.now t - mv := by
  rw [now_after, follows_compensates s ht hh hf, cheapFixed, hin]; grind

/-- **Following content at or past the top edge rides it**: content at or
past the top edge `l` ends exactly as far from the new edge `l - mv` as it
was from `l`. -/
theorem follows_rides_edge (B : Baker) (s : St) (t : Rat) (e' : Edges) (mv pin : Rat)
    (grows : Bool) (l : Rat) (hl : s.edges.minimum = some l) (hl' : e'.minimum = some (l - mv))
    (hat : s.now t ≤ l) (hh : s.holds = false)
    (hc : (!s.tracking && keyboardFollows s grows) = true) :
    (step B s (.keyboard t e' mv pin grows)).now t - (l - mv) = s.now t - l := by
  have hk : kbShift s t e' mv pin grows = cheapFixed s.edges e' (s.now t) mv - s.now t := by
    simp [kbShift, hh, hc]
  have hcf : cheapFixed s.edges e' (s.now t) mv = l - mv + (s.now t - l) := by
    simp only [cheapFixed, clamp, hl, hl']
    cases h1 : s.edges.maximum <;> cases h2 : e'.maximum <;> simp only [] <;> grind
  rw [now_after, hk, hcf]; grind

/-! ## What a keyboard change writes -/

/-- **No write unless following**: without a held pinned row and without
compensation, a keyboard change leaves the offset and the flight alone. -/
theorem no_write_unless_following (B : Baker) (s : St) (t : Rat) (e' : Edges) (mv pin : Rat)
    (grows : Bool) (hh : s.holds = false)
    (hc : (!s.tracking && keyboardFollows s grows) = false) :
    (step B s (.keyboard t e' mv pin grows)).offset = s.offset ∧
      (step B s (.keyboard t e' mv pin grows)).flight = s.flight := by
  have : kbShift s t e' mv pin grows = 0 := by simp [kbShift, hh, hc]
  simp only [step, this, Rat.add_zero]
  cases s.flight <;> simp [Flight.shiftBy, Rat.add_zero]

/-- **While the finger is down a keyboard change never writes** the offset
(the chat passes `compensatesInsetChange: !isTracking && …`). -/
theorem tracking_never_writes (B : Baker) (s : St) (ht : s.tracking = true) (hh : s.holds = false)
    (t : Rat) (e' : Edges) (mv pin : Rat) (grows : Bool) :
    (step B s (.keyboard t e' mv pin grows)).offset = s.offset ∧
      (step B s (.keyboard t e' mv pin grows)).flight = s.flight :=
  no_write_unless_following B s t e' mv pin grows hh (by simp [ht])

/-! ## An interactive dismissal latches -/

/-- **A release after an interactive dismissal keeps compensation off**, lifts
the finger and, when it decelerates, hands the flight its velocity. -/
theorem dismissal_latches (B : Baker) (s : St) (ht : s.tracking = true) (u : Option Rat) (t : Rat) :
    (step B s (.release u t false)).follows = false ∧ (step B s (.release u t false)).tracking = false ∧
      (step B s (.release u t false)).flight = u.map fun v => B.bake s.offset v t := by
  simp [step, ht]

/-- **A drag that leaves the keyboard alone turns compensation back on.** -/
theorem untouched_drag_resumes (B : Baker) (s : St) (ht : s.tracking = true) (u : Option Rat) (t : Rat) :
    (step B s (.release u t true)).follows = true := by
  simp [step, ht]

/-- What may follow a dismissal without the user acting again: the keyboard
finishing its hide, flight ticks and the landing. -/
def Ev.Quiet : Ev → Prop
  | .keyboard _ _ _ _ grows => grows = false
  | .rebake _ => True
  | .land _ => True
  | _ => False

theorem step_quiet (B : Baker) (s : St) (e : Ev) (he : e.Quiet) (ht : s.tracking = false)
    (hh : s.holds = false) (hf : s.follows = false) :
    (step B s e).tracking = false ∧ (step B s e).holds = false ∧ (step B s e).follows = false := by
  cases e with
  | keyboard t e' mv pin grows =>
    simp only [Ev.Quiet] at he
    simp [step, keyboardFollows, ht, hh, hf, he]
  | rebake t => simp only [step]; split <;> simp_all
  | land o => simp_all [step]
  | _ => exact he.elim

/-- **No snap after a dismissal.** Once the finger is up after an interactive
dismissal, no keyboard change in any run of keyboard shrinks, re-bakes and
landings writes the offset or the flight. -/
theorem dismissed_never_moved (B : Baker) : ∀ (pre : List Ev) (e : Ev),
    (∀ x ∈ pre, x.Quiet) → e.Quiet → e.IsKeyboard →
    ∀ s : St, s.tracking = false → s.holds = false → s.follows = false →
      (step B (run B s pre) e).offset = (run B s pre).offset ∧
      (step B (run B s pre) e).flight = (run B s pre).flight
  | [], e, _, he, hk, s, ht, hh, hf => by
    cases e with
    | keyboard t e' mv pin grows =>
      simp only [Ev.Quiet] at he
      exact no_write_unless_following B s t e' mv pin grows hh (by simp [keyboardFollows, ht, hf, he])
    | _ => exact hk.elim
  | x :: pre, e, hp, he, hk, s, ht, hh, hf => by
    obtain ⟨ht', hh', hf'⟩ := step_quiet B s x (hp x (by simp)) ht hh hf
    exact dismissed_never_moved B pre e (fun y h => hp y (by simp [h])) he hk _ ht' hh' hf'

/-- **From the dismissal's release on**: with no pinned row held, the release
of a dismissal followed by any run of keyboard shrinks, re-bakes and
landings never has a keyboard change write the offset or the flight. -/
theorem dismissal_then_quiet (B : Baker) (s : St) (ht : s.tracking = true) (hh : s.holds = false)
    (u : Option Rat) (t : Rat) (pre : List Ev) (e : Ev) (hp : ∀ x ∈ pre, x.Quiet) (he : e.Quiet)
    (hk : e.IsKeyboard) :
    (step B (run B (step B s (.release u t false)) pre) e).offset = (run B (step B s (.release u t false)) pre).offset ∧
      (step B (run B (step B s (.release u t false)) pre) e).flight = (run B (step B s (.release u t false)) pre).flight :=
  dismissed_never_moved B pre e hp he hk _ (by simp [step, ht]) (by simp [step, ht, hh])
    (by simp [step, ht])

/-! ## No re-pinning after a touch -/

theorem touch_unpins (B : Baker) (s : St) (t : Rat) : (step B s (.touch t)).holds = false := rfl

theorem step_unpinned (B : Baker) (s : St) (e : Ev) (he : e ≠ .pinTarget) (hh : s.holds = false) :
    (step B s e).holds = false := by
  cases e <;> simp only [step] <;> (try split) <;> (try split) <;> simp_all

/-- **Unpinned until asked**: from a touch on, only a scroll target to the
pinned row sets `holdsPinnedRow`. -/
theorem run_unpinned (B : Baker) : ∀ (evs : List Ev), (∀ e ∈ evs, e ≠ .pinTarget) →
    ∀ s : St, s.holds = false → (run B s evs).holds = false
  | [], _, _, h => h
  | e :: evs, hp, s, h =>
    run_unpinned B evs (fun e' h' => hp e' (by simp [h'])) _ (step_unpinned B s e (hp e (by simp)) h)

end UltraProofs.ListMomentum
