# Merge Request Information Contract

This reference defines how the Git Push workflow prepares MR information. It does not create, update, approve, assign, label, or merge an MR.

## Format precedence

Use the first applicable format source:

1. An explicit format or language requested by the user.
2. A repository merge-request template.
3. A project-level MR Skill or documented project convention.
4. This general fallback.

A project-specific format may replace the fallback, but the Push workflow must preserve the project's headings and order rather than inventing a second format.

## Suggested title

Prefer the current task's commit subject. If no commit subject exists, use a concise `type(scope): summary` title supported by the task request and repository convention. Keep identifiers, branch names, and commands unchanged.

## Suggested description

Build the description only from facts supported by:

- the user's request and acceptance criteria;
- the current task log and index fragment;
- commits between the resolved target and source branches;
- the target-to-source diff summary;
- checks actually executed during this workflow;
- explicit exclusions or intentionally untouched scope.

Follow the selected project format. Under the general fallback, use:

```markdown
## Summary

- <purpose and affected workflow>

## Changed Files

- `<path>` - <concrete change>

## Verification

- <check actually run, or clearly stated not run>
```

Use `## Test Scenarios` only when the task changes user-visible or business behavior and concrete scenarios are available. Use `## Exclusions` only when explicit exclusions materially help reviewers. For small changes, `## Summary` and `## Verification` are sufficient. Omit empty sections.

## Quality and safety

- State what changed and why, not a large raw diff.
- Do not claim a build, test, review, or deployment that did not run.
- Do not include uncommitted unrelated changes.
- Do not include secrets, tokens, or unrelated private information.
- Do not append `Co-Authored-By:` or `🤖 Generated with` lines.
- Keep the description concise and reviewer-oriented.

## Why this is not scripted yet

The section selection and wording still depend on repository context and project-specific MR conventions. They have not yet stabilized across enough repeated tasks to justify a generator. Keep the contract explicit and reviewable until repeated usage provides a stable scripting boundary.
