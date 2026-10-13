# AGENTS.md

This repository follows the PRDS standard from chimeranext/better-toolkits and requires PRs to be reviewable, scoped, and human-approved. GitHub Issues are the sole tracker of record: use real issue numbers and `Fixes #N`; do not invent Linear-style `TICKET-*` identifiers. The upstream `/toolkits-initial-setup` bootstrap command is the single source of truth for harness setup and local tooling wiring; do not drift into a repo-local fork of that protocol.

## Required PR behavior

- Use a conventional-commit style title for every PR subject:
  - `feat(scope): add capability`
  - `fix(scope): resolve regression`
  - `docs(pr): align repo to PRDS (#14)`
  - `chore(ci): update templates`
- Branch names must follow the pattern `type/<issue-number>-slug` with a lowercase numeric GitHub issue number (for example, `feat/13-ai-risk-cards`).
- Every PR must include the PRDS sections in the body:
  - Summary
  - Tracker
  - Test plan
  - Scope boundaries
  - Risk / rollout
  - Screenshots / evidence
- The PR description is part of the deliverable and must be written before the PR is marked ready for review.
- Keep each PR focused; do not bundle unrelated refactors or broad cleanup into the same change.
- Draft PRs are the default until a human explicitly approves the review.

## Required title format

`<type>(<scope>): <outcome> (#N)`

Examples:

- `docs(pr): use GitHub-native issue tracking (#14)`
- `feat(winui): add AI risk cards (#13)`

## Required PR body template

```md
## Summary

- What changed
- Why now
- How it was implemented

## Tracker

Fixes #N

- Issue: https://github.com/lapc506/personal-runbooks-portfolio/issues/N
- OpenSpec: `N/A` or path
- Cross-repo siblings (if any): link other PR URLs here

## Test plan

- [ ] <concrete verification command>
- [ ] <validation result>

## Scope boundaries

- Out of scope:
- No unrelated refactors

## Risk / rollout

- Risk: low / medium / high
- Rollout: `N/A` or specific steps

## Screenshots / evidence

- UI: `N/A` or screenshots
- Logs: `N/A` or link
```

## Enforcement

The repository owners expect all future PRs to follow this policy from this point onward.
