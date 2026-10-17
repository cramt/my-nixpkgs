#!/usr/bin/env bash
# Commits each bump that built on at least one system and failed on none, one
# commit per package. The others stay out until a later run gets them green.
set -euo pipefail

bumps=$1
results=$2

# A verify leg that died before writing anything would otherwise read as "no
# objections" and let a bump through on the other system's word alone.
for system in x86_64-linux aarch64-linux; do
  if [ ! -s "$results/$system" ]; then
    echo "::error::no verify results for $system, committing nothing"
    exit 1
  fi
done

for patch in "$bumps"/*.patch; do
  [ -e "$patch" ] || continue
  name=$(basename "$patch" .patch)
  verdicts=$(cat "$results"/* | awk -v n="$name" '$1 == n { print $2 }')
  if grep -qx fail <<<"$verdicts" || ! grep -qx ok <<<"$verdicts"; then
    echo "holding back $name: $(tr '\n' ' ' <<<"$verdicts")"
    continue
  fi
  git apply "$patch"
  git commit -qam "$(cat "$bumps/$name.msg")"
  git log --oneline -1
done
