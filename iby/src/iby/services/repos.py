"""Clone / fast-forward the four app repos. Port of dev.sh clone_* / pull_*.

`up` clones MISSING repos only (never touches existing checkouts, so local edits
survive); `pull` fast-forwards clean checkouts and skips dirty ones. frontend
carries the `harbor` submodule (cloned/updated recursively).
"""

from __future__ import annotations

from pathlib import Path

from ..core.context import AppContext
from ..core.errors import IbyError

REPOS = ("backend", "frontend", "infinization", "infiniservice")
GH_ORG = "Infinibay"


def _has_gh(ctx: AppContext) -> bool:
    from ..runtime.detect import has

    return has("gh")


def clone_one(ctx: AppContext, name: str) -> None:
    dest = ctx.repos_dir / name
    if (dest / ".git").is_dir():
        return
    ctx.repos_dir.mkdir(parents=True, exist_ok=True)
    ref = ctx.repo_ref
    ctx.console.info(f"cloning {name} (ref: {ref})…")
    recurse = name == "frontend"
    if _has_gh(ctx):
        args = ["gh", "repo", "clone", f"{GH_ORG}/{name}", str(dest)]
        if recurse:
            args += ["--", "--recurse-submodules"]
        ctx.runner.run(args, error=f"gh clone of {name} failed")
    else:
        url = f"https://github.com/{GH_ORG}/{name}.git"
        args = ["git", "clone"]
        if recurse:
            args.append("--recurse-submodules")
        args += [url, str(dest)]
        ctx.runner.run(args, error=f"git clone of {name} failed (private repo? authenticate gh or git first)")
    if not ctx.runner.succeeds(["git", "-C", str(dest), "checkout", ref]):
        ctx.console.warn(f"{name}: could not checkout {ref} (using default branch)")
    if recurse:
        ctx.console.info("initialising harbor submodule (pinned)…")
        if not ctx.runner.succeeds(["git", "-C", str(dest), "submodule", "update", "--init", "--recursive"]):
            ctx.console.warn("harbor submodule init failed — frontend build will break until fixed")


def clone_all(ctx: AppContext) -> None:
    for name in REPOS:
        clone_one(ctx, name)


def pull_one(ctx: AppContext, name: str) -> None:
    dest = ctx.repos_dir / name
    if not (dest / ".git").is_dir():
        clone_one(ctx, name)
        return
    if ctx.runner.capture(["git", "-C", str(dest), "status", "--porcelain"]):
        ctx.console.warn(f"{name} has local changes — skipping pull (commit/stash to update).")
        return
    ref = ctx.repo_ref
    ctx.console.info(f"updating {name} → origin/{ref}…")
    if not ctx.runner.succeeds(["git", "-C", str(dest), "fetch", "origin", ref, "--tags", "--quiet"]):
        ctx.console.warn(f"{name} fetch failed")
        return
    ctx.runner.succeeds(["git", "-C", str(dest), "checkout", ref, "--quiet"])
    if not ctx.runner.succeeds(["git", "-C", str(dest), "merge", "--ff-only", f"origin/{ref}", "--quiet"]):
        ctx.console.warn(f"{name} not fast-forwardable — resolve manually")
    if name == "frontend":
        if not ctx.runner.succeeds(
            ["git", "-C", str(dest), "submodule", "update", "--init", "--recursive", "--quiet"]
        ):
            ctx.console.warn("harbor submodule update failed")


def pull_all(ctx: AppContext) -> None:
    for name in REPOS:
        pull_one(ctx, name)


def repo_rows(ctx: AppContext) -> list[tuple[str, str, str, str]]:
    """Per-repo (name, ref, state, path) for `iby repos status | list`."""
    rows: list[tuple[str, str, str, str]] = []
    for name in REPOS:
        dest = ctx.repos_dir / name
        if not (dest / ".git").is_dir():
            rows.append((name, "—", "missing", str(dest)))
            continue
        ref = ctx.runner.capture(["git", "-C", str(dest), "rev-parse", "--abbrev-ref", "HEAD"]) or "?"
        state = "dirty" if ctx.runner.capture(["git", "-C", str(dest), "status", "--porcelain"]) else "clean"
        rows.append((name, ref, state, str(dest)))
    return rows
