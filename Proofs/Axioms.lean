import UltraProofs

/-! Prints the axioms every main theorem depends on. `scripts/proofs.sh`
fails if anything beyond Lean's standard `propext`, `Classical.choice` and
`Quot.sound` shows up (an unfinished proof would show `sorryAx`). -/

open UltraProofs

#print axioms Scheduling.Inv.step
#print axioms Scheduling.quiescent_clean
#print axioms Scheduling.progress
#print axioms Scheduling.settles
#print axioms Scheduling.PassInv.step
#print axioms Scheduling.visit_once
#print axioms Scheduling.sync_cost
#print axioms Scheduling.Count.step
#print axioms Scheduling.passes_le
#print axioms Scheduling.epoch_enqueues_at_most_one
#print axioms Commits.Commit.apply_merge
#print axioms Commits.take_is_newer
#print axioms Commits.views_after_take
#print axioms Pass.nodePass_shown
#print axioms Pass.nodePass_sound
#print axioms Pass.nodePass_entries
#print axioms Pass.nodePass_draws_only_stale
#print axioms Pass.nodePass_unchanged
#print axioms Pass.clean_not_evaluated
#print axioms Walks.collectFrames_complete
#print axioms Walks.collectFrames_visits
#print axioms Walks.assign_correct
#print axioms Walks.roots_needed
#print axioms Walks.spec_le_parent
#print axioms Global.pass_sound
#print axioms Global.kidsOk_of
#print axioms Global.run_sound
#print axioms EndToEnd.quiescent_shows_fresh_render
#print axioms EndToEnd.last_pass_renders
#print axioms Optimality.must_read
#print axioms Optimality.must_send
#print axioms Optimality.draws_exact
#print axioms Optimality.entry_only_if_changed
#print axioms Optimality.deps_of_inputs
#print axioms Optimality.stale_when_aux_ignored
#print axioms Optimality.round_relative_stable
#print axioms Optimality.round_size_stable
#print axioms Ranges.bitmap_iff
#print axioms Ranges.visible_implies_displayed
#print axioms Ranges.display_within_preload
#print axioms Ranges.range_contiguous
#print axioms Ranges.changed_le_swift
#print axioms Text.builds_le_distinct
#print axioms Power.idle_only_client
#print axioms Power.idle_clean
#print axioms Power.redundant_pass_cost
#print axioms Power.apply_local
#print axioms Corrected.FixedStep.inv
#print axioms Corrected.FixedCount.step
#print axioms Corrected.fixed_passes_le
#print axioms Corrected.DQInv.step
#print axioms Corrected.dq_idle_clean
#print axioms Corrected.dq_start_work
#print axioms Corrected.swift_spins
#print axioms Corrected.fixed_spins
#print axioms Corrected.move_redraws
#print axioms Corrected.kept_draws_only_changed
