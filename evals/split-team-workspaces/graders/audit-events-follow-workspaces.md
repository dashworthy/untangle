---
type: llm
focus: {source: file, path: 'split-plan.md'}
weight: 2
---
`sprout/audit/workspace_events.py` imports the Workspace model.
PASS if the plan puts workspace_events.py in the same slice as sprout/models/workspace.py, or in a later one.
FAIL if workspace_events.py ships in a slice before the Workspace model (for example, grouped with the
generic audit log ahead of workspaces), or if the plan never places it.
