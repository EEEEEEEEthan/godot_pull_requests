# Pull Requests

A **Godot 4.8** editor plugin that lists open GitHub Pull Requests in a left-bottom dock, lets you open them in the browser, and (optionally) check out a PR head with a destructive hard reset/clean.

## Features

- **List open PRs** — Shows open Pull Requests in an **EditorDock** slotted at the left-bottom (`DOCK_SLOT_LEFT_BR`).
- **Open in browser** — One click opens the PR URL via `OS.shell_open`.
- **Branch switcher (top MenuButton)** — Shows the current branch (or a clear detached-HEAD label). The popup lists every local and remote branch from current refs (`git for-each-ref`), nested by source (`本地` / each remote) and by `/` path segments. Choosing a leaf asks for the same destructive confirmation as PR checkout. Menus are rebuilt on `about_to_popup` from local refs only (no `fetch --all`); a remote target is fetched when you confirm.
- **Checkout PR head** — After confirmation, fetches `pull/<n>/head`, runs `git reset --hard` + `git clean -fd`, then `git checkout -B <branch> FETCH_HEAD` (works for fork / cross-repo PRs). **Destructive:** discards uncommitted and untracked local changes.

## Requirements

- Godot **4.8+** (uses the `EditorDock` API)
- `gh` (GitHub CLI) and `git` available in `PATH`
- A GitHub remote named `origin` on the project (owner/repo is parsed from the remote URL)

## Installation

### As a Git submodule (recommended)

Once the standalone repository is published:

```bash
git submodule add https://github.com/EEEEEEEEthan/godot_pull_requests.git addons/godot_pull_requests
```

Until that repository exists, you can use this addon’s transitional history from the Fire Emblem Gaiden game repo (`addon/godot_pull_requests` branch on `https://github.com/EEEEEEEEthan/FireEmblemGaiden.git`) as the submodule source.

### Or copy the folder

1. Copy this folder into your project as:

   `res://addons/godot_pull_requests`

2. Open **Project → Project Settings → Plugins**, enable **Pull Requests**.

## Usage

1. Open the **Pull Requests** dock (left-bottom by default).
2. The top dropdown shows the current branch; open it to pick any local/remote branch (nested menus). Confirm to hard-reset/clean and check out.
3. Use **Refresh** to reload the open PR list (`gh pr list`) and refresh the current-branch label.
4. **Open in browser** opens the selected PR on GitHub.
5. **Switch to this branch** asks for confirmation, then aligns the local branch to that PR’s latest head.

**Warning:** switching branches (dropdown or PR) is destructive — it hard-resets and cleans the working tree before checkout. Commit or stash anything you care about first.

## How it works (brief)

- The plugin registers an `EditorDock` and builds a small UI panel that shells out to `gh` / `git` (no shell; `OS.execute` with argv).
- `gh` is always invoked with `-R owner/repo` resolved from `git remote get-url origin`.
- Branch listing uses `git for-each-ref` on `refs/heads/` and `refs/remotes/` (skips `*/HEAD`). Local checkouts: `reset --hard` → `clean -fd` → `checkout <branch>`. Remote checkouts: `fetch <remote> <branch>` → same clean → `checkout -B <branch> FETCH_HEAD` (same tip alignment as PR checkout).
- PR checkout uses GitHub’s `pull/<number>/head` ref so fork PRs work without adding extra remotes. Both paths share one pending-checkout / confirm flow.

## License

Add a `LICENSE` file in this repository if you distribute the addon; none is included by default.
