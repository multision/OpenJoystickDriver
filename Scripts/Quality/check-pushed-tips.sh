#!/usr/bin/env bash
set -euo pipefail

zero_oid="$(printf '%040d' 0)"
empty_tree="$(git hash-object -t tree /dev/null)"

while read -r _local_ref local_oid _remote_ref remote_oid; do
  [[ "$local_oid" == "$zero_oid" ]] && continue

  commit="$(git rev-parse --verify "$local_oid^{commit}")" || {
    echo "Cannot validate pushed object $local_oid as a commit." >&2
    exit 1
  }
  base="$empty_tree"
  if [[ "$remote_oid" != "$zero_oid" ]]; then
    base="$(git rev-parse --verify "$remote_oid^{commit}")" || {
      echo "Cannot validate remote object $remote_oid as a commit." >&2
      exit 1
    }
  fi

  git diff --check "$base" "$commit"
done
