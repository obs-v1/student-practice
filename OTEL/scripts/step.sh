#!/usr/bin/env bash
# step.sh "Human-readable step title" "the shell command to run"
#
# Prints the step the way the documentation describes it, shows the exact command, then
# runs it — UNLESS DRY=1, in which case it only prints (so a student can read every step
# and type the commands by hand). This is what makes `make <section>` and docs/<section>
# say the same thing.
set -uo pipefail
title="$1"; cmd="$2"
printf '\n\033[1;36m▶ %s\033[0m\n' "$title"
printf '\033[2m   $ %s\033[0m\n' "$cmd"
if [ "${DRY:-0}" = "1" ]; then
  printf '\033[2m   (dry-run: not executed — your turn to run it)\033[0m\n'
  exit 0
fi
bash -c "$cmd"
rc=$?
if [ $rc -ne 0 ]; then
  printf '\033[1;31m   ✗ step failed (exit %d)\033[0m\n' "$rc"
  exit $rc
fi
