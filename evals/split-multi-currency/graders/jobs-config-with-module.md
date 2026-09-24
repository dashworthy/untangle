---
type: llm
focus: {source: file, path: 'split-plan.md'}
weight: 2
---
`config/jobs.json` gains a `refresh-rates` entry that the job registry loads by string via dynamic import; the module `src/jobs/refresh-rates.ts` arrives separately.
PASS if the plan ships the refresh-rates entry of config/jobs.json in the same slice as src/jobs/refresh-rates.ts or later (e.g. by hunk-splitting jobs.json).
FAIL if config/jobs.json ships whole in a slice before src/jobs/refresh-rates.ts, or the plan never places config/jobs.json.
