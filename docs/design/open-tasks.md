# Tasks marked for later

Tasks the user has asked to keep for a later session. Not decisions: a decision
is recorded in `decisions.md` only after the user answers. An entry is removed
when the task is done and its outcome is recorded elsewhere.

## Gap review against a large bank's internal platform (marked 2026-11-17)

Use the advisor model and its knowledge of a large bank's internal platform
environment to identify major gaps in the current specs (`specs/`, source of
design intent: `veridian_research.md`). Then discuss with the user what to
specify on our side; nothing is added to the specs before that discussion.

How to run it:
- Hand the advisor the spec list and the design summary, and ask for gaps by
  area (risk model, data, orchestration, user tools, controls, operations),
  each with a reason and how that platform handles it.
- Treat its knowledge of that platform as public-source hypotheses, not facts about the
  bank's internal system: mark each claim as known, inferred or unsure, and
  check material ones before any spec depends on them.
- Output: a ranked gap list for the user to discuss; no spec edits, no
  decision entries, until the user chooses what to specify.

Status 2026-11-18: the list is written, `gap-review-2026-11-18.md` (12 gaps,
checked against the specs). The discussion with the user is still to come;
this task stays open until the user has chosen what to specify.

## Keep spec and model files short (user rule 2026-11-17)

Allium specs stay under about 400 lines and Quint models under about 500.
Done: spec 02 and the graph model (D-065); specs 07, 20, 04, 19, 01, 21, 06, 13
and 10 (D-070). Every spec file is now under 400 lines and every model under
500 (largest: 02 at 399, `calc_graph.qnt` at 486). The split is by script
(`use` between the parts, `// spec:` tags repointed, gate green). New material
goes into new files instead of growing a large one.
