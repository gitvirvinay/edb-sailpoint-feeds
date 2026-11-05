#!/usr/bin/env bash
# Look up a list of logins in Active Directory (multi-source mode).
#
#   ad_lookup.sh <logins-file>  >  ad_users.csv
#
# <logins-file>: one lower-case login per line (from all clusters, duplicates removed).
# Output (CSV, no header), one row per login found in AD:
#   login, is_npid (t/f), first_name, last_name, owner, cost_centre
# Logins not found in AD (e.g. local database accounts) produce no row.
#
# Two searches per batch of logins:
#   1. AD_BASE: the attributes named in central.env (first/last name, owner, cost centre)
#   2. NPID_SEARCH_BASE + NPID_FILTER: which of those logins are non-person accounts
# Values AD returns base64-encoded (accented names, e.g. "Hélène") are decoded.
# An owner given as a DN ("CN=Tremblay\, Marc,OU=...") is reduced to its CN ("Tremblay, Marc").
#
# Exits non-zero if AD cannot be reached or the bind fails; then no output should be used.
set -euo pipefail
LOG_NAME="ad_lookup"
# shellcheck source=lib.sh
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"

LOGINS_FILE="${1:-}"
[ -r "$LOGINS_FILE" ] || die "usage: ad_lookup.sh <logins-file>"
for v in LDAP_URI BIND_DN BIND_PW_FILE AD_BASE NPID_SEARCH_BASE NPID_FILTER; do
    [ -n "${!v:-}" ] || die "$v is not set in $CENTRAL_ENV"
done
[ -r "$BIND_PW_FILE" ] || die "AD bind password file not readable: $BIND_PW_FILE"

# Attribute name (lower-case, as matched in LDIF) for each output column; empty = not used.
A_FIRST="$(tr 'A-Z' 'a-z' <<< "${AD_ATTR_FIRST_NAME:-}")"
A_LAST="$(tr 'A-Z' 'a-z' <<< "${AD_ATTR_LAST_NAME:-}")"
A_OWNER="$(tr 'A-Z' 'a-z' <<< "${AD_ATTR_OWNER:-}")"
A_COST="$(tr 'A-Z' 'a-z' <<< "${AD_ATTR_COST_CENTRE:-}")"
ATTRS=(sAMAccountName)
for a in "${AD_ATTR_FIRST_NAME:-}" "${AD_ATTR_LAST_NAME:-}" "${AD_ATTR_OWNER:-}" "${AD_ATTR_COST_CENTRE:-}"; do
    [ -n "$a" ] && ATTRS+=("$a")
done

ldap() {   # ldap <base> <filter> <attributes...>
    local base="$1" filter="$2"; shift 2
    ldapsearch -LLL -o ldif-wrap=no -E pr=1000/noprompt \
        -H "$LDAP_URI" -D "$BIND_DN" -y "$BIND_PW_FILE" -b "$base" "$filter" "$@"
}

# CSV field: empty -> unquoted (loads as NULL); otherwise quoted, quotes doubled,
# line breaks removed.
csv() {
    local v="${1//$'\r'/}"; v="${v//$'\n'/ }"
    if [ -z "$v" ]; then printf ''; else printf '"%s"' "${v//\"/\"\"}"; fi
}

# DN -> its first RDN value: "CN=Tremblay\, Marc,OU=x" -> "Tremblay, Marc"
dn_to_name() {
    sed -E -e 's/^[A-Za-z]+=((\\.|[^,])*).*$/\1/' -e 's/\\(.)/\1/g' <<< "$1"
}

# Turn LDIF on stdin into lines: login, first, last, owner, cost separated by the ASCII
# unit separator (\x1f). Not a tab: bash would merge consecutive tabs and shift empty fields.
parse_ldif() {
    local line attr val login="" first="" last="" owner="" cost=""
    emit() {
        if [ -n "$login" ]; then
            printf '%s\x1f%s\x1f%s\x1f%s\x1f%s\n' "$login" "$first" "$last" "$owner" "$cost"
        fi
        login=""; first=""; last=""; owner=""; cost=""
    }
    while IFS= read -r line || [ -n "$line" ]; do
        line="${line%$'\r'}"
        if [ -z "$line" ]; then emit; continue; fi
        [[ "$line" == *:* ]] || continue
        attr="${line%%:*}"; attr="$(tr 'A-Z' 'a-z' <<< "$attr")"
        val="${line#*:}"
        if [[ "$val" == :* ]]; then                      # "attr:: base64"
            val="$(printf '%s' "${val#:}" | tr -d ' ' | base64 -d 2>/dev/null || true)"
        else
            val="${val# }"
        fi
        val="${val//$'\x1f'/ }"
        case "$attr" in
            samaccountname)  login="$(tr 'A-Z' 'a-z' <<< "$val")" ;;
        esac
        [ -n "$A_FIRST" ] && [ "$attr" = "$A_FIRST" ] && first="$val"
        [ -n "$A_LAST"  ] && [ "$attr" = "$A_LAST"  ] && last="$val"
        [ -n "$A_OWNER" ] && [ "$attr" = "$A_OWNER" ] && \
            { if [[ "$val" == *=* ]]; then owner="$(dn_to_name "$val")"; else owner="$val"; fi; }
        [ -n "$A_COST"  ] && [ "$attr" = "$A_COST"  ] && cost="$val"
    done
    emit
}

ATTR_OUT="$(mktemp)"; NPID_OUT="$(mktemp)"
trap 'rm -f "$ATTR_OUT" "$NPID_OUT"' EXIT

mapfile -t NAMES < <(grep -v '^[[:space:]]*$' "$LOGINS_FILE" | sort -u | ldap_escape)
for ((i = 0; i < ${#NAMES[@]}; i += AD_BATCH)); do
    NAME_FILTER=""
    for n in "${NAMES[@]:i:AD_BATCH}"; do NAME_FILTER+="(sAMAccountName=$n)"; done
    ldap "$AD_BASE" "(&(objectClass=user)(|$NAME_FILTER))" "${ATTRS[@]}" | parse_ldif >> "$ATTR_OUT"
    ldap "$NPID_SEARCH_BASE" "(&$NPID_FILTER(|$NAME_FILTER))" sAMAccountName \
        | parse_ldif | cut -d $'\x1f' -f1 >> "$NPID_OUT"
done

sort -u -o "$NPID_OUT" "$NPID_OUT"
declare -A NPID=()
while IFS= read -r n; do [ -n "$n" ] && NPID[$n]=1; done < "$NPID_OUT"

# One row per login (first entry wins if AD returned duplicates).
declare -A DONE=()
while IFS=$'\x1f' read -r login first last owner cost; do
    [ -n "$login" ] && [ -z "${DONE[$login]:-}" ] || continue
    DONE[$login]=1
    printf '%s,%s,%s,%s,%s,%s\n' "$(csv "$login")" "$( [ -n "${NPID[$login]:-}" ] && echo t || echo f )" \
        "$(csv "$first")" "$(csv "$last")" "$(csv "$owner")" "$(csv "$cost")"
done < "$ATTR_OUT"

# An NPID found by the second search but missing from the first (outside AD_BASE).
for n in "${!NPID[@]}"; do
    [ -n "${DONE[$n]:-}" ] || printf '%s,t,,,,\n' "$(csv "$n")"
done

log "looked up ${#NAMES[@]} logins: $(wc -l < "$ATTR_OUT") found in AD, ${#NPID[@]} non-person" >&2
