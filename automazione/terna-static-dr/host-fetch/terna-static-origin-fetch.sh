#!/usr/bin/env bash
set -euo pipefail

root=/srv/terna-static-dr/static
bundles_dir="${root}/bundles"
builder=/usr/local/lib/terna-static-dr/build-static-bundle.py
chart_builder=/usr/local/lib/terna-static-dr/build-load-screenshot.py
public_dns_resolver="${TERNA_PUBLIC_DNS_RESOLVER:-10.10.4.2}"
allow_refresh_during_dr="${TERNA_DR_ALLOW_REFRESH_DURING_DR:-false}"
minimum_source_bytes=100000

install -d -m 0750 /run/terna-static-dr
exec 9>/run/terna-static-dr/origin-fetch.lock
flock -w 60 9 || {
  echo 'Another Terna snapshot refresh is still running; retry later.' >&2
  exit 1
}

# The timer freezes the point-in-time copy during DR. Reconcile may explicitly
# override this for an atomic format migration; the current bundle remains live
# until the replacement has passed every validation.
if [ -f "${root}/dr-active" ] && [ "${allow_refresh_during_dr}" != true ]; then
  echo 'Terna DR is active; scheduled snapshot refresh skipped.'
  exit 0
fi
command -v python3 >/dev/null 2>&1 || { echo 'python3 is required by the Terna static bundle builder.' >&2; exit 1; }
[ -r "${builder}" ] || { echo "Missing static bundle builder: ${builder}" >&2; exit 1; }
[ -r "${chart_builder}" ] || { echo "Missing Terna load chart builder: ${chart_builder}" >&2; exit 1; }

install -d -m 2770 -o 65534 -g 101 "${root}" "${bundles_dir}"
source_file="$(mktemp "${root}/source.XXXXXX")"
bundle="$(mktemp -d "${bundles_dir}/bundle.$(date +%s).XXXXXX")"
next="${root}/.current.$$"
cleanup() {
  rm -f -- "${source_file}" "${next}"
  [ "${keep_bundle}" = true ] || rm -rf -- "${bundle}"
}
keep_bundle=false
trap cleanup EXIT HUP INT TERM

is_public_ipv4() {
  python3 - "$1" <<'PY'
import ipaddress
import sys

try:
    address = ipaddress.ip_address(sys.argv[1])
except ValueError:
    sys.exit(1)
sys.exit(0 if address.version == 4 and address.is_global else 1)
PY
}

resolve_public_origin() {
  local answer candidate resolver
  local resolvers=("${public_dns_resolver}" 10.10.2.53)
  for resolver in "${resolvers[@]}"; do
    [[ "${resolver}" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]] || continue
    answer="$(dig "@${resolver}" +time=8 +tries=1 +short www.terna.it A 2>/dev/null || true)"
    while IFS= read -r candidate; do
      if [[ "${candidate}" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]] \
        && is_public_ipv4 "${candidate}"; then
        echo "Terna public origin resolved through ${resolver}: ${candidate}" >&2
        printf '%s\n' "${candidate}"
        return 0
      fi
    done <<<"${answer}"
    echo "Resolver ${resolver} returned no public Terna IPv4 address; trying the next resolver." >&2
  done
  return 1
}

if ! origin_ip="$(resolve_public_origin)"; then
  echo 'No configured lab resolver returned a public IPv4 address for www.terna.it.' >&2
  exit 1
fi

curl --fail --silent --show-error --compressed \
  --retry 3 --retry-all-errors --connect-timeout 15 --max-time 90 \
  --noproxy '*' --proto '=https' --proto-redir '=https' \
  --resolve "www.terna.it:443:${origin_ip}" \
  --user-agent 'Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 Chrome/140.0.0.0 Safari/537.36' \
  --header 'Accept-Language: it-IT,it;q=0.9' \
  https://www.terna.it/it --output "${source_file}"

source_bytes="$(wc -c <"${source_file}" | tr -d ' ')"
[ "${source_bytes}" -ge "${minimum_source_bytes}" ] || {
  echo "Downloaded Terna source is only ${source_bytes} bytes." >&2
  exit 1
}
grep -qi 'Terna' "${source_file}" || {
  echo 'Downloaded source does not contain the expected Terna identity.' >&2
  exit 1
}

python3 "${builder}" \
  --source "${source_file}" \
  --output "${bundle}" \
  --origin-ip "${origin_ip}"

# Carry the last valid chart into the candidate bundle. The chart builder will
# replace it atomically with either fresh data or an explicit local placeholder.
previous_chart="${root}/current/dr/load-chart"
if [ -f "${previous_chart}/.load-chart-v1" ]; then
  install -d -m 0750 "${bundle}/dr"
  cp -a -- "${previous_chart}" "${bundle}/dr/load-chart"
fi

if [ -f "${root}/dr-active" ] && [ "${allow_refresh_during_dr}" = true ]; then
  if [ -f "${bundle}/dr/load-chart/.load-chart-v1" ]; then
    echo 'Existing valid load chart preserved; API refresh skipped during DR migration.'
  else
    # The local terna.it zone is authoritative during DR and intentionally does
    # not expose api.terna.it. Publish an explicit placeholder now; a primary
    # timer run will replace it with authenticated data after cutback.
    python3 "${chart_builder}" --output "${bundle}" --origin-ip "${origin_ip}" --placeholder
    echo 'Load chart placeholder published; API refresh skipped during DR migration.'
  fi
else
  if ! python3 "${chart_builder}" --output "${bundle}" --origin-ip "${origin_ip}"; then
    if [ -f "${bundle}/dr/load-chart/.load-chart-v1" ]; then
      echo 'Terna API refresh failed; the previous valid load chart was preserved.' >&2
    else
      python3 "${chart_builder}" --output "${bundle}" --origin-ip "${origin_ip}" --placeholder
    fi
  fi
fi

test -s "${bundle}/index.html"
test -s "${bundle}/manifest.json"
test -f "${bundle}/.bundle-v1"
test -s "${bundle}/dr/load-chart/index.html"
test -s "${bundle}/dr/load-chart/data.json"
if [ ! -f "${bundle}/dr/load-chart/.load-chart-v1" ] \
  && [ ! -f "${bundle}/dr/load-chart/.load-chart-placeholder-v1" ]; then
  echo 'The candidate bundle contains no valid Terna load chart marker.' >&2
  exit 1
fi
date -u +%Y-%m-%dT%H:%M:%SZ >"${bundle}/captured-at"
printf '%s\n' static-bundle >"${bundle}/capture-mode"
chown -R 1000:101 "${bundle}"
chmod -R u+rwX,g+rX,o-rwx "${bundle}"

# A normal timer run must not publish across a concurrent failover. Explicit
# reconcile migrations are allowed because the previous bundle stays live
# until this atomic switch.
if [ -f "${root}/dr-active" ] && [ "${allow_refresh_during_dr}" != true ]; then
  echo 'Terna DR became active during acquisition; candidate bundle discarded.'
  exit 0
fi
rm -f -- "${next}"
ln -s "bundles/$(basename "${bundle}")" "${next}"
keep_bundle=true
mv -Tf "${next}" "${root}/current"
trap - EXIT HUP INT TERM
rm -f -- "${source_file}"

# Keep only the two newest published bundles to bound host-side storage.
set -- $(find "${bundles_dir}" -mindepth 1 -maxdepth 1 -type d -name 'bundle.*' | sort)
while [ "$#" -gt 2 ]; do
  rm -rf -- "$1"
  shift
done

echo "Terna static bundle refreshed (${source_bytes} HTML bytes from ${origin_ip})."
