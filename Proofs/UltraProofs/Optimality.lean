import UltraProofs.Global

/-!
# Optimality

* Lower bounds that hold for **any** correct pipeline: it must read every
  node whose change can alter what is shown, send an entry for every view
  that changes, and draw every bitmap whose key changed (when it keeps one
  bitmap per node, as UltraView does).
* The pipeline meets them per node: entries only for views that change (or
  whose child list was reported changed), draws exactly for out-of-date
  keys, nothing for unchanged nodes.
* `Deps`: what "frame unchanged ⇒ not re-evaluated" needs, and a concrete
  case (finding 8, percentage padding) where the Swift breaks it.
-/

namespace UltraProofs.Optimality

open UltraProofs UltraProofs.Commits UltraProofs.Pass

/-! ## Lower bounds for any algorithm -/

/-- An algorithm reads only the nodes in `T`: its result depends on its
input only through the values at those nodes. -/
def ReadsOnly {I O : Type} (alg : (Node → I) → O) (T : Node → Prop) : Prop :=
  ∀ x y, (∀ n, T n → x n = y n) → alg x = alg y

/-- **Any correct algorithm reads every node that matters**: if changing node
`n` alone can change the correct result, an algorithm that is always
correct must read `n`. -/
theorem must_read {I O : Type} (alg spec : (Node → I) → O) (T : Node → Prop)
    (hr : ReadsOnly alg T) (hc : ∀ x, alg x = spec x) (x : Node → I) (n : Node) (v : I)
    (hdiff : spec (upd x n v) ≠ spec x) : T n := by
  apply Classical.byContradiction
  intro hn
  apply hdiff
  rw [← hc, ← hc]
  apply hr
  intro m hm
  have : m ≠ n := by intro e; subst e; exact hn hm
  simp [upd, this]

/-- **Any commit that brings the views up to date has an entry for every view
that changes**: applying a commit leaves a node without an entry untouched. -/
theorem must_send {F P B : Type} [Inhabited F] [Inhabited P] (c : Commit F P B)
    (v : ViewState F P B) (n : Node) (h : c.apply v n ≠ v n) : (c.entries n).isSome := by
  cases e : c.entries n with
  | none => simp [Commit.apply, e, applyOpt] at h
  | some _ => rfl

/-! ## The pipeline meets them -/

variable {F P K B : Type} [DecidableEq F] [DecidableEq P] [DecidableEq K]

set_option maxHeartbeats 0 in
/-- The pipeline draws exactly the bitmaps whose key changed: a node in the
display range with something to draw gets a drawing job iff the bitmap it
holds is for another key (or it holds none). -/
theorem draws_exact (bmp : K → B) (c : Ctx F P K) (ho : c.old.ist.Valid)
    (hn : c.new.ist.Valid) (hd : Deps c) (k : K) :
    (nodePass bmp c (Sh.ofSpec bmp c.old)).job = some k ↔
      (c.new.ist.display = true ∧ c.new.key = some k ∧
        ¬ (c.old.ist.display = true ∧ c.old.key = some k)) := by
  constructor
  · exact nodePass_draws_only_stale bmp c ho hn
  · have hq := q_false hd
    rw [nodePass_eq bmp c ho hn]
    revert hq
    obtain ⟨⟨of, ⟨op, od, ov⟩, opr, ok⟩, ⟨nf, ⟨np, nd, nv⟩, npr, nk⟩, sy, fo, ex, cc, kids, ca⟩ := c
    simp only [IState.Valid] at ho hn
    simp only [afterAssign, evaluate, childrenStep, drawStep]
    cases op <;> cases od <;> cases np <;> cases nd <;> simp at ho hn <;>
      cases cc <;> cases ca <;> cases sy <;> cases ex <;> cases fo <;>
      by_cases he : of = nf <;>
      rcases ok with _ | k₁ <;> rcases nk with _ | k₂ <;> (try by_cases hk : k₁ = k₂) <;>
      (try subst hk) <;> (try have hk' := Ne.symm hk) <;> (try by_cases hk2 : k₂ = k) <;>
      (try by_cases hk1 : k₁ = k) <;> simp_all [updateE, @eq_comm _ nf of]

set_option maxHeartbeats 0 in
/-- **Entries are minimal**: without a cancelled drawing, the pipeline sends
an entry for a node only if what it shows changes (frame, props, the key its
bitmap is drawn for, its children, or whether it has a view at all) or its
child list was reported changed. -/
theorem entry_only_if_changed [Inhabited F] [Inhabited P] (bmp : K → B) (c : Ctx F P K)
    (kidsOld : List Node) (ho : c.old.ist.Valid) (hn : c.new.ist.Valid) (hd : Deps c)
    (hkids : KidsOk c kidsOld) (hc : c.cancelled = false)
    (he : (nodePass bmp c (Sh.ofSpec bmp c.old)).entry.isSome) :
    c.old.view (fun k => k) kidsOld ≠ c.new.view (fun k => k) c.kids ∨
      c.childrenChanged = true := by
  have hq := q_false hd
  rw [nodePass_eq bmp c ho hn] at he
  revert he hq
  obtain ⟨⟨of, ⟨op, od, ov⟩, opr, ok⟩, ⟨nf, ⟨np, nd, nv⟩, npr, nk⟩, sy, fo, ex, cc, kids, ca⟩ := c
  simp only [IState.Valid, KidsOk] at ho hn hkids hc
  subst hc
  simp only [afterAssign, evaluate, childrenStep, drawStep, Spec.view]
  cases op <;> cases od <;> cases np <;> cases nd <;> simp at ho hn <;>
    cases cc <;> cases sy <;> cases ex <;> cases fo <;>
    by_cases hf : of = nf <;> by_cases hp : opr = npr <;>
    rcases ok with _ | k₁ <;> rcases nk with _ | k₂ <;> (try by_cases hk : k₁ = k₂) <;>
    (try subst hk) <;> (try have hk' := Ne.symm hk) <;>
    simp_all [updateE, @eq_comm _ nf of, @eq_comm _ npr opr]

/-! ## What "frame unchanged ⇒ not re-evaluated" needs

`collectFrames` queues a node only when its frame changed. Its props and
drawing key are computed from its snapshot, its frame, the environment and
some layout output that is not the frame (`aux`): resolved padding and
borders for text (`UltraTextNode.contentInset`), the content frame for a
scroll node. `Deps` holds as long as a change of `aux` is itself a reason to
evaluate the node. -/

/-- Props and keys as functions of the node's inputs (`makeProps`,
`drawingInput`). -/
structure Inputs (S F E A : Type) where
  snap : S
  frame : F
  env : E
  aux : A

omit [DecidableEq P] [DecidableEq K] in
theorem deps_of_inputs {S E A : Type} (props : Inputs S F E A → P) (key : Inputs S F E A → Option K)
    (c : Ctx F P K) (i₀ i₁ : Inputs S F E A)
    (hp₀ : c.old.props = props i₀) (hp₁ : c.new.props = props i₁)
    (hk₀ : c.old.key = key i₀) (hk₁ : c.new.key = key i₁)
    (hf₀ : c.old.frame = i₀.frame) (hf₁ : c.new.frame = i₁.frame)
    (hsnap : i₁.snap ≠ i₀.snap → c.synced = true)
    (henv : i₁.env ≠ i₀.env → c.forced = true)
    (haux : i₁.aux ≠ i₀.aux → c.extra = true ∨ i₁.frame ≠ i₀.frame) : Deps c := by
  intro hch
  apply Classical.byContradiction
  intro hno
  have hs : c.synced ≠ true := fun h => hno (.inl h)
  have hf : c.forced ≠ true := fun h => hno (.inr (.inl h))
  have hx : c.extra ≠ true := fun h => hno (.inr (.inr (.inl h)))
  have hfr : ¬ c.new.frame ≠ c.old.frame := fun h => hno (.inr (.inr (.inr h)))
  have e1 : i₁.snap = i₀.snap := Classical.byContradiction fun h => hs (hsnap h)
  have e2 : i₁.env = i₀.env := Classical.byContradiction fun h => hf (henv h)
  have e4 : i₁.frame = i₀.frame := by
    rw [← hf₀, ← hf₁]; exact Classical.byContradiction hfr
  have e3 : i₁.aux = i₀.aux := Classical.byContradiction fun h =>
    (haux h).elim hx (fun h' => h' e4)
  have : i₁ = i₀ := by
    cases i₀; cases i₁; simp_all
  subst this
  rcases hch with h | h
  · exact h (by rw [hp₀, hp₁])
  · exact h (by rw [hk₀, hk₁])

/-- **Finding 8, formally**: when `aux` changes but the frame doesn't, and
the node is not otherwise queued (the Swift's situation with percentage
padding on a fixed-size text node), the pass sends nothing and the main
thread keeps showing the old props, although the new spec differs. -/
theorem stale_when_aux_ignored [Inhabited F] [Inhabited P] (bmp : K → B) (c : Ctx F P K)
    (hs : c.synced = false) (hx : c.extra = false) (hf : c.forced = false)
    (hfr : c.old.frame = c.new.frame) (hi : c.old.ist = c.new.ist)
    (hcc : c.childrenChanged = false) (hpre : c.old.ist.preload = true)
    (hprops : c.old.props ≠ c.new.props) (kidsOld : List Node) (hk : c.kids = kidsOld)
    (ho : c.old.ist.Valid) :
    applyOpt (nodePass bmp c (Sh.ofSpec bmp c.old)).entry (c.old.view bmp kidsOld) ≠
      c.new.view bmp c.kids := by
  have hn : c.new.ist.Valid := hi ▸ ho
  rw [nodePass_eq bmp c ho hn]
  revert hs hx hf hfr hi hcc hpre hprops hk
  obtain ⟨⟨of, ⟨op, od, ov⟩, opr, ok⟩, ⟨nf, ⟨np, nd, nv⟩, npr, nk⟩, sy, fo, ex, cc, kids, ca⟩ := c
  intro hs hx hf hfr hi hcc hpre hprops hk
  simp only at hs hx hf hfr hi hcc hpre hprops hk
  simp only [IState.mk.injEq] at hi
  obtain ⟨rfl, rfl, rfl⟩ := hi
  subst hs hx hf hfr hcc hpre hk
  simp only [IState.Valid] at ho
  simp only [afterAssign, evaluate, childrenStep, drawStep, Spec.view]
  cases od <;> simp at ho <;> rcases ok with _ | k₁ <;> rcases nk with _ | k₂ <;>
    (try by_cases hkk : k₁ = k₂) <;> (try subst hkk) <;>
    simp_all [applyOpt]

/-! ## Yoga's pixel rounding needs only the flagged nodes (finding 5)

Yoga rounds every node of the tree after each layout
(`roundLayoutResultsToPixelGrid`). Rounding is to multiples of one pixel
(`D` sub-pixel units here) with some bias `h` (nearest, floor or ceiling).
A subtree Yoga didn't lay out again already has on-grid relative frames,
and re-rounding them at any new parent offset changes nothing, so rounding
could be done only where `collectFrames` already walks. -/

/-- Round `x` to a multiple of `D`, with bias `h`. -/
def roundGrid (D h x : Int) : Int := (x + h) / D * D

theorem roundGrid_shift {D : Int} (hD : D ≠ 0) (h a m : Int) :
    roundGrid D h (a + m * D) = roundGrid D h a + m * D := by
  unfold roundGrid
  have : a + m * D + h = (a + h) + m * D := by omega
  rw [this, Int.add_mul_ediv_right _ _ hD, Int.add_mul]

/-- A node at on-grid relative offset `m * D` from its parent keeps that
offset after rounding absolute positions, wherever the parent is. -/
theorem round_relative_stable {D : Int} (hD : D ≠ 0) (h parentAbs m : Int) :
    roundGrid D h (parentAbs + m * D) - roundGrid D h parentAbs = m * D := by
  rw [roundGrid_shift hD]; omega

/-- And its size (an on-grid width `w * D`) is unchanged too. -/
theorem round_size_stable {D : Int} (hD : D ≠ 0) (h left w : Int) :
    roundGrid D h (left + w * D) - roundGrid D h left = w * D :=
  round_relative_stable hD h left w

end UltraProofs.Optimality
