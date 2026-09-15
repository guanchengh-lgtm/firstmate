# Fm Backend Herdr.Test 2

> 19 nodes · cohesion 0.16

## Key Concepts

- **make_death_lab()** (17 connections) — `tests/fm-backend-herdr.test.sh`
- **death_process_info_fixture()** (12 connections) — `tests/fm-backend-herdr.test.sh`
- **assert_projection_close_failed_removal_rolls_back_the_reposition()** (5 connections) — `tests/fm-backend-herdr.test.sh`
- **test_kill_emptying_non_focused_uses_pane_death()** (5 connections) — `tests/fm-backend-herdr.test.sh`
- **test_projection_close_death_escalates_sigkill_after_sighup_survival()** (5 connections) — `tests/fm-backend-herdr.test.sh`
- **test_projection_close_death_failure_falls_back_to_plain_close()** (5 connections) — `tests/fm-backend-herdr.test.sh`
- **test_projection_close_death_never_sigkills_a_reused_pid()** (5 connections) — `tests/fm-backend-herdr.test.sh`
- **test_projection_close_death_still_restores_a_stolen_focus()** (5 connections) — `tests/fm-backend-herdr.test.sh`
- **test_projection_close_emptying_after_focus_uses_pane_death_without_move()** (5 connections) — `tests/fm-backend-herdr.test.sh`
- **test_projection_close_emptying_before_focus_repositions_then_uses_pane_death()** (5 connections) — `tests/fm-backend-herdr.test.sh`
- **test_projection_close_emptying_before_last_focus_needs_no_move()** (5 connections) — `tests/fm-backend-herdr.test.sh`
- **test_projection_close_emptying_last_workspace_needs_no_move()** (5 connections) — `tests/fm-backend-herdr.test.sh`
- **test_projection_close_transient_prompt_helper_settles_then_uses_pane_death()** (5 connections) — `tests/fm-backend-herdr.test.sh`
- **test_kill_focused_workspace_stays_plain_close()** (4 connections) — `tests/fm-backend-herdr.test.sh`
- **test_projection_close_ambiguous_positions_fall_back_to_plain_close()** (4 connections) — `tests/fm-backend-herdr.test.sh`
- **test_projection_close_busy_pane_falls_back_to_plain_close()** (4 connections) — `tests/fm-backend-herdr.test.sh`
- **test_projection_close_move_failure_falls_back_to_plain_close()** (4 connections) — `tests/fm-backend-herdr.test.sh`
- **test_projection_close_non_emptying_stays_plain_without_proof_or_move()** (4 connections) — `tests/fm-backend-herdr.test.sh`
- **test_projection_close_failed_removal_rolls_back_the_reposition()** (3 connections) — `tests/fm-backend-herdr.test.sh`

## Relationships

- [Fm Backend Herdr.Test 1](Fm_Backend_Herdr.Test_1.md) (51 shared connections)

## Source Files

- `tests/fm-backend-herdr.test.sh`

## Audit Trail

- EXTRACTED: 79 (100%)
- INFERRED: 0 (0%)
- AMBIGUOUS: 0 (0%)

---

*Part of the graphify knowledge wiki. See [index](index.md) to navigate.*