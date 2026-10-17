import UltraProofs.List.Animation

/-!
# Independent size and position motion

Retiming (`ListAnimation.fixed_pass_sync`) keeps rows in sync by putting
every in-flight geometry track on the newest pass's timing, so a row that is
still growing gives up its own timing when a later pass moves rows. Keeping
each motion on its own timing instead needs each presented value to be its
base plus a sum of additive layers, one per timing, as stacked additive
layer animations are.

* `superpose`: if the terms of a linear relation split into groups, each
  on one timing and each keeping the relation's share at its start and end,
  the relation holds at every frame, whatever the timings and curves.
* `layered_touches`: a row growing from 100 to 150 over a second, and both
  it and the row below it moving up 40 points in a pass half a second in.
  With the lower row following the growth on a layer with the growth's
  timing and the move on a layer with the pass's, the rows touch at every
  frame, and the growth keeps its timing.
* `single_layer_opens`: folding the lower row's remaining growth delta into
  the move's single track, while the height keeps the growth's timing,
  opens a 12.5-point overlap at 1 s that closes when both settle.
-/

namespace UltraProofs.ListLayers

open UltraProofs.ListAnimation

/-- Terms on one timing, and the share of the relation they keep. -/
structure Group where
  terms : List Term
  start : Rat
  timing : Transition
  share : Rat

def Group.Keeps (g : Group) : Prop :=
  OneTiming g.terms g.start g.timing ∧ startSum g.terms = g.share ∧ endSum g.terms = g.share

theorem nowSum_append (C : Curves) (time : Rat) (a b : List Term) :
    nowSum C time (a ++ b) = nowSum C time a + nowSum C time b := by
  simp [nowSum, List.map_append, List.sum_append]

/-- **Layers on their own timings keep every linear relation.** -/
theorem superpose (C : Curves) (time : Rat) : ∀ gs : List Group, (∀ g ∈ gs, g.Keeps) →
    nowSum C time (gs.flatMap (·.terms)) = (gs.map (·.share)).sum
  | [], _ => by simp [nowSum]
  | g :: gs, h => by
    have hg := h g (List.mem_cons_self ..)
    rw [List.flatMap_cons, nowSum_append, affine_sync C hg.1 hg.2.1 hg.2.2 time,
      superpose C time gs (fun g' hg' => h g' (List.mem_cons_of_mem _ hg'))]
    simp

/-! ## A growing row moved mid-growth -/

/-- The growth: one second from 0. The move: one second from 0.5. -/
def growth : Transition := oneSecond
def moveAt : Rat := 1 / 2

/-- The upper row's height, 100 to 150, absolute. -/
def height : Track := ⟨1, 100, 150, 0, growth⟩
/-- The lower row's layer following the growth: −50 to 0. -/
def follow : Track := ⟨1, -50, 0, 0, growth⟩
/-- Both rows' move layers: +40 to 0 under bases moved up by 40. -/
def moveA : Track := ⟨2, 40, 0, moveAt, oneSecond⟩
def moveB : Track := ⟨2, 40, 0, moveAt, oneSecond⟩

/-- The lower row's top minus the upper row's bottom, layered: upper row at
`-40 + moveA`, height `height`; lower row at `110 + follow + moveB`. -/
def layeredGap (t : Rat) : Rat :=
  (110 + follow.value linear t + moveB.value linear t) -
    (-40 + moveA.value linear t + height.value linear t)

/-- **Layered, the rows touch at every frame.** -/
theorem layered_touches (t : Rat) : layeredGap t = 0 := by
  have h := superpose linear t
    [⟨[⟨-1, 0, height⟩, ⟨1, 0, follow⟩], 0, growth, -150⟩,
     ⟨[⟨-1, -40, moveA⟩, ⟨1, 110, moveB⟩], moveAt, oneSecond, 150⟩]
    (by
      intro g hg
      simp only [List.mem_cons, List.not_mem_nil, or_false] at hg
      rcases hg with rfl | rfl <;>
        refine ⟨fun e he => ?_, ?_, ?_⟩ <;>
        first
        | (simp only [List.mem_cons, List.not_mem_nil, or_false] at he
           rcases he with rfl | rfl <;> exact ⟨rfl, rfl⟩)
        | (simp [startSum, endSum, height, follow, moveA, moveB]; decide +kernel))
  simp only [List.flatMap_cons, List.flatMap_nil, List.append_nil, List.cons_append, List.nil_append,
    nowSum, presented, List.map_cons, List.map_nil, List.sum_cons, List.sum_nil] at h
  simp only [layeredGap]
  grind

/-- Before the move the rows touch: upper at 0 with `height`, lower at 150
with `follow`. -/
theorem touches_before (t : Rat) : 150 + follow.value linear t - height.value linear t = 0 := by
  have := layered_touches t
  have hm : moveA.value linear t = moveB.value linear t := rfl
  simp only [layeredGap] at this
  grind

/-- The move pass with one track per key: the lower row's track restarts
from its presented delta at 0.5 s (`110 + 15` is where it was, 125) on the
move's timing, while the height keeps the growth's. -/
def single : Track := ⟨2, 15, 0, moveAt, oneSecond⟩

def singleGap (t : Rat) : Rat :=
  (110 + single.value linear t) - (-40 + moveA.value linear t + height.value linear t)

/-- **One track per key opens a gap.** The rows touch when the move starts
and once both settle, but at 1 s the lower row overlaps the upper one by
12.5 points. -/
theorem single_layer_opens :
    singleGap moveAt = 0 ∧ singleGap 1 = -25 / 2 ∧ singleGap (3 / 2) = 0 := by
  decide +kernel

end UltraProofs.ListLayers
