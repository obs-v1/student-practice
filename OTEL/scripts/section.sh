#!/usr/bin/env bash
# section.sh "N" "Section title" "one-line intent"
# Prints a section banner so the Makefile output reads like the chapters of the doc.
set -uo pipefail
num="$1"; title="$2"; intent="${3:-}"
printf '\n\033[1;33m═══════════════════════════════════════════════════════════════\033[0m\n'
printf '\033[1;33m  SECTION %s — %s\033[0m\n' "$num" "$title"
[ -n "$intent" ] && printf '\033[33m  %s\033[0m\n' "$intent"
printf '\033[1;33m═══════════════════════════════════════════════════════════════\033[0m\n'
if [ "${DRY:-0}" = "1" ]; then printf '\033[2m  (DRY=1 — printing steps only, nothing is applied)\033[0m\n'; fi
exit 0
