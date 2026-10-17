/-!
# Engine callbacks during a pass

Models the guard on the engine's `onFlightChanged` callback in
`UltraListView` (UltraListView.swift, `init` and `applyChanges`). A pass
(`applyChanges`, `updateViewportInsets`, `handleScroll`) sets `passing`,
replaces the items, rebuilds the window and the attachment runs, and clears
`passing`. Engine calls inside it (`halt`, `shift`, `setEdges`) can report a
flight synchronously. Attachment rendering reads the items at every index of
the window and the runs, so between the items' swap and the rebuild it reads
a half-applied list.

The state keeps the item count and the indices rendering reads. A pass is
any sequence of swaps, rebuilds and callbacks.

* `guarded_pass_renders`: with the guard (`guard !passing else
  { deferredAttachmentRender = true; return }`), whatever the callbacks'
  order, a pass renders only after it ends, on its final state, and does so
  exactly when some callback was deferred: no callback observes a
  half-applied list and none is lost.
* `guarded_consistent`: so every render reads indices inside the items when
  the pass ends with its window and runs rebuilt.
* `unguarded_reads_outside` (the crash before `0592bc8`): rendering in the
  callback, an empty-collection pass that halts the engine after swapping
  the items reads index 3 of no items.
-/

namespace UltraProofs.ListReentry

/-- The item count, the window's and runs' indices, the flags, and the
states renders have read. -/
structure L where
  items : Nat
  reads : List Nat
  passing : Bool
  deferred : Bool
  renders : List (Nat × List Nat)

/-- Rendering reads only indices inside the items. -/
def Consistent (n : Nat) (reads : List Nat) : Prop := ∀ i ∈ reads, i < n

/-- `renderAttachments()`: it reads the current state and clears the flag. -/
def render (s : L) : L := { s with renders := s.renders ++ [(s.items, s.reads)], deferred := false }

/-- A step of a pass: the items' swap, a rebuild of the window and runs, or
an engine callback. -/
inductive Micro
  | swap (n : Nat)
  | rebuild (reads : List Nat)
  | callback

def Micro.isCallback : Micro → Bool
  | .callback => true
  | _ => false

/-- `onFlightChanged` at `0592bc8`. -/
def guarded (s : L) : L := if s.passing then { s with deferred := true } else render s

/-- `onFlightChanged` before it: it renders at once. -/
def unguarded (s : L) : L := render s

def micro (cb : L → L) (s : L) : Micro → L
  | .swap n => { s with items := n }
  | .rebuild r => { s with reads := r }
  | .callback => cb s

/-- A pass: `passing = true`, its steps, `passing = false`, then the deferred
render (`applyChanges`' `defer`). -/
def pass (cb : L → L) (s : L) (ms : List Micro) : L :=
  let s1 := ms.foldl (micro cb) { s with passing := true }
  let s2 := { s1 with passing := false }
  if s2.deferred then render s2 else s2

/-- Inside a pass the guarded callback only defers: the steps leave
`renders`, the items and the reads as the swaps and rebuilds make them. -/
theorem guarded_inside : ∀ (ms : List Micro) (s : L), s.passing = true →
    (ms.foldl (micro guarded) s).renders = s.renders ∧ (ms.foldl (micro guarded) s).passing = true ∧
    ((ms.foldl (micro guarded) s).deferred = (s.deferred || ms.any Micro.isCallback))
  | [], s, h => ⟨rfl, h, by simp⟩
  | m :: ms, s, h => by
    have hm : (micro guarded s m).renders = s.renders ∧ (micro guarded s m).passing = true ∧
        (micro guarded s m).deferred = (s.deferred || m.isCallback) := by
      cases m <;> simp [micro, guarded, h, Micro.isCallback]
    obtain ⟨r, p, d⟩ := guarded_inside ms _ hm.2.1
    simp only [List.foldl_cons]
    refine ⟨r.trans hm.1, p, ?_⟩
    rw [d, hm.2.2]
    cases m <;> simp [Micro.isCallback, List.any_cons]

/-- **No callback observes a half-applied list, and none is lost.** A
guarded pass that starts with nothing deferred adds exactly one render, of
its final items and reads, when some callback ran during it, and none
otherwise. -/
theorem guarded_pass_renders (s : L) (hd : s.deferred = false) (ms : List Micro) :
    (pass guarded s ms).renders = s.renders ++
      (if ms.any Micro.isCallback then
        [((ms.foldl (micro guarded) { s with passing := true }).items,
          (ms.foldl (micro guarded) { s with passing := true }).reads)] else []) := by
  obtain ⟨r, _, d⟩ := guarded_inside ms { s with passing := true } rfl
  have d' : (ms.foldl (micro guarded) { s with passing := true }).deferred = ms.any Micro.isCallback := by
    rw [d]; simp [hd]
  simp only [pass]
  generalize ms.foldl (micro guarded) { s with passing := true } = fin at r d' ⊢
  cases hc : ms.any Micro.isCallback <;> simp only [hc] at d' <;> simp [d', render, r]

/-- **Every render of a guarded pass reads inside the items** when the pass
ends consistent (its window and runs rebuilt for its items). -/
theorem guarded_consistent (s : L) (hd : s.deferred = false) (ms : List Micro)
    (hend : Consistent (ms.foldl (micro guarded) { s with passing := true }).items
      (ms.foldl (micro guarded) { s with passing := true }).reads) :
    ∀ x ∈ (pass guarded s ms).renders, x ∈ s.renders ∨ Consistent x.1 x.2 := by
  intro x hx
  rw [guarded_pass_renders s hd ms] at hx
  rcases List.mem_append.mp hx with h | h
  · exact Or.inl h
  · right; split at h
    · simp at h; subst h; exact hend
    · simp at h

/-- **The crash before the guard.** A list of 5 items whose window reads
row 3 becomes empty; the empty-collection branch halts the engine, which
reports the end of its flight before the window and runs are cleared. The
callback renders 3 against no items. -/
theorem unguarded_reads_outside :
    let s : L := ⟨5, [3], false, false, []⟩
    (pass unguarded s [.swap 0, .callback, .rebuild []]).renders = [(0, [3])] ∧ ¬Consistent 0 [3] := by
  refine ⟨rfl, fun h => ?_⟩
  have := h 3 (by simp)
  omega

end UltraProofs.ListReentry
