import UltraProofs.Scheduling
import UltraProofs.Commit

/-!
# Power: nothing runs while nothing changes

In the scheduling model every step is either caused by a client (a node
mutation, which covers style, text, children and scroll offset reports
through `setNeedsSync`, or a host update: size, window, appearance) or is
work a client step made due (walks, queued passes and their visits).

The Swift has no timers, display links or polling in the pipeline: the
layout queue runs only blocks that `setNeedsPass`/`update` enqueued, and the
main thread runs only commits the sink posted. The one timer in UltraCore is
the long-press `Task` in `NodeView`, started by a touch and cancelled when
the press ends. `waitUntilIdle` spins, but it is a test helper (`settle()`).
-/

namespace UltraProofs.Power

open UltraProofs UltraProofs.Scheduling UltraProofs.Commits

/-- Idle: no walk in flight, no pass running, none queued. -/
def Idle (s : State) : Prop := s.walkers = [] ∧ s.running = false ∧ s.queued = 0

/-- Steps a client causes. -/
def ClientStep (s s' : State) : Prop :=
  (∃ n, s' = { s with needs := upd s.needs n true, walkers := n :: s.walkers
                      mutations := s.mutations + 1 }) ∨
  s' = { s with scheduled := true, queued := s.queued + 1, updates := s.updates + 1 }

/-- **When idle, only a client can make anything happen**: no pass, walk or
visit is possible until a mutation or host update arrives. -/
theorem idle_only_client {t : Tree} {s s' : State} (hI : Inv t s) (hidle : Idle s)
    (h : Step t s s') : ClientStep s s' := by
  obtain ⟨hw, hr, hq⟩ := hidle
  obtain ⟨hp, hb⟩ := hI.idle hr
  cases h with
  | mutate n => exact .inl ⟨n, rfl⟩
  | hostUpdate => exact .inr rfl
  | walkUp v p hv => simp [hw] at hv
  | walkRoot hv => simp [hw] at hv
  | start _ hq' => omega
  | visitA v rest hp' => rw [hp] at hp'; cases hp'
  | visitB v hb' => rw [hb] at hb'; cases hb'
  | finish hr' => rw [hr] at hr'; cases hr'

/-- When idle, every flag is clear: the idle state owes no work. -/
theorem idle_clean {t : Tree} {s : State} (hI : Inv t s) (hidle : Idle s) :
    ∀ n, s.needs n = false ∧ s.desc n = false := by
  obtain ⟨hw, hr, hq⟩ := hidle
  apply quiescent_clean hI hw hr
  cases hs : s.scheduled
  · rfl
  · have := hI.sched hs; omega

/-- A pass that finds nothing marked visits only the root in its sync walk.
(The rest of the Swift `runPass` still calls Yoga and walks the root's
children in `collectFrames`; see finding 1 for the early exit.) -/
theorem redundant_pass_cost {t : Tree} {s : State} (hP : PassInv t s) (hp : s.pending = [])
    (hex : s.expanded = []) : s.visited.length = 1 := by
  have := sync_cost hP hp; rw [hex] at this; simpa using this

/-- **The main thread touches only nodes in the commit**: applying a commit
leaves every other view as it was, so with minimal entries
(`Optimality.entry_only_if_changed`) its work follows the changed nodes. -/
theorem apply_local {F P B : Type} [Inhabited F] [Inhabited P] (c : Commit F P B)
    (v : ViewState F P B) (n : Node) (h : c.entries n = none) : c.apply v n = v n := by
  simp [Commit.apply, h, applyOpt]

end UltraProofs.Power
