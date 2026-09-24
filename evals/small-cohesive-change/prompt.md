---
tags: [negative]
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

Can you split feature/paginate-books into smaller PRs so it's easier to review? If you write a plan, put it in split-plan.md at the repo root.
