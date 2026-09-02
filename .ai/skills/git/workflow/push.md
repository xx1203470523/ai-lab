# Git Push

## 1. Pre-checks

### Repository and branch

1. Confirm the current directory is inside a Git repository.
2. Inspect `git status` and identify modified and untracked files.
3. Confirm that `origin` is reachable.
4. Reject the operation when the current branch is `main`, `master`, `production`, or `staging`.
5. Resolve one target/base branch before rebase. Prefer, in order:
   - an explicit target supplied by the user;
   - the repository's documented MR or branch policy;
   - the remote default branch reported by Git or the hosting tool.
6. If no target can be resolved without guessing, stop and ask the user. Use the same resolved target for fetch, rebase, MR lookup, and the creation link.

### Commit scope and local conventions

- Read `../reference/push/push.md` before pushing.
- If the repository has a custom commit convention, read `../reference/commit/custom.md`.
- Load `../reference/merge-request/custom.md` when preparing MR title or description.
- Keep unrelated dirty files unchanged and out of the commit.

## 2. Rebase check

Before committing, fetch and rebase onto the resolved remote target:

```text
git fetch origin <target-branch>
git rebase origin/<target-branch>
```

If rebase conflicts, run `git rebase --abort`, report the conflicting files, and stop. Do not force a resolution or use a merge as a shortcut.

## 3. Commit

### Scope control

Commit only changes belonging to the current task. Stage files explicitly; never use `git add -A` or `git add .`.

### Commit message

Follow the loaded repository/project convention. The commit message must not end with `Co-Authored-By:` or `🤖 Generated with` lines.

## 4. Push

```text
git push -u origin <source-branch>
```

After a successful push, report the source branch, commit hash, push result, and MR lookup/link result.

## 5. MR lookup and suggested content

1. Set `source-branch` to the current branch and use the single previously resolved target branch.
2. Check for an existing MR using both branches:

```text
glab mr list --source-branch <source-branch> --target-branch <target-branch> --output json
```

3. If a matching MR exists, report its existing web URL and do not create or update an MR.
4. If no matching MR exists, obtain the repository `web_url` from `glab repo view --output json`, then URI-encode both branch names when building the web creation link:

```text
https://<host>/<project>/-/merge_requests/new?merge_request[source_branch]=<encoded-source>&merge_request[target_branch]=<encoded-target>
```

5. Prepare, but do not submit, an MR suggestion:
   - title: prefer the current task's commit subject;
   - description: follow `../reference/merge-request/custom.md` and any stricter repository/project format;
   - include only facts supported by the user request, task log, target-to-source commit log, diff summary, and checks actually run;
   - never append Claude attribution lines.

6. The ordinary Push workflow ends after reporting the existing MR or creation link and suggested content. It must not call `glab mr create`, update an MR, assign reviewers, add labels, or alter milestones.

## 6. Error handling

- Stop immediately when a required operation fails and report the concrete reason.
- For a non-fast-forward push rejection, check for collaboration on the source branch and prefer rebase over merge.
- If GitLab CLI is unavailable or the remote is not GitLab, report that the push completed but MR lookup/link preparation was skipped or degraded; do not invent a URL.
