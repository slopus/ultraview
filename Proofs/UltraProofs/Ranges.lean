import UltraProofs.Pass

/-!
# Scroll ranges

`RangeTuning.state` decides a scroll child's interface state from its
extent along the scroll axis and the viewport, extended by
`preloadScreens` and `displayScreens` viewport lengths. Coordinates are
integers here (points at some fixed precision).

* At the end of a pass a node holds a bitmap exactly when it is in the
  display range and has something to draw.
* Drawn before visible: a node visible at the actual scroll position is in
  the display range of the position the last applied pass used, as long as
  the two differ by at most the display margin.
* Rows laid out one after another fall into each range as one contiguous
  run, so a pass could move each range's ends instead of testing every row
  (finding 3: `Renderer.updateRanges` tests all of them).
-/

namespace UltraProofs.Ranges

open UltraProofs UltraProofs.Pass

/-- `overlaps(extendedBy:)` in `RangeTuning.state`: the extent
`[start, end]` meets the viewport `[low, high]` widened by `margin` on each
side; an empty extent counts when it lies inside. -/
def overlaps (low high margin start stop : Int) : Bool :=
  (decide (start < high + margin) && decide (stop > low - margin)) ||
    (decide (start = stop) && decide (start ≥ low - margin) && decide (start ≤ high + margin))

/-! ## Bitmaps at the end of a pass -/

/-- **A node holds a bitmap iff it is in the display range and has something
to draw**, for the shadow a pass leaves (`Pass.nodePass_sound`). -/
theorem bitmap_iff {F P K B : Type} (bmp : K → B) (x : Spec F P K) :
    (Sh.ofSpec bmp x).contents.isSome = (x.ist.display && x.key.isSome) := by
  simp only [Sh.ofSpec]
  cases x.ist.display <;> cases x.key <;> rfl

/-! ## Drawn before visible -/

/-- **A node visible at the actual offset is in the display range of the
offset the shown commit was computed for**, when the two are at most the
display margin apart (margin ≥ 0). `ScrollNodeView` reports every quarter
viewport, so this holds while the pipeline keeps up within
`displayScreens - 0.25` viewports. -/
theorem visible_implies_displayed (low high margin d start stop : Int)
    (hd : -margin ≤ d ∧ d ≤ margin) (hvis : overlaps (low + d) (high + d) 0 start stop = true) :
    overlaps low high margin start stop = true := by
  simp only [overlaps, Bool.or_eq_true, Bool.and_eq_true, decide_eq_true_eq] at hvis ⊢
  omega

/-- The display range lies inside the preload range, so a drawn node is
mounted. -/
theorem display_within_preload (low high dm pm start stop : Int) (h : dm ≤ pm)
    (hd : overlaps low high dm start stop = true) : overlaps low high pm start stop = true := by
  simp only [overlaps, Bool.or_eq_true, Bool.and_eq_true, decide_eq_true_eq] at hd ⊢
  omega

/-! ## Ranges are contiguous runs of rows -/

/-- Rows one after another along the scroll axis: `start i ≤ stop i ≤
start (i+1)` (a column or row without wrapping, reversing or absolute
positioning). -/
def Sorted (start stop : Nat → Int) : Prop :=
  ∀ i, start i ≤ stop i ∧ stop i ≤ start (i + 1)

theorem sorted_le {start stop : Nat → Int} (h : Sorted start stop) {i j : Nat} (hij : i < j) :
    stop i ≤ start j := by
  induction j with
  | zero => omega
  | succ j ih =>
    rcases Nat.lt_succ_iff_lt_or_eq.1 hij with hlt | heq
    · have := ih hlt; have := h j; omega
    · subst heq; exact (h i).2

/-- **Each range is one contiguous run**: if rows `i < k` are in a range, so
is every row between them. -/
theorem range_contiguous {start stop : Nat → Int} (hs : Sorted start stop)
    (low high margin : Int) {i j k : Nat} (hij : i < j) (hjk : j < k)
    (hi : overlaps low high margin (start i) (stop i) = true)
    (hk : overlaps low high margin (start k) (stop k) = true) :
    overlaps low high margin (start j) (stop j) = true := by
  have h1 := sorted_le hs hij
  have h2 := sorted_le hs hjk
  have h3 := (hs j).1
  have h4 := (hs i).1
  have h5 := (hs k).1
  simp only [overlaps, Bool.or_eq_true, Bool.and_eq_true, decide_eq_true_eq] at hi hk ⊢
  omega

/-- What `updateRanges` costs in the Swift: one `RangeTuning.state` per
child of the content container, on every range update. -/
def swiftRangeCost (children : List Node) : Nat := children.length

/-- Lower bound for any pipeline: it must assign a new state to every child
whose state changes. With contiguous ranges those children are the ones
between the old and new ends of each range, which is what a windowed update
touches (plus one probe per end). -/
def changedChildren (old new : Node → Bool) (children : List Node) : List Node :=
  children.filter fun c => old c != new c

theorem changed_le_swift (old new : Node → Bool) (children : List Node) :
    (changedChildren old new children).length ≤ swiftRangeCost children :=
  List.length_filter_le _ _

end UltraProofs.Ranges
