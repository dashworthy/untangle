---
type: llm
focus: {source: file, path: 'split-plan.md'}
---
`src/routes.ts` adds a `rateConverter()` helper that reads `app.locals.converter`; `src/server.ts` sets `app.locals.converter`. Neither works without the other.
PASS if the plan puts the routes.ts rateConverter hunk and the server.ts app.locals.converter hunk in the same slice.
FAIL if they land in different slices, or the plan doesn't address them.
