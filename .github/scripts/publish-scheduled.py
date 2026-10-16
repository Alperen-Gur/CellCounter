"""Publish prebuilt, digest-pinned packages during the approved one-off window."""
import datetime as dt
import hashlib
import json
import os
from pathlib import Path
import re
import subprocess
import tempfile

REPOSITORY = "Alperen-Gur/CellCounter"
BRANCH = "codex/local-diagnostics-release"
NOT_BEFORE = dt.datetime(2026, 10, 17, 6, tzinfo=dt.timezone.utc)
DEADLINE = dt.datetime(2026, 10, 17, 9, tzinfo=dt.timezone.utc)
EXPECTED = {
    "windows-v1.2.1": (False, False, {"CellCounter_1.2.1_x64-setup.exe", "CellCounter_1.2.1_x64_en-US.msi", "SHA256SUMS.txt"}),
    "web-v0.3.1": (True, False, {"CellCounter-Web-v0.3.1.zip", "SHA256SUMS.txt"}),
    "v1.0.17": (False, True, {"CellCounter-v1.0.17.zip", "CellCounter-v1.0.17.zip.sha256"}),
}


def run(*args):
    return subprocess.check_output(args, text=True).strip()


def api(path, payload=None):
    command = ["gh", "api", f"repos/{REPOSITORY}/{path}"]
    if payload is None:
        return json.loads(run(*command))
    return json.loads(subprocess.check_output(command + ["--method", "PATCH", "--input", "-"], input=json.dumps(payload), text=True))


def require(condition, message):
    if not condition:
        raise RuntimeError(message)


def main():
    require(os.environ.get("GITHUB_REPOSITORY") == REPOSITORY, "Unexpected repository")
    check_only = os.environ.get("CHECK_ONLY", "false").lower() == "true"
    now = dt.datetime.now(dt.timezone.utc)
    if not check_only and not (NOT_BEFORE <= now < DEADLINE):
        print("Outside the approved publication window; no push or release publication.")
        return
    plan = json.loads(os.environ["RELEASE_PLAN"])
    sha = plan["sourceSha"]
    require(re.fullmatch(r"[0-9a-f]{40}", sha) is not None, "Invalid pinned source SHA")
    require(set(plan["releases"]) == set(EXPECTED), "Unexpected release set")
    run("git", "fetch", "origin", f"refs/heads/{BRANCH}:refs/remotes/origin/{BRANCH}", "refs/heads/main:refs/remotes/origin/main")
    require(run("git", "rev-parse", f"origin/{BRANCH}") == sha, "Staging branch changed after package preparation")
    ancestor = subprocess.run(["git", "merge-base", "--is-ancestor", "origin/main", sha], check=False)
    require(ancestor.returncode == 0, "main changed independently; refusing to overwrite it")
    # A normal token must never be used to promote unreviewed workflow changes.
    changed_workflows = run("git", "diff", "--name-only", "origin/main", sha, "--", ".github/")
    require(not changed_workflows, "Scheduler configuration differs from the staged source")
    run_id = str(plan["windowsRunId"])
    require(run_id.isdigit(), "Invalid Windows run identity")
    windows = api(f"actions/runs/{run_id}")
    require(windows["conclusion"] == "success" and windows["head_sha"] == sha, "Windows packaging did not succeed for the pinned source")
    jobs = api(f"actions/runs/{run_id}/jobs?per_page=100")["jobs"]
    tests = [step for job in jobs for step in job["steps"] if step["name"].startswith("Test ")]
    require(len(tests) >= 4 and all(step["conclusion"] == "skipped" for step in tests), "Expected packaging-only run with tests skipped")
    releases = api("releases?per_page=100")
    by_tag = {release["tag_name"]: release for release in releases}
    prepared = []
    with tempfile.TemporaryDirectory(prefix="cellcounter-publish-") as directory:
        root = Path(directory)
        # Validate every package before making any release public.
        for tag, (prerelease, latest, names) in EXPECTED.items():
            release = by_tag.get(tag)
            require(release is not None, f"Missing prepared release {tag}")
            require(release["target_commitish"] == sha, f"Wrong source target for {tag}")
            require(release["prerelease"] == prerelease, f"Unexpected preview state for {tag}")
            assets = {asset["name"]: asset for asset in release["assets"]}
            pinned = plan["releases"][tag]
            require(set(assets) == names == set(pinned), f"Unexpected or missing assets for {tag}")
            if not release["draft"]:
                published = dt.datetime.fromisoformat(release["published_at"].replace("Z", "+00:00"))
                require(published >= NOT_BEFORE, f"Release {tag} was published before the approved window")
                require(api(f"commits/{tag}")["sha"] == sha, f"Wrong published tag for {tag}")
            folder = root / tag
            folder.mkdir()
            for name in sorted(names):
                asset, expected = assets[name], pinned[name]
                require(re.fullmatch(r"[0-9a-f]{64}", expected["sha256"]) is not None, "Invalid asset digest")
                require(asset["state"] == "uploaded" and asset["size"] == expected["size"], f"Unfinished or wrong-sized asset {name}")
                require(asset.get("digest") == "sha256:" + expected["sha256"], f"Asset metadata changed: {name}")
                destination = folder / name
                with destination.open("wb") as stream:
                    subprocess.run(["gh", "api", f"repos/{REPOSITORY}/releases/assets/{asset['id']}", "-H", "Accept: application/octet-stream"], stdout=stream, check=True)
                with destination.open("rb") as stream:
                    digest = hashlib.file_digest(stream, "sha256").hexdigest()
                require(digest == expected["sha256"] and destination.stat().st_size == expected["size"], f"Downloaded asset failed integrity check: {name}")
            print(f"Verified {tag}: pinned source and {len(names)} package assets")
            prepared.append((tag, release, latest))
        if check_only:
            print("Readiness check passed. No source push, tag creation or release publication was performed.")
            return
        run("git", "push", "origin", f"{sha}:refs/heads/main")
        require(api("git/ref/heads/main")["object"]["sha"] == sha, "main promotion was not confirmed")
        for tag, release, latest in prepared:
            if release["draft"]:
                updated = api(f"releases/{release['id']}", {"draft": False, "make_latest": "true" if latest else "false"})
                require(not updated["draft"], f"Publication failed for {tag}")
            require(api(f"commits/{tag}")["sha"] == sha, f"Wrong published tag for {tag}")
            print(f"Published {tag}")
    # Stop this one-off schedule after all releases have been confirmed public.
    subprocess.run(["gh", "api", "--method", "PUT", f"repos/{REPOSITORY}/actions/workflows/scheduled-release.yml/disable"], check=True)
    print("All releases published; the one-off workflow is now disabled.")


if __name__ == "__main__":
    main()
