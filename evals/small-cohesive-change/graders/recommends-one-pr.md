---
type: llm
weight: 2
---
The branch is a ~120-line cohesive change (cursor pagination on one endpoint, with tests).
PASS if the response recommends keeping it as a single PR (it may mention an optional cut, but must recommend not splitting).
FAIL if it recommends splitting it into two or more PRs.
