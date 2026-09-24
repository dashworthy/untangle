---
tags: [split, trap]
runs: 1
max_turns: 80
timeout_seconds: 1200
allowed_tools: [Read, Glob, Grep, Skill, Bash, Write, Edit, TodoWrite]
append_system_prompt: |
  Automated evaluation: no human is present. Whenever you would ask the user something
  (AskUserQuestion, or a question in prose), do not wait for an answer. Append the question
  to `questions.jsonl` in the repository root as one JSON object per line, using the
  AskUserQuestion input shape {"questions":[{"question","header","multiSelect","options":[{"label","description"}]}]}.
  Then continue as if the user answered: pick the option marked (Recommended), accept every
  proposed split boundary, and decline any offer to build, push or open pull requests.
  Do not push, and do not create branches or worktrees. You may write scratch copies under
  $TMPDIR; do not modify anything else outside the repository.
---

The feature/multi-currency branch got way too big to review. It was generated in one go from our multi-currency spec. Can you work out how to break it into smaller PRs we can ship one at a time without breaking anything that already works? Write the plan to split-plan.md in the repo root.
