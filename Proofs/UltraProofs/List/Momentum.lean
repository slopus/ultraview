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
`!isTracking && followsComposer`, and keeps `followsComposer` from what it
sees at the start, during and at the end of a drag and when the keyboard
grows. The list clears `holdsPinnedRow` on a touch and when a drag begins;
only a scroll target to the pinned row sets it.

Events are arbitrary: the theorems hold for every order.

* `release_hands_velocity`: the flight a release starts has the release
  decision's velocity at its first instant.
* `keyboard_keeps_velocity`, `run_keeps_velocity`: keyboard changes during
  a flight translate it and leave its velocity at every time unchanged;
  `rebake_continuous`: re-baking for new edges keeps the offset and the
  velocity at the splice. `edges_keep_finiteness`: an inset change never
  makes an edge finite or infinite, so it never triggers the edge-discovery
  rebake in `setEdges`.
* `no_write_unless_following`, `tracking_never_writes`: a keyboard change
  writes neither the offset nor the flight unless the pinned row is held or
  the chat compensates, and while the finger is down it never does.
* `follows_rides_edge`: compensating content at (or past) the top edge
  stays exactly as far from the new edge as it was from the old one. With
  `ListPass.lockstep_iff` the viewport track then moves it with the
  composer at every frame when both use the keyboard's timing.
* `touch_unpins`, `run_unpinned`: after a touch, no event but a scroll
  target to the pinned row sets `holdsPinnedRow`, so the pinned-row branch
  never re-pins content the user moved.
* `dragged_off_never_moved`: content the user left off the edge, which the
  chat no longer follows, is never moved by any later keyboard change while
  it stays off the edge whenever the keyboard grows.
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

/-- The engine, the list's `holdsPinnedRow` and the chat's gesture state. -/
structure St where
  tracking : Bool
  holds : Bool
  follows : Bool
  atNewestAtStart : Bool
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
  /-- `willBeginDragging`, with the chat's `isAtNewestEdge()`. -/
  | dragBegin (atEdge : Bool)
  /-- A drag sample to offset `o`, with the chat's readings: travel within a
  point, the keyboard where it was at the start, `isAtNewestEdge()`. -/
  | drag (o : Rat) (small stayed atEdge : Bool)
  /-- The finger lifts. `u` is the release decision's velocity, `none` when
  it does not decelerate and the offset is inside the edges. -/
  | release (u : Option Rat) (t : Rat) (stayed atEdge : Bool)
  /-- A keyboard or composer inset change at `t`, with the new edges, the
  screen move (inset plus slack change), the pinned row's boundary shift,
  whether the keyboard grows and the chat's `isAtNewestEdge()`. -/
  | keyboard (t : Rat) (e' : Edges) (mv pin : Rat) (grows atEdge : Bool)
  /-- A tick re-bakes the flight's future from its current state. -/
  | rebake (t : Rat)
  /-- The flight ends at its settled offset `o`. -/
  | land (o : Rat)
  /-- `applyChanges(scrollTo:)` to the pinned row. -/
  | pinTarget

/-- The chat's `followsComposer` after a keyboard notification:
`if !isTracking, overlap grows { followsComposer = isAtNewestEdge() }`. -/
def keyboardFollows (s : St) (grows atEdge : Bool) : Bool :=
  if !s.tracking && grows then atEdge else s.follows

/-- `updateViewportInsets`'s shift: the pinned row's boundary when it holds
it, otherwise the compensated destination (`cheapFixed`) when the chat asks
for compensation, otherwise none. -/
def kbShift (s : St) (t : Rat) (e' : Edges) (mv pin : Rat) (grows atEdge : Bool) : Rat :=
  if s.holds then pin
  else if !s.tracking && keyboardFollows s grows atEdge then cheapFixed s.edges e' (s.now t) mv - s.now t
  else 0

def step (B : Baker) (s : St) : Ev → St
  | .touch t => { s with holds := false, offset := s.now t, flight := none }
  | .dragBegin a => { s with tracking := true, holds := false, atNewestAtStart := a, follows := a }
  | .drag o small stayed a =>
    if s.tracking then
      { s with offset := o, follows := s.atNewestAtStart && small || stayed && a }
    else s
  | .release u t stayed a =>
    if s.tracking then
      { s with tracking := false, follows := if stayed && a then true else s.follows,
               flight := u.map fun v => B.bake s.offset v t }
    else s
  | .keyboard t e' mv pin grows a =>
    let d := kbShift s t e' mv pin grows a
    { s with follows := keyboardFollows s grows a, offset := s.offset + d,
             flight := s.flight.map (·.shiftBy d), edges := e' }
  | .rebake t => match s.flight with
    | some f => { s with flight := some (B.bake (f.offset t) (f.velocity t) t) }
    | none => s
  | .land o => { s with offset := o, flight := none }
  | .pinTarget => { s with holds := true }

def run (B : Baker) (s : St) (evs : List Ev) : St := evs.foldl (step B) s

/-! ## The release's velocity reaches the flight -/

/-- **A release hands the flight its velocity.** -/
theorem release_hands_velocity (B : Baker) (s : St) (ht : s.tracking = true) (u t : Rat)
    (stayed a : Bool) : ∃ f, (step B s (.release (some u) t stayed a)).flight = some f ∧
      f.velocity t = u ∧ f.offset t = s.offset := by
  have h0 : t - t = 0 := by grind
  refine ⟨B.bake s.offset u t, by simp [step, ht], ?_, ?_⟩
  · simp [Flight.velocity, (B.begins _ _ _).1, h0, (B.first _ _ _).2]
  · simp [Flight.offset, (B.begins _ _ _).1, (B.begins _ _ _).2, h0, (B.first _ _ _).1, Rat.add_zero]

/-- **A keyboard change keeps the flight's velocity** at every time and
translates its offsets by the shift. -/
theorem keyboard_keeps_velocity (B : Baker) (s : St) (f : Flight) (hf : s.flight = some f)
    (t : Rat) (e' : Edges) (mv pin : Rat) (grows a : Bool) :
    ∃ f', (step B s (.keyboard t e' mv pin grows a)).flight = some f' ∧
      (∀ τ, f'.velocity τ = f.velocity τ) ∧
      ∀ τ, f'.offset τ = f.offset τ + kbShift s t e' mv pin grows a := by
  refine ⟨f.shiftBy (kbShift s t e' mv pin grows a), by simp [step, hf], fun τ => rfl, fun τ => ?_⟩
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
    | keyboard t e' mv pin grows a =>
      obtain ⟨f1, h1, v1, _⟩ := keyboard_keeps_velocity B s f hf t e' mv pin grows a
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

/-! ## What a keyboard change writes -/

/-- **No write unless following**: without a held pinned row and without
compensation, a keyboard change leaves the offset and the flight alone. -/
theorem no_write_unless_following (B : Baker) (s : St) (t : Rat) (e' : Edges) (mv pin : Rat)
    (grows a : Bool) (hh : s.holds = false)
    (hc : (!s.tracking && keyboardFollows s grows a) = false) :
    (step B s (.keyboard t e' mv pin grows a)).offset = s.offset ∧
      (step B s (.keyboard t e' mv pin grows a)).flight = s.flight := by
  have : kbShift s t e' mv pin grows a = 0 := by simp [kbShift, hh, hc]
  simp only [step, this, Rat.add_zero]
  cases s.flight <;> simp [Flight.shiftBy, Rat.add_zero]

/-- **While the finger is down a keyboard change never writes** the offset
(the chat passes `compensatesInsetChange: !isTracking && …`). -/
theorem tracking_never_writes (B : Baker) (s : St) (ht : s.tracking = true) (hh : s.holds = false)
    (t : Rat) (e' : Edges) (mv pin : Rat) (grows a : Bool) :
    (step B s (.keyboard t e' mv pin grows a)).offset = s.offset ∧
      (step B s (.keyboard t e' mv pin grows a)).flight = s.flight :=
  no_write_unless_following B s t e' mv pin grows a hh (by simp [ht])

/-- **Following content rides the edge**: content at or past the top edge
`l`, compensated by a move `mv` that moves the edge to `l - mv`, ends as far
from the new edge as it was from the old one. -/
theorem follows_rides_edge (B : Baker) (s : St) (t : Rat) (e' : Edges) (mv pin : Rat)
    (grows a : Bool) (l : Rat) (hl : s.edges.minimum = some l) (hl' : e'.minimum = some (l - mv))
    (hat : s.now t ≤ l) (hh : s.holds = false)
    (hc : (!s.tracking && keyboardFollows s grows a) = true) :
    (step B s (.keyboard t e' mv pin grows a)).now t - (l - mv) = s.now t - l := by
  have hk : kbShift s t e' mv pin grows a = cheapFixed s.edges e' (s.now t) mv - s.now t := by
    simp [kbShift, hh, hc]
  have hcf : cheapFixed s.edges e' (s.now t) mv = l - mv + (s.now t - l) := by
    simp only [cheapFixed, clamp, hl, hl']
    cases h1 : s.edges.maximum <;> cases h2 : e'.maximum <;> simp only [] <;> grind
  have hnow : (step B s (.keyboard t e' mv pin grows a)).now t =
      s.now t + kbShift s t e' mv pin grows a := by
    simp only [step, St.now]
    cases s.flight <;> simp [Flight.shiftBy, Flight.offset] <;> grind
  rw [hnow, hk, hcf]; grind

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

/-- Off the edge whenever the keyboard grows: the chat's reading. -/
def Ev.OffEdge : Ev → Prop
  | .keyboard _ _ _ _ grows a => grows = true → a = false
  | .rebake _ => True
  | .land _ => True
  | _ => False

theorem step_off (B : Baker) (s : St) (e : Ev) (he : e.OffEdge) (ht : s.tracking = false)
    (hh : s.holds = false) (hf : s.follows = false) :
    (step B s e).tracking = false ∧ (step B s e).holds = false ∧ (step B s e).follows = false := by
  cases e with
  | keyboard t e' mv pin grows a =>
    simp only [Ev.OffEdge] at he
    simp only [step, keyboardFollows, ht, hh, hf]
    cases grows <;> simp_all
  | rebake t => simp only [step]; split <;> simp_all
  | land o => simp_all [step]
  | _ => exact he.elim

/-- **Content dragged off the edge stays put.** Once the finger is up, no
pinned row is held and the chat no longer follows, no keyboard change in any
run of keyboard changes, re-bakes and landings writes the offset or the
flight, as long as the content is off the edge whenever the keyboard grows. -/
theorem dragged_off_never_moved (B : Baker) : ∀ (pre : List Ev) (e : Ev),
    (∀ x ∈ pre, x.OffEdge) → e.OffEdge → e.IsKeyboard →
    ∀ s : St, s.tracking = false → s.holds = false → s.follows = false →
      (step B (run B s pre) e).offset = (run B s pre).offset ∧
      (step B (run B s pre) e).flight = (run B s pre).flight
  | [], e, _, he, hk, s, ht, hh, hf => by
    cases e with
    | keyboard t e' mv pin grows a =>
      exact no_write_unless_following B s t e' mv pin grows a hh (by simp [keyboardFollows, ht, hf]; simp_all [Ev.OffEdge])
    | _ => exact hk.elim
  | x :: pre, e, hp, he, hk, s, ht, hh, hf => by
    obtain ⟨ht', hh', hf'⟩ := step_off B s x (hp x (by simp)) ht hh hf
    exact dragged_off_never_moved B pre e (fun y h => hp y (by simp [h])) he hk _ ht' hh' hf'

end UltraProofs.ListMomentum
