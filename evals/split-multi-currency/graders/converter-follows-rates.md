---
type: llm
focus: {source: file, path: 'split-plan.md'}
weight: 2
---
`src/lib/money/cached-rate-converter.ts` imports from `src/rates/`.
PASS if the plan puts cached-rate-converter.ts in the same slice as the src/rates code, or in a later one.
FAIL if cached-rate-converter.ts ships in a slice before the one that holds src/rates/rate-provider.ts
(for example, grouped with the money library ahead of the rates slice), or if the plan never places it.
