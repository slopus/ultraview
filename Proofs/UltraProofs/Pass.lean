import UltraProofs.Commit

/-!
# One node through one pass

Models what `Renderer.runPass` does to one node, in the order the Swift does
it, with the same shadow fields, the same comparisons and the same commit
operations:

1. sync: a synced node is queued for evaluation (`pass.evaluate`);
2. `collectFrames`: a changed frame (or a forced pass) updates
   `shadow.frame` and queues the node; a scroll node whose content frame
   changed is queued too;
3. interface state: `transition` when the state changes (mount, unmount,
   entering or leaving the display range);
4. `evaluate`: props and frame compared with `sentProps` / `sentFrame`, the
   drawing key compared with `drawnKey`;
5. the child list, when the children changed;
6. `draw`: a finished bitmap is applied unless it was cancelled.

What the node should show is given by a `Spec`: its frame (from the
layout), its interface state, its props and its drawing key. A node's props
and key are functions of its snapshot, frame, environment and (for scroll
and text nodes) a little layout output (`makeProps`, `drawingInput`); the
hypothesis `Deps` says that whenever they change, one of the reasons the
pipeline queues a node holds.
-/

namespace UltraProofs.Pass

open UltraProofs UltraProofs.Commits

/-- `InterfaceState`. Each state implies the ones before it. -/
structure IState where
  preload : Bool
  display : Bool
  visible : Bool
  deriving DecidableEq

def IState.Valid (s : IState) : Prop :=
  (s.display = true → s.preload = true) ∧ (s.visible = true → s.display = true)

/-- What a node should show after a pass. `key = none`: nothing to draw
(empty size, or a box that layer properties show and no content). -/
structure Spec (F P K : Type) where
  frame : F
  ist : IState
  props : P
  key : Option K

/-- The pipeline's record of a node (`Shadow`), the fields that matter here. -/
structure Sh (F P K B : Type) where
  frame : F
  ist : IState
  mounted : Bool
  sentFrame : Option F
  sentProps : Option P
  contents : Option B
  drawnKey : Option K

variable {F P K B : Type}

/-- The shadow of a node that shows `x`, drawn with `bmp`. -/
def Sh.ofSpec (bmp : K → B) (x : Spec F P K) : Sh F P K B where
  frame := x.frame
  ist := x.ist
  mounted := x.ist.preload
  sentFrame := if x.ist.preload then some x.frame else none
  sentProps := if x.ist.preload then some x.props else none
  contents := if x.ist.display then x.key.map bmp else none
  drawnKey := if x.ist.display then x.key else none

/-- The view the main thread holds for a node that shows `x`. -/
def Spec.view (bmp : K → B) (x : Spec F P K) (kids : List Node) : Option (View F P B) :=
  if x.ist.preload then
    some { frame := x.frame, props := x.props
           contents := if x.ist.display then x.key.map bmp else none, children := kids }
  else none

/-- Per-node facts of one pass. -/
structure Ctx (F P K : Type) where
  old : Spec F P K
  new : Spec F P K
  /-- The node was synced (`needsSync` observed, or attached this pass). -/
  synced : Bool
  /-- First pass, or the environment changed: every node is re-evaluated. -/
  forced : Bool
  /-- A scroll node whose content container's frame changed. -/
  extra : Bool
  /-- `pass.childrenDidChange` was called for the node. -/
  childrenChanged : Bool
  /-- The node's mounted children at the end of the pass. -/
  kids : List Node
  /-- Its bitmap was cancelled (display sentinel bumped while drawing). -/
  cancelled : Bool

/-- The node's part of the pass in progress. -/
structure W (F P K B : Type) where
  sh : Sh F P K B
  entry : Option (Entry F P B)
  queued : Bool
  job : Option K

def recordE (e : Option (Entry F P B)) (x : Entry F P B) : Option (Entry F P B) :=
  some (match e with | none => x | some y => y.merge x)

def updateE (e : Option (Entry F P B)) (f : Entry F P B → Entry F P B) : Option (Entry F P B) :=
  some (f (e.getD { kind := .update }))

section steps

variable [DecidableEq F] [DecidableEq P] [DecidableEq K]

/-- Step 3, `collectFrames`. -/
def frameStep (c : Ctx F P K) (w : W F P K B) : W F P K B :=
  if c.forced = true ∨ w.sh.frame ≠ c.new.frame then
    { w with sh := { w.sh with frame := c.new.frame }, queued := true }
  else w

/-- `Renderer.transition`. -/
def transition (new : IState) (w : W F P K B) : W F P K B :=
  let old := w.sh.ist
  let w := { w with sh := { w.sh with ist := new } }
  let w :=
    if new.preload = true ∧ w.sh.mounted = false then
      { w with sh := { w.sh with mounted := true }
               entry := recordE w.entry { kind := .mount }, queued := true }
    else if new.preload = false ∧ w.sh.mounted = true then
      { w with sh := { w.sh with mounted := false, sentProps := none, sentFrame := none }
               entry := recordE w.entry { kind := .unmount } }
    else w
  if new.display = true ∧ old.display = false then { w with queued := true }
  else if new.display = false ∧ old.display = true then
    { w with
      sh := { w.sh with contents := none, drawnKey := none }
      entry := if w.sh.contents.isSome ∧ w.sh.mounted = true
        then updateE w.entry (fun x => { x with contents := some .clear }) else w.entry }
  else w

/-- Step 4: `assignState` calls `transition` only when the state changes. -/
def assignStep (c : Ctx F P K) (w : W F P K B) : W F P K B :=
  if w.sh.ist ≠ c.new.ist then transition c.new.ist w else w

/-- Step 5, `Renderer.evaluate`. -/
def evaluate (c : Ctx F P K) (w : W F P K B) : W F P K B :=
  if w.queued = false ∨ w.sh.mounted = false then w else
  let isMounting := decide ((w.entry.map (·.kind)) = some .mount)
  let frame := w.sh.frame
  let props := c.new.props
  let pc := decide (some props ≠ w.sh.sentProps)
  let fc := decide (some frame ≠ w.sh.sentFrame)
  let entry :=
    if isMounting then updateE w.entry (fun x => { x with frame := some frame, props := some props })
    else if pc ∨ fc then
      updateE w.entry (fun x => { x with
        props := if pc then some props else x.props
        frame := if fc then some frame else x.frame })
    else w.entry
  let sh := { w.sh with sentProps := some props, sentFrame := some frame }
  let w := { w with sh, entry }
  if sh.ist.display = false then w
  else if c.new.key ≠ sh.drawnKey then
    match c.new.key with
    | some k => { w with job := some k }
    | none =>
      { w with
        sh := { sh with drawnKey := none, contents := none }
        entry := if sh.contents.isSome
          then updateE entry (fun x => { x with contents := some .clear }) else entry }
  else if isMounting then
    match sh.contents with
    | some b => { w with entry := updateE entry (fun x => { x with contents := some (.set b) }) }
    | none => w
  else w

/-- End of step 5: the mounted children, when they changed. -/
def childrenStep (c : Ctx F P K) (w : W F P K B) : W F P K B :=
  if c.childrenChanged = true ∧ w.sh.mounted = true then
    { w with entry := updateE w.entry (fun x => { x with children := some c.kids }) }
  else w

/-- Step 6, `Renderer.draw`: keep a bitmap only if it wasn't cancelled and the
node is still mounted and in the display range. -/
def drawStep (bmp : K → B) (c : Ctx F P K) (w : W F P K B) : W F P K B :=
  match w.job with
  | none => w
  | some k =>
    if c.cancelled = false ∧ w.sh.mounted = true ∧ w.sh.ist.display = true then
      { w with sh := { w.sh with contents := some (bmp k), drawnKey := some k }
               entry := updateE w.entry (fun x => { x with contents := some (.set (bmp k)) }) }
    else w

/-- One node through one pass. -/
def nodePass (bmp : K → B) (c : Ctx F P K) (sh : Sh F P K B) : W F P K B :=
  drawStep bmp c <| childrenStep c <| evaluate c <| assignStep c <| frameStep c
    { sh, entry := none, queued := c.synced || c.extra, job := none }

end steps

/-! ## Hypotheses -/

/-- Props and drawing keys change only for a reason the pipeline acts on: the
node's own state (synced), the environment (forced), its frame, or for a
scroll node its content frame (`extra`). -/
def Deps (c : Ctx F P K) : Prop :=
  (c.new.props ≠ c.old.props ∨ c.new.key ≠ c.old.key) →
    c.synced = true ∨ c.forced = true ∨ c.extra = true ∨ c.new.frame ≠ c.old.frame

/-- The child list sent with the node is right: when nothing called
`childrenDidChange`, a node that stays mounted keeps its mounted children,
and a node that mounts has none. -/
def KidsOk (c : Ctx F P K) (kidsOld : List Node) : Prop :=
  c.childrenChanged = false → c.new.ist.preload = true →
    (c.old.ist.preload = true → c.kids = kidsOld) ∧ (c.old.ist.preload = false → c.kids = [])

/-! ## The node's state after each step -/

section proofs

variable [DecidableEq F] [DecidableEq P] [DecidableEq K]

set_option linter.unusedSectionVars false

/-- The node right after its interface state was assigned. -/
def afterAssign (bmp : K → B) (old new : Spec F P K) (q : Bool) : W F P K B where
  sh :=
    { frame := new.frame, ist := new.ist, mounted := new.ist.preload
      sentFrame := if old.ist.preload && new.ist.preload then some old.frame else none
      sentProps := if old.ist.preload && new.ist.preload then some old.props else none
      contents := if old.ist.display && new.ist.display then old.key.map bmp else none
      drawnKey := if old.ist.display && new.ist.display then old.key else none }
  entry :=
    if !old.ist.preload && new.ist.preload then some { kind := .mount }
    else if old.ist.preload && !new.ist.preload then some { kind := .unmount }
    else if old.ist.preload && old.ist.display && !new.ist.display && old.key.isSome then
      some { kind := .update, contents := some .clear }
    else none
  queued := q || (!old.ist.preload && new.ist.preload) || (!old.ist.display && new.ist.display)
  job := none

theorem frame_assign (bmp : K → B) (c : Ctx F P K) (ho : c.old.ist.Valid) (hn : c.new.ist.Valid) :
    assignStep c (frameStep c
      { sh := Sh.ofSpec bmp c.old, entry := none, queued := c.synced || c.extra, job := none }) =
    afterAssign bmp c.old c.new
      (c.synced || c.extra || c.forced || decide (c.old.frame ≠ c.new.frame)) := by
  obtain ⟨⟨of, ⟨op, od, ov⟩, opr, ok⟩, ⟨nf, ⟨np, nd, nv⟩, npr, nk⟩, sy, fo, ex, cc, kids, ca⟩ := c
  simp only [IState.Valid] at ho hn
  simp only [frameStep, assignStep, transition, Sh.ofSpec, afterAssign]
  cases op <;> cases od <;> cases ov <;> cases np <;> cases nd <;> cases nv <;>
    simp at ho hn <;> cases fo <;> cases sy <;> cases ex <;> by_cases he : of = nf <;>
    cases ok <;> simp_all [recordE, updateE]

theorem nodePass_eq (bmp : K → B) (c : Ctx F P K) (ho : c.old.ist.Valid) (hn : c.new.ist.Valid) :
    nodePass bmp c (Sh.ofSpec bmp c.old) =
      drawStep bmp c (childrenStep c (evaluate c (afterAssign bmp c.old c.new
        (c.synced || c.extra || c.forced || decide (c.old.frame ≠ c.new.frame))))) := by
  unfold nodePass
  rw [frame_assign bmp c ho hn]

/-- The key whose bitmap the node holds after the pass: the new one, unless
its drawing was cancelled, in which case whatever it held before. -/
def drawnAfter (c : Ctx F P K) (job : Option K) : Option K :=
  if c.cancelled = true ∧ job.isSome then
    (if c.old.ist.display && c.new.ist.display then c.old.key else none)
  else c.new.key

set_option maxHeartbeats 0 in
/-- The steps after the interface state, for any reason `q` to evaluate. -/
theorem rest_sound [Inhabited F] [Inhabited P] (bmp : K → B) (c : Ctx F P K) (q : Bool)
    (kidsOld : List Node) (ho : c.old.ist.Valid) (hn : c.new.ist.Valid)
    (hq : q = false → c.new.frame = c.old.frame ∧ c.new.props = c.old.props ∧ c.new.key = c.old.key)
    (hkids : KidsOk c kidsOld) :
    let w := drawStep bmp c (childrenStep c (evaluate c (afterAssign bmp c.old c.new q)))
    let shown := { c.new with key := drawnAfter c w.job }
    w.sh = Sh.ofSpec bmp shown ∧
      applyOpt w.entry (c.old.view bmp kidsOld) = shown.view bmp c.kids := by
  obtain ⟨⟨of, ⟨op, od, ov⟩, opr, ok⟩, ⟨nf, ⟨np, nd, nv⟩, npr, nk⟩, sy, fo, ex, cc, kids, ca⟩ := c
  simp only [IState.Valid, KidsOk] at ho hn hkids hq
  simp only [afterAssign, evaluate, childrenStep, drawStep, Sh.ofSpec, Spec.view, drawnAfter]
  cases op <;> cases od <;> cases np <;> cases nd <;> simp at ho hn <;>
    cases q <;> cases cc <;> cases ca <;> by_cases he : of = nf <;> by_cases hp : opr = npr <;>
    rcases ok with _ | k₁ <;> rcases nk with _ | k₂ <;> (try by_cases hk : k₁ = k₂) <;> (try subst hk) <;>
    (try have hk' := Ne.symm hk) <;>
    simp_all [updateE, applyOpt, Entry.apply, applyContents, @eq_comm _ npr opr, @eq_comm _ nf of]

set_option maxHeartbeats 0 in
/-- What the entries and draw jobs of a node can be. -/
theorem rest_shape (bmp : K → B) (c : Ctx F P K) (q : Bool)
    (ho : c.old.ist.Valid) (hn : c.new.ist.Valid) :
    let w := drawStep bmp c (childrenStep c (evaluate c (afterAssign bmp c.old c.new q)))
    (∀ e, w.entry = some e → e.kind = .update → c.old.ist.preload = true) ∧
    (∀ e, w.entry = some e → e.kind = .mount →
      e.frame = some c.new.frame ∧ e.props = some c.new.props) ∧
    (∀ k, w.job = some k → c.new.ist.display = true ∧ c.new.key = some k ∧
      ¬ (c.old.ist.display = true ∧ c.old.key = some k)) := by
  obtain ⟨⟨of, ⟨op, od, ov⟩, opr, ok⟩, ⟨nf, ⟨np, nd, nv⟩, npr, nk⟩, sy, fo, ex, cc, kids, ca⟩ := c
  simp only [IState.Valid] at ho hn
  simp only [afterAssign, evaluate, childrenStep, drawStep]
  cases op <;> cases od <;> cases np <;> cases nd <;> simp at ho hn <;>
    cases q <;> cases cc <;> cases ca <;> by_cases he : of = nf <;> by_cases hp : opr = npr <;>
    rcases ok with _ | k₁ <;> rcases nk with _ | k₂ <;> (try by_cases hk : k₁ = k₂) <;> (try subst hk) <;>
    (try have hk' := Ne.symm hk) <;>
    simp_all [updateE, @eq_comm _ npr opr, @eq_comm _ nf of]

set_option maxHeartbeats 0 in
/-- A node whose spec didn't change and whose children didn't change gets no
entry and no drawing, even in a forced pass. -/
theorem rest_unchanged (bmp : K → B) (c : Ctx F P K) (q : Bool)
    (ho : c.old.ist.Valid) (heq : c.old = c.new) (hcc : c.childrenChanged = false) :
    let w := drawStep bmp c (childrenStep c (evaluate c (afterAssign bmp c.old c.new q)))
    w.entry = none ∧ w.job = none := by
  obtain ⟨⟨of, ⟨op, od, ov⟩, opr, ok⟩, new, sy, fo, ex, cc, kids, ca⟩ := c
  simp only at heq hcc
  subst heq hcc
  simp only [IState.Valid] at ho
  simp only [afterAssign, evaluate, childrenStep, drawStep]
  cases op <;> cases od <;> simp at ho <;> cases q <;> rcases ok with _ | k₁ <;> simp_all

end proofs

/-! ## One node: the results -/

section results

variable [DecidableEq F] [DecidableEq P] [DecidableEq K]

set_option linter.unusedSectionVars false

theorem q_false {c : Ctx F P K} (hd : Deps c)
    (h : (c.synced || c.extra || c.forced || decide (c.old.frame ≠ c.new.frame)) = false) :
    c.new.frame = c.old.frame ∧ c.new.props = c.old.props ∧ c.new.key = c.old.key := by
  have hs : c.synced = false := by cases e : c.synced <;> simp_all
  have he : c.extra = false := by cases e : c.extra <;> simp_all
  have hf : c.forced = false := by cases e : c.forced <;> simp_all
  have hfr : c.old.frame = c.new.frame := by
    by_cases e : c.old.frame = c.new.frame
    · exact e
    · simp [hs, he, hf, e] at h
  refine ⟨hfr.symm, ?_⟩
  by_cases hc : c.new.props ≠ c.old.props ∨ c.new.key ≠ c.old.key
  · rcases hd hc with h1 | h1 | h1 | h1
    · simp [hs] at h1
    · simp [hf] at h1
    · simp [he] at h1
    · exact absurd hfr.symm h1
  · constructor
    · by_cases e : c.new.props = c.old.props
      · exact e
      · exact absurd (Or.inl e) hc
    · by_cases e : c.new.key = c.old.key
      · exact e
      · exact absurd (Or.inr e) hc

/-- **One node, one pass.** Starting from a shadow that matches what the
main thread shows, the pass leaves a shadow matching the node's new spec
(with, for a cancelled drawing, the bitmap it already had), and the entry it
puts in the commit turns the main thread's view into exactly that. -/
theorem nodePass_shown [Inhabited F] [Inhabited P] (bmp : K → B) (c : Ctx F P K)
    (kidsOld : List Node) (ho : c.old.ist.Valid) (hn : c.new.ist.Valid) (hd : Deps c)
    (hkids : KidsOk c kidsOld) :
    let w := nodePass bmp c (Sh.ofSpec bmp c.old)
    let shown := { c.new with key := drawnAfter c w.job }
    w.sh = Sh.ofSpec bmp shown ∧
      applyOpt w.entry (c.old.view bmp kidsOld) = shown.view bmp c.kids := by
  simp only [nodePass_eq bmp c ho hn]
  exact rest_sound bmp c _ kidsOld ho hn (q_false hd) hkids

/-- Without cancellation the node ends up showing exactly its new spec. -/
theorem nodePass_sound [Inhabited F] [Inhabited P] (bmp : K → B) (c : Ctx F P K)
    (kidsOld : List Node) (ho : c.old.ist.Valid) (hn : c.new.ist.Valid) (hd : Deps c)
    (hkids : KidsOk c kidsOld) (hc : c.cancelled = false) :
    let w := nodePass bmp c (Sh.ofSpec bmp c.old)
    w.sh = Sh.ofSpec bmp c.new ∧ applyOpt w.entry (c.old.view bmp kidsOld) = c.new.view bmp c.kids := by
  have h := nodePass_shown bmp c kidsOld ho hn hd hkids
  have hdr : drawnAfter c (nodePass bmp c (Sh.ofSpec bmp c.old)).job = c.new.key := by
    simp [drawnAfter, hc]
  simp only [hdr] at h
  exact h

/-- Entries are well formed: an `update` only for a node that already had a
view, and a `mount` carries the frame and props. -/
theorem nodePass_entries (bmp : K → B) (c : Ctx F P K) (ho : c.old.ist.Valid)
    (hn : c.new.ist.Valid) :
    let w := nodePass bmp c (Sh.ofSpec bmp c.old)
    (∀ e, w.entry = some e → e.kind = .update → c.old.ist.preload = true) ∧
    (∀ e, w.entry = some e → e.kind = .mount →
      e.frame = some c.new.frame ∧ e.props = some c.new.props) := by
  simp only [nodePass_eq bmp c ho hn]
  have := rest_shape bmp c (c.synced || c.extra || c.forced || decide (c.old.frame ≠ c.new.frame)) ho hn
  exact ⟨this.1, this.2.1⟩

/-- **A bitmap is drawn only when it is out of date**: the node is in the
display range and its drawing key differs from the one its bitmap was drawn
for (or it had none). So a node draws at most once per pass, and never for an
unchanged key. -/
theorem nodePass_draws_only_stale (bmp : K → B) (c : Ctx F P K) (ho : c.old.ist.Valid)
    (hn : c.new.ist.Valid) {k : K} (hk : (nodePass bmp c (Sh.ofSpec bmp c.old)).job = some k) :
    c.new.ist.display = true ∧ c.new.key = some k ∧
      ¬ (c.old.ist.display = true ∧ c.old.key = some k) := by
  simp only [nodePass_eq bmp c ho hn] at hk
  exact (rest_shape bmp c _ ho hn).2.2 k hk

/-- **Unchanged nodes cost nothing to send or draw**: no entry, no drawing,
whatever the reason the pass looked at them. -/
theorem nodePass_unchanged (bmp : K → B) (c : Ctx F P K) (ho : c.old.ist.Valid)
    (heq : c.old = c.new) (hcc : c.childrenChanged = false) :
    (nodePass bmp c (Sh.ofSpec bmp c.old)).entry = none ∧
      (nodePass bmp c (Sh.ofSpec bmp c.old)).job = none := by
  have hn : c.new.ist.Valid := heq ▸ ho
  simp only [nodePass_eq bmp c ho hn]
  exact rest_unchanged bmp c _ ho heq hcc

/-- `evaluate` does work for a node only if it is mounted and queued. -/
def evaluates (c : Ctx F P K) : Bool :=
  (c.synced || c.extra || c.forced || decide (c.old.frame ≠ c.new.frame) ||
    (!c.old.ist.preload && c.new.ist.preload) || (!c.old.ist.display && c.new.ist.display)) &&
  c.new.ist.preload

/-- **A clean node is not evaluated**: not synced, not forced, same frame,
no interface-state change that mounts it or brings it into the display
range. -/
theorem clean_not_evaluated (c : Ctx F P K) (hs : c.synced = false) (he : c.extra = false)
    (hf : c.forced = false) (hfr : c.old.frame = c.new.frame) (hi : c.old.ist = c.new.ist) :
    evaluates c = false := by
  simp [evaluates, hs, he, hf, hfr, hi]

end results

end UltraProofs.Pass
