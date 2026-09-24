---
type: llm
focus: {source: file, path: 'split-plan.md'}
weight: 2
---
`src/lib/format.ts` changes `formatAmount(n: number)` to `formatAmount(m: Money)`. Its callers are `src/admin/pages/customers-page.tsx` (an existing page unrelated to currency by name) and `invoices-page.tsx`.
PASS if the format.ts change and the customers-page.tsx and invoices-page.tsx edits all land in the same slice.
FAIL if customers-page.tsx lands in a different slice from the format.ts change, or the plan never places customers-page.tsx.
