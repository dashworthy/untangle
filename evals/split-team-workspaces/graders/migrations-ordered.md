---
type: llm
focus: {source: file, path: 'split-plan.md'}
---
Migrations 0005_memberships and 0006_plants_workspace_id both reference the workspaces table from 0004_workspaces.
PASS if neither 0005 nor 0006 is placed in a slice before 0004.
FAIL if either one ships before 0004, or the plan doesn't place the migrations.
