#!/usr/bin/env python3
"""Upstream monitor: polls our notification issues (GitHub REST API -
the public Atom feeds were removed), forum topics (NodeBB JSON API) and
upstream latest-release tags (vs packages/mirrors.json), and prints one
report line per new activity since the last run.

State lives in .github/monitor-state.json (committed by the workflow).
First run baselines everything silently. DRY_RUN=1 prints the report but
does not write state; ACT=1 additionally posts the report to the
LOG_ISSUE issue via gh.
"""
import json
import os
import re
import subprocess
import sys
import urllib.request

STATE_FILE = os.environ.get("STATE_FILE", ".github/monitor-state.json")
WATCH_FILE = os.environ.get("WATCH_FILE", ".github/upstream-watch.json")
MIRRORS_FILE = os.environ.get("MIRRORS_FILE", "packages/mirrors.json")
DRY_RUN = os.environ.get("DRY_RUN", "0") == "1"
ACT = os.environ.get("ACT", "0") == "1"
LOG_REPO = os.environ.get("LOG_REPO", "")
LOG_ISSUE = os.environ.get("LOG_ISSUE", "")
GH_TOKEN = os.environ.get("GH_TOKEN", "")


def fetch(url, token=None, api=False):
    headers = {"User-Agent": "pfsense-community-monitor"}
    if api:
        headers["Accept"] = "application/vnd.github+json"
    if token:
        headers["Authorization"] = "Bearer " + token
    req = urllib.request.Request(url, headers=headers)
    with urllib.request.urlopen(req, timeout=30) as r:
        return r.read().decode("utf-8", "replace")


def load_state():
    if os.path.exists(STATE_FILE):
        with open(STATE_FILE) as f:
            return json.load(f)
    return {"issues": {}, "forum": {}, "releases": {}}


def save_state(state):
    os.makedirs(os.path.dirname(STATE_FILE), exist_ok=True)
    with open(STATE_FILE, "w") as f:
        json.dump(state, f, indent=2, sort_keys=True)
        f.write("\n")


def report_issues(state, out):
    """GitHub removed the public issue Atom feeds (406), so poll the REST
    API: comment count + issue state per watched issue."""
    for url in watch.get("issues", []):
        m = re.match(r"https://github\.com/([^/]+)/([^/]+)/issues/(\d+)$", url)
        if not m:
            continue
        owner, repo, num = m.group(1), m.group(2), m.group(3)
        try:
            issue = json.loads(fetch("https://api.github.com/repos/%s/%s/issues/%s"
                                      % (owner, repo, num), GH_TOKEN, api=True))
            comments = json.loads(fetch(
                "https://api.github.com/repos/%s/%s/issues/%s/comments?per_page=100"
                % (owner, repo, num), GH_TOKEN, api=True))
            count = len(comments)
            issue_state = issue.get("state", "")
            where = "%s/%s#%s" % (owner, repo, num)
            last = state["issues"].get(url)
            if isinstance(last, dict):
                if count > last.get("comments", 0):
                    author = ((comments[-1].get("user") or {}).get("login", "someone")
                              if comments else "someone")
                    out.append("**[%s]** %d new comment(s), last by **%s** — %s"
                               % (where, count - last.get("comments", 0), author, url))
                if issue_state and issue_state != last.get("state"):
                    out.append("**[%s]** issue is now **%s** — %s" % (where, issue_state, url))
            state["issues"][url] = {"comments": count, "state": issue_state}
        except Exception as exc:
            print("warn: issue %s: %s" % (url, exc), file=sys.stderr)


def report_forum(state, out):
    """NodeBB topics: the .rss feed carries no items, but the JSON API
    (https://forum.netgate.com/api/topic/<id>) gives postcount + posts."""
    for url in watch.get("forum", []):
        m = re.search(r"/topic/(\d+)", url)
        if not m:
            continue
        api_url = "https://forum.netgate.com/api/topic/" + m.group(1)
        try:
            data = json.loads(fetch(api_url))
            count = data.get("postcount", 0)
            users = []
            for p in data.get("posts", []):
                u = (p.get("user") or {}).get("username")
                if u:
                    users.append(u)
            last = state["forum"].get(url)
            if last is not None and count > last:
                out.append("**[forum topic %s]** %d new post(s) (total %d, last by %s) — %s"
                           % (m.group(1), count - last, count,
                              users[-1] if users else "unknown", url))
            state["forum"][url] = count
        except Exception as exc:
            print("warn: forum topic %s: %s" % (m.group(1), exc), file=sys.stderr)


def report_releases(state, out):
    repos = set()
    for p in mirrors.get("packages", []):
        m = re.match(r"https://github\.com/([^/]+/[^/]+)", p.get("upstream", ""))
        if m:
            repos.add(m.group(1))
    for repo in sorted(repos):
        try:
            tag = json.loads(fetch("https://api.github.com/repos/%s/releases/latest"
                                   % repo, GH_TOKEN, api=True)).get("tag_name")
            if not tag:
                continue
            last = state["releases"].get(repo)
            if last and tag != last:
                out.append("**[%s]** new release **%s** (was %s) — check the pinned asset in packages/mirrors.json"
                           % (repo, tag, last))
            state["releases"][repo] = tag
        except Exception as exc:
            print("warn: releases %s: %s" % (repo, exc), file=sys.stderr)


with open(WATCH_FILE) as f:
    watch = json.load(f)
with open(MIRRORS_FILE) as f:
    mirrors = json.load(f)

state = load_state()
out = []
report_issues(state, out)
report_forum(state, out)
report_releases(state, out)

if out:
    print("=== Upstream activity report")
    for line in out:
        print(line)
else:
    print("No new upstream activity.")

if DRY_RUN:
    print("(dry run: state not updated)")
    sys.exit(0)

save_state(state)

if ACT and out and LOG_REPO and LOG_ISSUE:
    body = "Upstream activity report:\n\n" + "\n".join("- " + l for l in out)
    subprocess.run(["gh", "issue", "comment", LOG_ISSUE, "--repo", LOG_REPO, "--body", body],
                   check=True)
