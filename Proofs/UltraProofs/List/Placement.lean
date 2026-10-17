/-!
# Placing transformed row views

Row views put their layer's anchor point at the top-left corner
(`ListRowView.init`), and an inverted list flips each row back with a
`scale(1, -1)` transform (the demo's rows do, inside a flipped content view).
A view's frame is the bounding box of its transformed bounds around the
layer's position, so with the anchor at the top a flipped row of height `h`
covers `[position - h, position]`. `ListRowView.place(in:)` puts the
position at the frame's top plus `placementOffset`, which is `h` for a
flipped row and 0 otherwise.

UIKit leaves the frame setter undefined for a view with a non-identity
transform. What it does is the hypothesis `Setter`: it places the
position at the requested top, as for an untransformed view with that
anchor point.

* `place_exact`: `place(in:)` puts the frame where it was asked.
* `translate_exact`, `retarget_exact`: moving the layer's position by `d`
  moves the frame by exactly `d`, so `position += next - frame.minY` puts it
  at `next`, flipped or not.
* `setter_drifts`, `writes_drift`: through the setter, a read-modify-write of
  the frame (`frame.origin.y += d`, or `frame.origin.y = next` after reading
  `frame.minY`) moves a flipped row by `d - h`; `n` such writes leave it
  `n * h` past where they asked. In the flipped content view of an inverted
  list that is `h` down the screen per write.
* `setter_exact_iff`: the setter is right for a row exactly when it is not
  flipped or has no height.
* `stream_carry_drifts`: a 140-point carried row replanned by five stream
  passes, each writing its planned top through the setter (the passes do not
  shift detached views, `shiftDetached` skips a zero delta), ends 700 points
  from its plan.
-/

namespace UltraProofs.ListPlacement

/-- `placementOffset(size:).y` with the anchor point at the top. -/
def offsetY (flip : Bool) (h : Rat) : Rat := if flip then h else 0

/-- `frame.minY` from the layer's position: the top of the transformed
bounds. -/
def frameTop (flip : Bool) (h p : Rat) : Rat := p - offsetY flip h

/-- `place(in:)`: the position for a requested top. -/
def place (flip : Bool) (h top : Rat) : Rat := top + offsetY flip h

/-- The frame setter's position for a requested top, a UIKit hypothesis. -/
structure Setter where
  set : Bool → Rat → Rat → Rat
  anchored : ∀ flip h top, set flip h top = top

theorem place_exact (flip : Bool) (h top : Rat) : frameTop flip h (place flip h top) = top := by
  simp only [frameTop, place]; grind

theorem translate_exact (flip : Bool) (h p d : Rat) : frameTop flip h (p + d) = frameTop flip h p + d := by
  simp only [frameTop]; grind

/-- `layer.position.y += next - frame.minY` lands the frame on `next`. -/
theorem retarget_exact (flip : Bool) (h p next : Rat) :
    frameTop flip h (p + (next - frameTop flip h p)) = next := by
  rw [translate_exact]; grind

/-- One read-modify-write through the setter: `frame.origin.y += d`. -/
def write (U : Setter) (flip : Bool) (h d p : Rat) : Rat := U.set flip h (frameTop flip h p + d)

theorem setter_drifts (U : Setter) (h d p : Rat) :
    frameTop true h (write U true h d p) = frameTop true h p + d - h := by
  simp only [write, U.anchored, frameTop, offsetY, ite_true]

theorem setter_exact_iff (U : Setter) (flip : Bool) (h d p : Rat) :
    frameTop flip h (write U flip h d p) = frameTop flip h p + d ↔ flip = false ∨ h = 0 := by
  cases flip <;> simp only [write, U.anchored, frameTop, offsetY] <;> constructor <;> intro hx <;> simp_all <;> try grind

/-- `n` writes, each asking for a move of `d`. -/
def writes (U : Setter) (flip : Bool) (h d : Rat) : Nat → Rat → Rat
  | 0, p => p
  | n + 1, p => writes U flip h d n (write U flip h d p)

/-- **Each write through the setter loses a row height.** -/
theorem writes_drift (U : Setter) (h d : Rat) : ∀ (n : Nat) (p : Rat),
    frameTop true h (writes U true h d n p) = frameTop true h p + n * (d - h)
  | 0, p => by simp [writes, Rat.add_zero]
  | n + 1, p => by
    rw [writes, writes_drift U h d n, setter_drifts]
    push_cast; grind

/-- The same moves through the position are exact. -/
def moves (d : Rat) : Nat → Rat → Rat
  | 0, p => p
  | n + 1, p => moves d n (p + d)

theorem moves_exact (flip : Bool) (h d : Rat) : ∀ (n : Nat) (p : Rat),
    frameTop flip h (moves d n p) = frameTop flip h p + n * d
  | 0, p => by simp [moves, Rat.add_zero]
  | n + 1, p => by
    rw [moves, moves_exact flip h d n, translate_exact]
    push_cast; grind

/-- **A carried 140-point row under five stream passes** (each replans it in
place, `d = 0`) ends 700 points past its plan through the setter, and on it
when moved through its position. -/
theorem stream_carry_drifts (U : Setter) (p : Rat) :
    frameTop true 140 (writes U true 140 0 5 p) = frameTop true 140 p - 700 ∧
      frameTop true 140 (moves 0 5 p) = frameTop true 140 p := by
  rw [writes_drift, moves_exact]; constructor <;> grind

end UltraProofs.ListPlacement
