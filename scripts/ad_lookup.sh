#!/usr/bin/env bash
# Look up logins in ONE AD profile (one AD server + branch + bind account), exactly the way
# Postgres finds them when they log in. Called by collect_all.sh once per distinct profile.
#
#   ad_lookup.sh <profile-file> <logins-file>  >  results.csv
#
# <profile-file>: one line, fields separated by the ASCII unit separator (\x1f), taken from a
#   pg_hba.conf LDAP line: server, port, scheme, tls, basedn, binddn, bindpasswd,
#   searchattribute, searchfilter. It holds a password: collect_all.sh keeps it in a private
#   folder and deletes it at the end of the run.
# <logins-file>: one lower-case login per line.
# Output (CSV, no header), one row per login found: login, first_name, last_name, owner, cost_centre
#
# Search: from basedn, with ldapsearchfilter ($username replaced, one query per login) or
# else (ldapsearchattribute=<login>) (default attribute uid, as in Postgres), in batches.
# Base64 values from AD (accented names) are decoded; an owner given as a DN
# ("CN=Tremblay\, Marc,OU=...") is reduced to its name ("Tremblay, Marc").
# Exits non-zero if AD cannot be reached or the bind fails.
set -euo pipefail
LOG_NAME="ad_lookup"
# shellcheck source=lib.sh
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"

PROFILE_FILE="${1:-}"; LOGINS_FILE="${2:-}"
[ -r "$PROFILE_FILE" ] && [ -r "$LOGINS_FILE" ] || die "usage: ad_lookup.sh <profile-file> <logins-file>"

IFS=$'\x1f' read -r SERVER PORT SCHEME TLS BASEDN BINDDN BINDPW SEARCH_ATTR SEARCH_FILTER < "$PROFILE_FILE" || true
[ -n "${SERVER:-}" ] && [ -n "${BASEDN:-}" ] || die "profile has no ldapserver or ldapbasedn"

# Password file for ldapsearch -y (never on the command line, where `ps` would show it).
umask 077
PRIV="$(mktemp -d)"
trap 'rm -rf "$PRIV"' EXIT
printf '%s' "${BINDPW:-}" > "$PRIV/pw"

# Connection options, as Postgres builds them from the pg_hba.conf line.
URIS=""
for host in $SERVER; do URIS+="${SCHEME:-ldap}://$host${PORT:+:$PORT} "; done
# -x = simple bind (bind DN + password), as Postgres does; without it ldapsearch tries SASL.
LDAP_OPTS=(-x -LLL -o ldif-wrap=no -E pr=1000/noprompt -H "${URIS% }")
[ "${TLS:-}" = "1" ] && LDAP_OPTS+=(-ZZ)
[ -n "${BINDDN:-}" ] && LDAP_OPTS+=(-D "$BINDDN" -y "$PRIV/pw")

A_FIRST="$(tr 'A-Z' 'a-z' <<< "${AD_ATTR_FIRST_NAME:-}")"
A_LAST="$(tr 'A-Z' 'a-z' <<< "${AD_ATTR_LAST_NAME:-}")"
A_OWNER="$(tr 'A-Z' 'a-z' <<< "${AD_ATTR_OWNER:-}")"
A_COST="$(tr 'A-Z' 'a-z' <<< "${AD_ATTR_COST_CENTRE:-}")"
ATTR="${SEARCH_ATTR:-uid}"
A_LOGIN="$(tr 'A-Z' 'a-z' <<< "$ATTR")"
ATTRS=("$ATTR")
for a in "${AD_ATTR_FIRST_NAME:-}" "${AD_ATTR_LAST_NAME:-}" "${AD_ATTR_OWNER:-}" "${AD_ATTR_COST_CENTRE:-}"; do
    [ -n "$a" ] && ATTRS+=("$a")
done

# CSV field: empty -> unquoted (loads as NULL); otherwise quoted, quotes doubled.
csv() {
    local v="${1//$'\r'/}"; v="${v//$'\n'/ }"
    if [ -z "$v" ]; then printf ''; else printf '"%s"' "${v//\"/\"\"}"; fi
}

# DN -> value of its first component: "CN=Tremblay\, Marc,OU=x" -> "Tremblay, Marc"
dn_to_name() { sed -E -e 's/^[A-Za-z]+=((\\.|[^,])*).*$/\1/' -e 's/\\(.)/\1/g' <<< "$1"; }

# LDIF on stdin -> lines "login\x1ffirst\x1flast\x1fowner\x1fcost" (\x1f, not a tab: bash
# would merge consecutive tabs and shift empty fields). $1 = fixed login (filter mode) or "".
parse_ldif() {
    local fixed="$1" line attr val login="" first="" last="" owner="" cost=""
    emit() {
        [ -n "$fixed" ] && login="$fixed"
        if [ -n "$login" ]; then
            printf '%s\x1f%s\x1f%s\x1f%s\x1f%s\n' "$login" "$first" "$last" "$owner" "$cost"
        fi
        login=""; first=""; last=""; owner=""; cost=""
    }
    while IFS= read -r line || [ -n "$line" ]; do
        line="${line%$'\r'}"
        if [ -z "$line" ]; then emit; continue; fi
        [[ "$line" == *:* ]] || continue
        attr="$(tr 'A-Z' 'a-z' <<< "${line%%:*}")"
        val="${line#*:}"
        if [[ "$val" == :* ]]; then                          # "attr:: base64"
            val="$(printf '%s' "${val#:}" | tr -d ' ' | base64 -d 2>/dev/null || true)"
        else
            val="${val# }"
        fi
        val="${val//$'\x1f'/ }"
        [ "$attr" = "dn" ] && continue
        [ "$attr" = "$A_LOGIN" ] && login="$(tr 'A-Z' 'a-z' <<< "$val")"
        [ -n "$A_FIRST" ] && [ "$attr" = "$A_FIRST" ] && first="$val"
        [ -n "$A_LAST"  ] && [ "$attr" = "$A_LAST"  ] && last="$val"
        if [ -n "$A_OWNER" ] && [ "$attr" = "$A_OWNER" ]; then
            if [[ "$val" == *=* ]]; then owner="$(dn_to_name "$val")"; else owner="$val"; fi
        fi
        [ -n "$A_COST"  ] && [ "$attr" = "$A_COST"  ] && cost="$val"
    done
    emit
}

OUT="$PRIV/found"; : > "$OUT"
mapfile -t LOGINS < <(grep -v '^[[:space:]]*$' "$LOGINS_FILE" | sort -u)

if [ -n "${SEARCH_FILTER:-}" ]; then
    # ldapsearchfilter: one query per login, $username replaced as Postgres does.
    for l in "${LOGINS[@]}"; do
        esc="$(printf '%s' "$l" | ldap_escape)"
        ldapsearch "${LDAP_OPTS[@]}" -b "$BASEDN" "${SEARCH_FILTER//\$username/$esc}" "${ATTRS[@]}" \
            | parse_ldif "$l" >> "$OUT"
    done
else
    # ldapsearchattribute: batches of AD_BATCH logins per query.
    mapfile -t ESCAPED < <(printf '%s\n' "${LOGINS[@]}" | ldap_escape)
    for ((i = 0; i < ${#ESCAPED[@]}; i += AD_BATCH)); do
        f=""
        for n in "${ESCAPED[@]:i:AD_BATCH}"; do f+="($ATTR=$n)"; done
        ldapsearch "${LDAP_OPTS[@]}" -b "$BASEDN" "(|$f)" "${ATTRS[@]}" | parse_ldif "" >> "$OUT"
    done
fi

# One row per login (first entry wins), CSV.
declare -A DONE=()
while IFS=$'\x1f' read -r login first last owner cost; do
    [ -n "$login" ] && [ -z "${DONE[$login]:-}" ] || continue
    DONE[$login]=1
    printf '%s,%s,%s,%s,%s\n' "$(csv "$login")" "$(csv "$first")" "$(csv "$last")" "$(csv "$owner")" "$(csv "$cost")"
done < "$OUT"
