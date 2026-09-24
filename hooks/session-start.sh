#!/bin/sh
# SessionStart hook for the untangle plugin: routes oversized-PR splitting to the skill.
#
# Injects guidance only; it never blocks, never touches git, never reads or writes a
# file, and does not depend on jq.

message='When a pull request, branch, or diff is too big to review and the user wants it split, broken up, sliced, chunked, or stacked into smaller PRs (or asks where its natural seams are), use the `untangle:untangle` skill before any other entrance or design skill. It takes precedence over feature-discovery and brainstorming skills for this request, because the code already exists and the work is finding safe cut lines, not designing new behavior.'

printf '{\n  "hookSpecificOutput": {\n    "hookEventName": "SessionStart",\n    "additionalContext": "%s"\n  }\n}\n' "$message"

exit 0
