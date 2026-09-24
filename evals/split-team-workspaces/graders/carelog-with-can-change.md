---
type: llm
focus: {source: file, path: 'split-plan.md'}
weight: 2
---
`permissions.can()` changes from `can(user, ...)` to `can(actor, ...)` with a new `Actor` type. `sprout/carelog/api.py` and `tests/carelog/test_carelog_api.py` (existing care-log code, unrelated to workspaces by name) are updated for it.
PASS if the carelog/api.py and carelog test changes land in the same slice as the can()/Actor change in permissions.py.
FAIL if they land in a different slice, or the plan never places the carelog files.
