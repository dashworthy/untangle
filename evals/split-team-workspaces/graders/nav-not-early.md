---
type: llm
focus: {source: file, path: 'split-plan.md'}
---
PASS if the "Workspaces" and "Activity" nav links (templates/nav.html) ship no earlier than the pages they link to
(the workspaces pages and the member activity page respectively).
FAIL if either link ships in a slice before its page, or the plan never places nav.html.
