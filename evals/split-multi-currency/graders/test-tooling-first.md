---
type: llm
focus: {source: file, path: 'split-plan.md'}
---
The base branch has no test runner; the branch adds vitest (package.json + vitest.config.ts).
PASS if the vitest setup is placed in the first slice that contains tests, or in an earlier slice.
FAIL if any slice with tests is scheduled before the vitest setup, or the plan never places the vitest setup.
