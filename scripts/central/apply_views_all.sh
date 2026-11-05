#!/usr/bin/env bash
# MULTI-SOURCE mode: create or refresh the sailpoint views on every cluster in
# config/sources.conf (or only the codes given as arguments), using scripts/apply_views.sh.
#
#   apply_views_all.sh              all clusters
#   apply_views_all.sh PRD01 UAT01  only these
#
# Run it after the one-time setup of a new cluster, and whenever a file in sql/views changes.
# Each cluster is updated in its own transaction; a failure on one does not affect the others.
# Exit code: 0 = all updated, 1 = at least one cluster failed.
set -uo pipefail
LOG_NAME="apply_views_all"
# shellcheck source=lib.sh
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"
load_sources

declare -A WANT=()
for a in "$@"; do WANT[$a]=1; done

FAILED=0; DONE=0
for i in "${!SRC_CODE[@]}"; do
    code="${SRC_CODE[$i]}"
    [ $# -eq 0 ] || [ -n "${WANT[$code]:-}" ] || continue
    env_file="$(mktemp)"
    printf 'PGHOST=%q\nPGPORT=%q\nPGDATABASE=%q\nPGUSER=%q\n' \
        "${SRC_HOST[$i]}" "${SRC_PORT[$i]}" "${SRC_DB[$i]}" "${SRC_USER[$i]}" > "$env_file"
    log "$code: applying views"
    if FEEDS_ENV="$env_file" "$REPO_DIR/scripts/apply_views.sh" | sed "s/^/  [$code] /"; then
        DONE=$((DONE + 1))
    else
        log "ERROR: $code: views not applied"; FAILED=$((FAILED + 1))
    fi
    rm -f "$env_file"
done

log "done: $DONE updated, $FAILED failed"
[ "$FAILED" -eq 0 ]
