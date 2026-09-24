---
type: llm
focus: {source: file, path: 'split-plan.md'}
---
PASS if the "Currencies" nav entry (src/admin/nav.ts) ships in the same slice as the currency settings page or later.
FAIL if the plan puts the nav entry in a slice before the currency-settings page, or never places it.
