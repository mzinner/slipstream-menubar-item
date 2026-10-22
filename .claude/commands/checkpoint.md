---
description: Save a compressed summary of this session so a future session can resume. Usage: /checkpoint
---

# Checkpoint Command

**A checkpoint is an update, not a regeneration.** Where a context file already exists, edit the parts this session changed and leave the rest alone: its structure, its section order and its wording are the record of earlier sessions, and rewriting them from the template below loses what those sessions knew. Only a project with no context file at all gets the template.

## A. `.claude/context/` exists — split layout

`.claude/PROJECT_CONTEXT.md` is the index: the description, the top-level layout table, a table of the context files with what is in each, and whatever cross-cutting sections it carries.

1. Read the index first. It tells you which context file covers which area.
2. Read only the context files this session's work touched — that is the point of the split, so do not read the whole set to write a checkpoint.
3. Update those files in place. A fact belongs in the file whose area it is about; put it there rather than in the index.
4. Update the index only when the split itself changed: a new context file, a file whose coverage moved, a change to the description, the layout table or a cross-cutting section. Keep the index's own table in step with the files.
5. If a context file has grown past roughly 400 lines and has a clean seam in it, split it further, add the new file to the index table, and say so when you report back.

## B. `.claude/PROJECT_CONTEXT.md` exists, with no `context/` — single file

1. Read it, and update it in place, following the structure it already has rather than the template below.
2. If it is longer than roughly 400 lines, split it as you write the checkpoint: keep `PROJECT_CONTEXT.md` as the index described in A (description, layout, a table of context files, cross-cutting sections such as known gaps and conventions), and move each area into `.claude/context/<area>.md`. Carry the prose over verbatim — promote heading levels and add each file's title and a link back to `../PROJECT_CONTEXT.md`, but do not reword content while moving it. Verify nothing was lost before finishing, then report the new file list.
3. Do not split a file that is comfortably under that size. A small project is easier to read in one place.

## C. Neither exists — new project

Create `.claude/PROJECT_CONTEXT.md` with a compressed summary structured as:

### Project

One-paragraph description of what this project is and its goal.

### Architecture / key decisions

Bullet list of non-obvious design choices and why.

### Current state

- What's implemented and working
- What's in progress
- What's broken/known issues

### Files that matter

Path -> one-line purpose, for files central to this work.

### Next steps

Concrete, ordered list of what to do next.

### Gotchas / things not to repeat

Dead ends already tried and why they failed.

(Those are top-level `##` headings in the file itself.)

## In every case

- Keep it dense — favour bullet points over prose, and omit anything derivable by reading the code.
- **Write only what stays true.** The context is read by sessions weeks later, so it holds knowledge, not status:
  - No PR or branch state: open, merged, in review, "assumes PR #N is merged", "waiting for X to land", review-thread status. That lives in GitHub and goes stale the day it changes. A PR number is fine as a permanent reference to where a change and its discussion live ("the review of #59 found …"), and so is a commit hash. Branch names are not: branches are deleted after the merge. Describe the feature or fix itself (by file, function or behaviour).
  - No session history: no "added on <date>", "renamed on <date>", "fixed in round 2", "(was X)", test counts or "all passing on <date>". State the current design and behaviour in the present tense. Keep a date only when it is the fact itself (a deadline, the release a behaviour depends on).
  - No version or state of the day ("the current version is …", "the local build is …"): name where to look instead (`gh release list`, `bld/bin/mariadb-shell --version`).
  - No paths or details of one developer's machine (home directories, `~/Downloads`, local server installs, sandbox ports, VM addresses, personal config files). Use repository-relative paths; for something outside the repository, say what it is (for example "the `bin` directory of a MariaDB server"), not where it lives on one machine. Paths the product itself defines (`~/.mariadb-shell`, `~/.mylogin.cnf`) are fine.
  - Next steps are work still to do, not PRs to review or merge.
- **Updating means deleting too.** When this session made a fact false — something fixed, merged, removed, renamed, decided — delete or rewrite it where it stands; never append a correction or a history line next to it. Check the parts of the touched files that this session's work affects for such facts.
- Do not record git status or the current branch in a "Git state" section or anywhere else: they change with every command.
- Confirm back to the user every path you wrote to, and say which files you left untouched.
