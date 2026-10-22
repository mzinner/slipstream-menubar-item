---
description: Reads the compressed summary that /checkpoint saved, plus the open PRs and dangling branches, so this session can resume. Usage: /read-checkpoint
---

# Read Checkpoint Command

Read `.claude/PROJECT_CONTEXT.md` at the repository root to resume where the last session stopped.

## A. `.claude/context/` exists — split layout

`.claude/PROJECT_CONTEXT.md` is the index: the description, the top-level layout table, a table of the context files with what is in each, and whatever cross-cutting sections it carries.

1. Read the index first. It tells you which context file covers which area.
2. Read only the context files for the area the user wants to work on — that is the point of the split, so do not read the whole set. If the user has not said yet, read the index alone and ask.

## B. `.claude/PROJECT_CONTEXT.md` exists, with no `context/` — single file

Read it; it holds the whole context.

## C. Neither exists

Say that `.claude/PROJECT_CONTEXT.md` does not exist and that `/checkpoint` creates it.

## D. Open PRs — the live state the context leaves out

`/checkpoint` records no PR or branch state, because it goes stale. Read it live instead, in every case above (and the branches without a PR in E):

1. List the open PRs:
   `gh pr list --state open --json number,title,headRefName,author,isDraft,reviewDecision,statusCheckRollup`
   If `gh` fails (no network, not authenticated), say so and carry on without them.
2. For each one, keep in mind for this session: number, title, branch, author, draft or not, review decision, and whether its checks pass.
3. Note which PR, if any, is for the branch checked out now (`git branch --show-current`).
4. Check which PRs change `.claude/` (`gh pr view <N> --json files`). Their branches carry context that is not on `main` yet: say so, and read those changes too when they cover the area the user wants to work on.
5. Connect a PR to the context where it obviously matches (the same feature, files or area), so the user can see which work is in flight.

Keep this in the conversation only. Never write it into `.claude/`.

## E. Dangling branches — work with no open PR

Branches that carry work but have no open PR are not in D, and the context does not record them either. Find them live:

1. Run `git fetch --prune github` and `git fetch --prune origin` so deleted remote branches drop out. This repo has two remotes: `github` is GitHub, where the PRs live, and `origin` is the NAS mirror; every branch is normally pushed to both. Look at local branches, `github/*` and `origin/*`, and take the union by branch name.
2. List every PR by branch: `gh pr list --state all --limit 1000 --json number,state,headRefName,headRefOid`. If `gh` fails, say so and list the branches below without their PR status.
3. PRs here are merged by fast-forwarding `main` to the PR branch, so a merged branch's commits are on `main` unchanged. `git merge-base --is-ancestor <branch> main` (exit 0) therefore settles that a branch's work is on `main`, whether it came through a PR or a direct push.
4. Match each branch except `main` to the PRs by branch name, and sort it. Releases are triggered by tags, so there is no release branch to leave out.
   - **Open PR**: already reported in D; skip it here.
   - **On `main`**: the tip is an ancestor of `main` (step 3). Not dangling, but a candidate for deletion; name its PR if it has one.
   - **Done**: its PR is merged or closed and the branch tip equals that PR's `headRefOid`. Not dangling, but a candidate for deletion.
   - **Work after merge**: its PR is merged or closed and `git rev-list --count <headRefOid>..<branch>` is above 0. Dangling.
   - **Can't compare**: its PR is merged or closed but `headRefOid` is not in the local repository (the branch was rebased or force-pushed before the merge). Say so; do not guess.
   - **No PR**: no PR has ever had this branch name. Dangling.
5. A branch name is not proof. Work often moves to a new branch and is merged from there, so before reporting a branch as no PR or work after merge, look its commits up by hash, not by name: `gh api repos/{owner}/{repo}/commits/<branch tip sha>/pulls --jq '.[]|"\(.number) \(.state) \(.merged_at) \(.head.ref)"'` lists every PR that contains the tip, whatever its branch was called. If a merged PR contains the tip, the branch is **contained in PR #N**: not dangling, but a candidate for deletion, like done. For work after merge, check the tip, not `headRefOid`. If the call fails, say the branch was matched by name only.
6. Report the dangling ones (work after merge, and no PR) that are pushed to `github` or `origin` or have a commit in the last 30 days, one line each: branch, where it is (local, `github`, `origin`), commits ahead of `main` (`git rev-list --count main..<branch>`), date and author of the last commit (`git log -1 --format='%cs %an' <branch>`), and the PR number for work after merge. Sum up the others in one line ("N older local branches, M branches on `main` or done that can be deleted").
7. Connect a dangling branch to the context where it obviously matches, as in D.
8. Report only what these commands show. A branch that is not on `main` may still be superseded by work merged from another branch, and a `git diff --stat` against `main` does not show whether it is, so neither supports a guess like "probably superseded". When the commands do not settle a branch, say which check is missing.

Keep this in the conversation only. Never write it into `.claude/`, and never delete a branch unless the user asks.

## In every case

- The context describes the project as it was when written. Before acting on a fact that names a file, function, option or behaviour, check it still holds in the code.
- Report back in a few lines: what the context covers, which files you read, the open PRs (one line each, the checked-out branch's PR first), and the dangling branches.
