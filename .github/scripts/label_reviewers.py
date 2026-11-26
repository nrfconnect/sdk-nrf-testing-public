#!/usr/bin/env python3
#
# Copyright (c) 2026 Nordic Semiconductor ASA
#
# SPDX-License-Identifier: LicenseRef-Nordic-5-Clause

"""Request pull request reviews based on the label that was just added.

Reads a YAML map of label -> list of reviewers (users or "org/team" teams) and
asks GitHub, through the gh CLI, to request a review from them.

Inputs are taken from the environment: PR_NUMBER, PR_AUTHOR, LABEL and
GITHUB_REPOSITORY. gh also needs GH_TOKEN.
"""

import argparse
import os
import subprocess
import sys

import yaml


def split_reviewers(entries, author):
    """Split map entries into (users, team slugs), leaving out the PR author."""
    users = []
    teams = []
    for entry in entries:
        if "/" in entry:
            slug = entry.split("/", 1)[1]
            if slug not in teams:
                teams.append(slug)
        elif entry.lower() != author.lower() and entry not in users:
            users.append(entry)
    return users, teams


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--map", required=True, help="YAML file mapping labels to reviewers")
    parser.add_argument("--dry-run", action="store_true", help="print the gh command instead of running it")
    args = parser.parse_args()

    label = os.environ["LABEL"]
    author = os.environ["PR_AUTHOR"]
    pr_number = os.environ["PR_NUMBER"]
    repo = os.environ["GITHUB_REPOSITORY"]

    try:
        with open(args.map) as f:
            reviewers_by_label = yaml.safe_load(f) or {}
    except FileNotFoundError:
        print(f"Warning: {args.map} not found, nothing to do")
        return 0

    users, teams = split_reviewers(reviewers_by_label.get(label) or [], author)
    if not users and not teams:
        print(f"No reviewers to request for label '{label}'")
        return 0

    cmd = ["gh", "api", "--method", "POST", f"repos/{repo}/pulls/{pr_number}/requested_reviewers"]
    for user in users:
        cmd += ["-f", f"reviewers[]={user}"]
    for team in teams:
        cmd += ["-f", f"team_reviewers[]={team}"]

    print(f"Label '{label}': requesting users {users}, teams {teams}")
    if args.dry_run:
        print(" ".join(cmd))
        return 0

    result = subprocess.run(cmd, capture_output=True, text=True)
    if result.returncode != 0:
        # A stale user or team in the map should not fail the pull request.
        print(f"Warning: review request failed: {result.stderr.strip()}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
