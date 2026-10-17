import UltraProofs.List.Window
import UltraProofs.List.Animation

/-!
# A pass on screen

The screen arithmetic of `UltraListView.applyChanges` (UltraListView.swift).
Everything in the content view is drawn at its content `y`, plus its own
additive delta, minus the engine offset plus the viewport delta. A pass
moves the engine from `oldOffset` to `newOffset` (`shift` is the
difference) and, when it *displaces* the content (a scroll target, a size or
inset change, or an additional scroll distance), replaces the viewport track
with one from `oldOffset + coordinateMap + oldCorrection - newOffset` to 0,
where `coordinateMap` is how far the reference row moved in content
coordinates.

All positions here are at one progress `p` of the pass's timing; by
`ListAnimation.lerp_sync` every track the pass starts has that same `p`.

* `displaced_row_screen`, `kept_row_screen`: every loaded row goes on screen
  from exactly where it was to exactly where it settles, as
  `(1 - p) * before + p * after`, so rows move together.
* `detached_jump` (the gap in the Swift before `detachedShift`): outgoing
  carries and departure blocks were moved by `shift`, not `coordinateMap`,
  so in a displacing pass they jumped by `shift - coordinateMap` when it
  started. `scroll_carry_jumps` builds both windows with `ListWindow.build`
  for a scroll to row 3 of rows 100 points tall: row 0, leaving the window
  at the top of the screen, reappeared 300 points down. `detached_fixed`,
  `scroll_carry_fixed`: mapping them by `coordinateMap`, as
  `applyChanges` now does in a displacing pass, keeps them where they were
  and rigid with the rows.
* `inset_moves_content`, `inset_top_pinned`: an inset change (a keyboard or
  a growing input) moves the anchor by exactly the inset change plus the
  slack change, and every loaded row with it, in that same pass.
* `immediate_same_frame`: with an immediate transition the content is at
  its new place in the same pass, so in the same Core Animation transaction
  as the inset change.
* `lockstep`, `lockstep_iff`: with an animated input, the content keeps its
  distance to the input at every frame exactly when the list's progress
  equals the input's, that is, when the host passes the input's own curve
  and duration and both start in one transaction. `chat_lockstep` applies
  this to the inverted chat, whose top inset is the composer's occlusion.
* `ghost_follows_witness`: a departure block welded to a surviving row's
  edge stays on it through the pass when it starts there.
-/

namespace UltraProofs.ListPass

open UltraProofs.ListWindow UltraProofs.ListAnimation

/-- Where something in the content view is on screen. -/
def screen (contentY delta offset viewportDelta : Rat) : Rat :=
  contentY + delta - (offset + viewportDelta)

/-- `(1 - p) * a + p * b`. -/
def mix (p a b : Rat) : Rat := (1 - p) * a + p * b

/-! ## Loaded rows -/

/-- **A loaded row in a displacing pass** goes from where it was on screen
to where it settles. Its track runs from
`oldBase + old.y + coordinateMap + current - newY` (the Swift's `oldY` in
the displacing branch) and the viewport track from
`oldOffset + coordinateMap + oldCorrection - newOffset`; at progress `p`
each has `1 - p` of its delta left. -/
theorem displaced_row_screen (oldBase oldY current oldOffset oldCorrection newBase newY newOffset
    coordinateMap p : Rat) :
    let rowFrom := (oldBase + oldY + coordinateMap) + current - (newBase + newY)
    let viewFrom := oldOffset + coordinateMap + oldCorrection - newOffset
    screen (newBase + newY) ((1 - p) * rowFrom) newOffset ((1 - p) * viewFrom) =
      mix p (screen (oldBase + oldY) current oldOffset oldCorrection)
        (screen (newBase + newY) 0 newOffset 0) := by
  simp only [screen, mix]; grind

/-- **A loaded row in a pass that does not displace** compares screen
positions (`oldBase + old.y - oldOffset` against `newBase + row.y -
engine.offset`) and leaves the viewport track running, so it goes from where
it was to where it settles relative to the viewport's motion `v`. -/
theorem kept_row_screen (oldBase oldY current oldOffset newBase newY newOffset v p : Rat) :
    let rowFrom := (oldBase + oldY - oldOffset) + current - (newBase + newY - newOffset)
    screen (newBase + newY) ((1 - p) * rowFrom) newOffset v + v =
      mix p (screen (oldBase + oldY) current oldOffset 0) (screen (newBase + newY) 0 newOffset 0) := by
  simp only [screen, mix]; grind

/-! ## Detached views -/

/-- **Detached views jump in a displacing pass (Swift before
`detachedShift`).** An outgoing carry (or a departure block) placed at its
old content `y` plus `shift`, with its own track starting from where it was
placed, appears under the new viewport track `shift - coordinateMap` away
from where it was. -/
theorem detached_jump (oldContentY current oldOffset oldCorrection newOffset coordinateMap : Rat) :
    let shift := newOffset - oldOffset
    let viewFrom := oldOffset + coordinateMap + oldCorrection - newOffset
    screen (oldContentY + shift) current newOffset viewFrom -
      screen oldContentY current oldOffset oldCorrection = shift - coordinateMap := by
  simp only [screen]; grind

/-- **Mapped by `coordinateMap`, detached views stay put** when the pass
starts, and a carry planned with the reference row's displacement (zero in
the mapped coordinates) ends rigid with that row. -/
theorem detached_fixed (oldContentY current oldOffset oldCorrection newOffset coordinateMap
    p : Rat) :
    let viewFrom := oldOffset + coordinateMap + oldCorrection - newOffset
    screen (oldContentY + coordinateMap) ((1 - p) * current) newOffset ((1 - p) * viewFrom) =
      mix p (screen oldContentY current oldOffset oldCorrection)
        (screen oldContentY 0 oldOffset 0 + (coordinateMap - (newOffset - oldOffset))) := by
  simp only [screen, mix]; grind

/-- Rows 100 points tall with no reserved space. -/
def tall (_ : Nat) : Option Meas := some ⟨100, 0, 0⟩

/-- A 320 × 400 viewport without insets. -/
def phone : Viewport := ⟨320, 400, 0, 0, 0, 0⟩

/-- The loaded window at the top: rows 0 to 5 at 0, 100, …, 500. -/
def topWindow : Window := build 20 0 phone 160 none true none tall (fun _ => 0)

/-- After `scrollTo(index: 3)`: row 3 at the top of the screen, rows 1 to 8. -/
def row3Window : Window := build 20 3 phone 160 none false none tall (fun _ => 0)

/-- `ScrollCore.containerOrigin`. -/
def containerOrigin (height : Rat) (top bottom : Bool) : Rat :=
  if top then 0 else if bottom then -height else -height / 2

def rowY (w : Window) (i : Nat) : Rat := ((w.find? fun r => r.index = i).map (·.y)).getD 0

/-- **A carried row jumps on a scroll (Swift before `detachedShift`).**
Scrolling from the top to
row 3 with an animated transition: the old window starts at content 0
(`oldBase` 0, offset 0); the new one has `newBase = -200`, the engine moves to
`-200` (`shift = -200`), and the reference row 1 moved from content 100 to
`-400` (`coordinateMap = -500`). Row 0 leaves the window and is carried; it
was on screen at 0 and appears at 300, over rows 3 and 4. -/
theorem scroll_carry_jumps :
    let oldBase := containerOrigin topWindow.height true false - topWindow.minY
    let newBase := containerOrigin row3Window.height false false - row3Window.minY
    let oldOffset : Rat := 0
    let newOffset := newBase
    let coordinateMap := newBase + rowY row3Window 1 - oldBase - rowY topWindow 1
    topWindow.map (·.index) = [0, 1, 2, 3, 4, 5] ∧
    row3Window.map (·.index) = [1, 2, 3, 4, 5, 6, 7, 8] ∧
    rowY row3Window 3 = 0 ∧ newOffset - oldOffset = -200 ∧ coordinateMap = -500 ∧
    screen (oldBase + rowY topWindow 0) 0 oldOffset 0 = 0 ∧
    screen (oldBase + rowY topWindow 0 + (newOffset - oldOffset)) 0 newOffset
      (oldOffset + coordinateMap - newOffset) = 300 := by
  decide +kernel

/-- **With `detachedShift`, the carried row stays put.** The same scroll,
with row 0 placed by `coordinateMap`: it starts on screen at 0, where it
was. -/
theorem scroll_carry_fixed :
    let oldBase := containerOrigin topWindow.height true false - topWindow.minY
    let newBase := containerOrigin row3Window.height false false - row3Window.minY
    let oldOffset : Rat := 0
    let newOffset := newBase
    let coordinateMap := newBase + rowY row3Window 1 - oldBase - rowY topWindow 1
    screen (oldBase + rowY topWindow 0 + coordinateMap) 0 newOffset
      (oldOffset + coordinateMap - newOffset) = 0 := by
  decide +kernel

/-! ## Insets: a keyboard or a growing input -/

/-- `resolveY`'s anchor rule for a surviving witness with
`compensatesInsetChange`: the witness's old screen position plus the inset
change plus the change in pin slack. -/
def compensated (oldScreenY oldTop newTop oldSlack newSlack : Rat) : Rat :=
  oldScreenY + (newTop - oldTop + newSlack - oldSlack)

/-- **Linked windows move rigidly with their anchor.** If two windows with
the same measurements put a shared anchor `Δ` apart, every shared row is `Δ`
apart. -/
theorem rigid {count count' : Nat} {measure : Nat → Option Meas} {w w' : Window}
    (hw : Good count measure w) (hw' : Good count' measure w') {a a' r r' : Row}
    (ha : a ∈ w) (ha' : a' ∈ w') (hai : a.index = a'.index) (hr : r ∈ w) (hr' : r' ∈ w')
    (hri : r.index = r'.index) (Δ : Rat) (hΔ : a'.y = a.y + Δ) : r'.y = r.y + Δ := by
  by_cases hle : a.index ≤ r.index
  · rw [linked_y hw' ha' hr' (by omega), linked_y hw ha hr hle, hΔ, ← hai, ← hri]; grind
  · have e := linked_y hw hr ha (by omega)
    have e' := linked_y hw' hr' ha' (by omega)
    rw [← hai, ← hri] at e'
    grind

/-- **An inset change moves the content by exactly the inset change plus the
slack change, in the same pass.** The old window is on screen at
`oldBase + y - oldSettled`; the new one is built in screen coordinates
(`destination = newBase`, so screen `y` is the row's `y`) with the anchor at
the compensated position. Insets do not change widths, so both windows use
the same measurements. -/
theorem inset_moves_content {count : Nat} {measure : Nat → Option Meas} {w w' : Window}
    (hw : Good count measure w) (hw' : Good count measure w')
    (oldBase oldSettled oldTop newTop oldSlack newSlack : Rat) {a a' : Row} (ha : a ∈ w)
    (ha' : a' ∈ w') (hai : a.index = a'.index)
    (hanchor : a'.y = compensated (oldBase + a.y - oldSettled) oldTop newTop oldSlack newSlack)
    {r r' : Row} (hr : r ∈ w) (hr' : r' ∈ w') (hri : r.index = r'.index) :
    r'.y = (oldBase + r.y - oldSettled) + (newTop - oldTop) + (newSlack - oldSlack) := by
  have := rigid hw hw' ha ha' hai hr hr' hri (oldBase - oldSettled + (newTop - oldTop + newSlack - oldSlack))
    (by rw [hanchor, compensated]; grind)
  grind

/-- **At the loaded top the content follows the inset too.** With the top
loaded and the list at its top edge, the old content's top was on screen at
`oldTop + oldSlack`; `build` puts the new content's top at
`newTop + newSlack` (`build_top_pinned`), so it moves by the same amount. -/
theorem inset_top_pinned (count anchor : Nat) (vp : Viewport) (margin : Rat)
    (pinned : Option Nat) (slackBaseline : Option Rat) (measure : Nat → Option Meas)
    (resolveY : Rat → Rat) (hg : anchor < count ∧ 0 < vp.contentWidth ∧ 0 < vp.height)
    {m : Meas} (hm : measure anchor = some m)
    (hlow : (prependWhile measure (fun w => decide (w.minY > -margin)) count
      [mkRow anchor (resolveY m.height) m]).lower = 0) (oldTop oldSlack : Rat) :
    let newSlack := pinSlack (pinRoom count measure vp pinned
        (prependWhile measure (fun w => decide (w.minY > -margin)) count
          [mkRow anchor (resolveY m.height) m])) pinned vp
    (build count anchor vp margin pinned true slackBaseline measure resolveY).minY =
      (oldTop + oldSlack) + (vp.top - oldTop) + (newSlack - oldSlack) := by
  intro newSlack
  rw [build_top_pinned count anchor vp margin pinned slackBaseline measure resolveY hg hm hlow]
  grind

/-- **Immediate means the same frame.** An immediate `replace` removes the
track, so the key shows its new value at once: the viewport and every row
are at their new places in the pass that changed the inset, which runs
inside the host's layout pass and commits with it. -/
theorem immediate_same_frame {K : Type} [DecidableEq K] (C : Curves) (Ks : Keys K) (M : Model K)
    (k : K) (src dst time : Rat) {τ : Transition} (hτ : τ.duration ≤ 0) (t : Rat) :
    (M.replace k src dst time τ).1.value C Ks k t = dst := by
  simp [Model.replace, hτ, Model.value]

/-- The distance from the content to the input while both animate: the
content at progress `p` of its move by `Δ`, the input at progress `q` of
its own move by `Δ`. -/
def gapAt (content input Δ p q : Rat) : Rat := (content + p * Δ) - (input + q * Δ)

/-- **Lockstep.** When the list's progress equals the input's at every
frame, the content keeps its distance to the input exactly. -/
theorem lockstep (content input Δ : Rat) (p q : Rat → Rat) (h : ∀ t, p t = q t) (t : Rat) :
    gapAt content input Δ (p t) (q t) = content - input := by
  simp only [gapAt, h t]; grind

/-- **And only then.** If the input moves at all, the distance stays fixed
at every frame if and only if the two progresses agree at every frame; a
different curve opens or closes the gap by `Δ * (p - q)`. -/
theorem lockstep_iff (content input Δ : Rat) (hΔ : Δ ≠ 0) (p q : Rat → Rat) :
    (∀ t, gapAt content input Δ (p t) (q t) = content - input) ↔ ∀ t, p t = q t := by
  constructor
  · intro h t
    have := h t
    simp only [gapAt] at this
    have : (p t - q t) * Δ = 0 := by grind
    rcases Rat.mul_eq_zero.mp this with h | h
    · grind
    · exact absurd h hΔ
  · exact fun h t => lockstep content input Δ p q h t

/-- **The inverted chat.** The composer's top is at `c` on screen; the list
is flipped, so its top inset is the occlusion `H - c + gap` and a content
point at list `y` is on screen at `H - y`. The newest message's bottom
sits on the content top (`inset + slack`), so on screen it is
`c - gap - slack`: it follows the composer exactly while the slack does not
change. -/
theorem chat_lockstep (H gap slack c : Rat) :
    let inset := H - c + gap
    H - (inset + slack) = c - gap - slack := by
  simp only; grind

/-! ## Departure blocks -/

/-- **A welded block stays on its witness.** A departure block whose edge
starts on a surviving row's boundary and is welded to it
(`DepartureLedger.targets`: its target is the boundary minus the edge's
local offset) moves with the row through the pass. -/
theorem ghost_follows_witness (C : Curves) {s : Rat} {τ : Transition} (local_ root target
    oldBoundary newBoundary : Rat) (block row : Track) (hb : block.start = s ∧ block.transition = τ)
    (hr : row.start = s ∧ row.transition = τ)
    (hbs : block.src = root - target) (hbd : block.dst = 0)
    (hrs : row.src = oldBoundary - newBoundary) (hrd : row.dst = 0)
    (hstart : root + local_ = oldBoundary) (hweld : target + local_ = newBoundary) (time : Rat) :
    target + block.value C time + local_ = newBoundary + row.value C time := by
  have h := affine_sync C (es := [⟨1, target + local_, block⟩, ⟨-1, newBoundary, row⟩])
    (s := s) (τ := τ) (d := 0)
    (by intro e he; simp at he; rcases he with he | he <;> subst he <;> assumption)
    (by simp [startSum, hbs, hrs]; grind) (by simp [endSum, hbd, hrd]; grind) time
  simp [nowSum, presented] at h
  grind

end UltraProofs.ListPass
