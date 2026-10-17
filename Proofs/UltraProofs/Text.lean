import UltraProofs.Basic

/-!
# Text layouts are built once per width

`UltraTextNode.textLayout(fitting:)` keeps the node's recent layouts
(newest first, at most four) and reuses the first one that `fits` the
requested width; otherwise it builds one, puts it first and drops the
oldest past four. Yoga's measure function and `updateContentForFrame` both
go through it, and drawing uses the layout `updateContentForFrame` chose
(`TextDrawing` holds it; the drawing key carries its id), so drawing never
lays text out.

Hypothesis (the measurer's contract): a layout fits the width it was built
for (`TextLayout.fits` returns `true` when `width == maxWidth`).
-/

namespace UltraProofs.Text

variable {W L : Type} [DecidableEq W]

/-- One request: reuse a cached layout that fits, or build one. Returns the
new cache and whether a layout was built. -/
def request (fits : L → W → Bool) (build : W → L) (cache : List L) (w : W) : List L × Bool :=
  if cache.any (fits · w) then (cache, false) else ((build w :: cache).take 4, true)

/-- A sequence of requests (one pass: Yoga's measurements, then the final
width), counting builds. -/
def run (fits : L → W → Bool) (build : W → L) : List L → List W → List L × Nat
  | cache, [] => (cache, 0)
  | cache, w :: ws =>
    let (c, b) := request fits build cache w
    let (c', n) := run fits build c ws
    (c', n + if b then 1 else 0)

theorem nodup_length_le {l ds : List W} (hn : l.Nodup) (hs : ∀ x ∈ l, x ∈ ds) :
    l.length ≤ ds.length := by
  induction l generalizing ds with
  | nil => simp
  | cons a l ih =>
    have ha : a ∈ ds := hs a (List.mem_cons_self ..)
    have hn' := List.nodup_cons.1 hn
    have : l.length ≤ (ds.erase a).length := by
      apply ih hn'.2
      intro x hx
      have hxa : x ≠ a := by intro e; subst e; exact hn'.1 hx
      exact (List.mem_erase_of_ne hxa).2 (hs x (List.mem_cons_of_mem _ hx))
    rw [List.length_erase_of_mem ha] at this
    have : 0 < ds.length := List.length_pos_of_mem ha
    simp; omega

/-- Invariant: the cache holds one layout per width built so far, newest first. -/
def Holds (build : W → L) (cache : List L) (seen : List W) : Prop :=
  cache = seen.map build ∧ seen.Nodup

theorem run_builds (fits : L → W → Bool) (build : W → L)
    (hfit : ∀ w, fits (build w) w = true) (ds : List W) (hds : ds.length ≤ 4) :
    ∀ (ws : List W) (seen : List W), (∀ w ∈ ws, w ∈ ds) → (∀ w ∈ seen, w ∈ ds) →
      Holds build (seen.map build) seen →
      ∃ seen' : List W, (run fits build (seen.map build) ws).2 + seen.length = seen'.length ∧
        seen'.Nodup ∧ (∀ w ∈ seen', w ∈ ds) := by
  intro ws
  induction ws with
  | nil =>
    intro seen _ hseen hh
    exact ⟨seen, by simp [run], hh.2, hseen⟩
  | cons w ws ih =>
    intro seen hws hseen hh
    simp only [run, request]
    by_cases hf : (seen.map build).any (fits · w) = true
    · simp only [hf, ite_true]
      obtain ⟨s', h1, h2, h3⟩ := ih seen (fun x hx => hws x (List.mem_cons_of_mem _ hx)) hseen hh
      exact ⟨s', by simpa using h1, h2, h3⟩
    · simp only [hf]
      have hw : w ∉ seen := by
        intro hmem
        exact hf (List.any_eq_true.2 ⟨build w, List.mem_map_of_mem hmem, hfit w⟩)
      have hnd : (w :: seen).Nodup := List.nodup_cons.2 ⟨hw, hh.2⟩
      have hsub : ∀ x ∈ w :: seen, x ∈ ds := by
        intro x hx
        rcases List.mem_cons.1 hx with e | e
        · subst e; exact hws x (List.mem_cons_self ..)
        · exact hseen x e
      have hlen : (w :: seen).length ≤ 4 := Nat.le_trans (nodup_length_le hnd hsub) hds
      have htake : (build w :: seen.map build).take 4 = (w :: seen).map build := by
        rw [List.take_of_length_le (by simpa using hlen)]; simp
      rw [htake]
      obtain ⟨s', h1, h2, h3⟩ := ih (w :: seen) (fun x hx => hws x (List.mem_cons_of_mem _ hx))
        hsub ⟨rfl, hnd⟩
      refine ⟨s', ?_, h2, h3⟩
      simp at h1 ⊢; omega

/-- **Each width is laid out at most once per text**: when a pass asks for at
most four distinct widths (Yoga's measurements plus the final frame), the
number of layouts built is at most the number of distinct widths, however
many times each is requested. -/
theorem builds_le_distinct (fits : L → W → Bool) (build : W → L)
    (hfit : ∀ w, fits (build w) w = true) (ds : List W) (hds : ds.length ≤ 4)
    (ws : List W) (hws : ∀ w ∈ ws, w ∈ ds) : (run fits build [] ws).2 ≤ ds.length := by
  obtain ⟨s', h1, h2, h3⟩ := run_builds fits build hfit ds hds ws [] hws (by simp) ⟨rfl, List.nodup_nil⟩
  have := nodup_length_le h2 h3
  simp at h1; omega

end UltraProofs.Text
