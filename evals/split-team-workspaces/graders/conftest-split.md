---
type: llm
focus: {source: file, path: 'split-plan.md'}
weight: 2
---
`tests/conftest.py` gains a `make_workspace` fixture and, in the same commit, top-level imports of `sprout.workspaces.invites` / `sprout.models.invite` plus an `invite_token` fixture.
PASS if the plan hunk-splits conftest.py so the invites imports and `invite_token` fixture ship no earlier than the invites code.
FAIL if conftest.py ships whole in a slice before sprout/workspaces/invites.py exists, or the plan never places conftest.py.
