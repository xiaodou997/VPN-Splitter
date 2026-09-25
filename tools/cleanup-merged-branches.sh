#!/bin/bash
# SPDX-License-Identifier: MIT
# Remote branch cleanup only. No local reset, branch deletion or worktree removal.
set -euo pipefail
mode=${1:---check}
[[ $# -le 1 && ( $mode == --check || $mode == --delete-merged ) ]] || { echo 'Usage: cleanup-merged-branches.sh [--check|--delete-merged]' >&2; exit 64; }
url=$(git remote get-url origin)
case "$url" in https://github.com/xiaodou997/VPN-Splitter|https://github.com/xiaodou997/VPN-Splitter.git|git@github.com:xiaodou997/VPN-Splitter.git) ;; *) echo 'Unexpected origin; no deletion.' >&2; exit 65;; esac
push_url=$(git remote get-url --push --all origin)
case "$push_url" in https://github.com/xiaodou997/VPN-Splitter|https://github.com/xiaodou997/VPN-Splitter.git|git@github.com:xiaodou997/VPN-Splitter.git) ;; *) echo 'Unexpected or multiple push URLs; no deletion.' >&2; exit 65;; esac
git fetch origin main
for item in 'feat/s0-readonly-baseline:7dca4a3ad4251b7c55448aa4a37a13ad7b6f5aa2' 'feat/s1-policy-core:a591db3f16c69b56101ba2bd5fa07fb71b7f1d17'; do
  branch=${item%%:*}; expected=${item#*:}; ref="refs/heads/$branch"
  result=$(git ls-remote --heads origin "$ref")
  if [[ -z $result ]]; then printf '%s: already absent\n' "$branch"; continue; fi
  read -r head actual_ref <<< "$result"
  [[ $actual_ref == "$ref" && $head == "$expected" ]] || { echo 'Branch changed since review; stop without deleting it.' >&2; exit 65; }
  git fetch origin "$ref"
  git merge-base --is-ancestor "$head" refs/remotes/origin/main || { echo 'Unmerged commits; no deletion.' >&2; exit 65; }
  if [[ $mode == --delete-merged ]]; then
    git push "--force-with-lease=$ref:$head" origin ":$ref"
  else
    printf '%s: merged, exact reviewed head; eligible for --delete-merged\n' "$branch"
  fi
done
