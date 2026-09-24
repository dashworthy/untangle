---
type: llm
focus: {source: file, path: 'split-plan.md'}
weight: 2
---
`sprout/config.py` gets two hunks in the audit-log commit: `AUDIT_RETENTION_DAYS` (used by the audit log) and a `"sprout.workspaces.api:bp"` entry in the string list of blueprints loaded via importlib.
PASS if the plan ships the workspaces blueprint entry in the same slice as sprout/workspaces/api.py or later (e.g. by hunk-splitting config.py).
FAIL if config.py ships whole with the audit slice or any slice before sprout/workspaces/api.py, or the plan never places config.py.
