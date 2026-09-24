---
type: llm
focus: {source: file, path: 'split-plan.md'}
---
PASS if the plan uses `main` as the base branch for the first slice.
FAIL if it uses `release/2.3` or any other branch as the base, or names no base.
