#!/usr/bin/env bash
# Verifica il sync del mirror on-prem (scripts/backup/mirror-from-s3.sh) con una
# CLI `aws` mockata su PATH e una "S3 finta" su filesystem. Nessuna dipendenza da
# LXD, AWS reale o rete.
set -euo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "${TEST_DIR}/.." && pwd)"
temp_dir="$(mktemp -d)"
trap 'rm -rf "${temp_dir}"' EXIT

mirror_root="${temp_dir}/mirror"
fake_s3="${temp_dir}/s3/postgres"
bin_dir="${temp_dir}/bin"
mkdir -p "${mirror_root}" "${fake_s3}" "${bin_dir}"
mirror_dir="${mirror_root}/postgres"

# Backup finti su S3. Il .sha256 imita il CronJob del primario, che scrive il
# checksum col PATH ASSOLUTO del pod (/work/...): il sync deve normalizzarlo a
# basename perche' restore-onprem.sh fa `sha256sum -c` dal mirror.
make_dump() {
  local stamp="$1" content="$2"
  printf '%s' "${content}" >"${fake_s3}/${stamp}.dump"
  printf '%s  /work/postgres-%s.dump\n' \
    "$(sha256sum "${fake_s3}/${stamp}.dump" | awk '{print $1}')" "${stamp}" \
    >"${fake_s3}/${stamp}.dump.sha256"
}
make_dump 20260101T000000Z aaa
make_dump 20260102T000000Z bbb
make_dump 20260103T000000Z ccc

# Mock della CLI `aws`: s3 ls / s3 cp contro la S3 finta. FAKE_S3_FAIL=1 simula il
# primario/rete irraggiungibile. Salta un eventuale `--region <val>` in testa.
cat >"${bin_dir}/aws" <<'AWS'
#!/usr/bin/env bash
set -eu
[ "${FAKE_S3_FAIL:-0}" = 1 ] && exit 1
# Salta le opzioni globali in testa (--region X, --cli-connect-timeout X, ...)
# fino al comando di servizio `s3`.
while [ "$#" -gt 0 ] && [ "${1}" != "s3" ]; do shift; done
case "${1:-} ${2:-}" in
  "s3 ls")
    for f in "${FAKE_S3_DIR}"/*; do
      [ -e "$f" ] || continue
      printf '2026-01-01 00:00:00 %s %s\n' "$(wc -c <"$f")" "$(basename "$f")"
    done
    ;;
  "s3 cp")
    cp "${FAKE_S3_DIR}/$(basename "$3")" "$4"
    ;;
  *) exit 2 ;;
esac
AWS
chmod +x "${bin_dir}/aws"

cat >"${temp_dir}/config.env" <<EOF
POSTGRES_PASSWORD=test-only
DR_REQUIRE_ANSIBLE_NODE=false
BACKUP_MIRROR_DIR=${mirror_root}
BACKUP_S3_PREFIX=postgres
BACKUP_S3_BUCKET=fake-bucket
BACKUP_MIRROR_RETENTION=2
EOF
export HELPDESK_DR_CONFIG_FILE="${temp_dir}/config.env"
export FAKE_S3_DIR="${fake_s3}"
export PATH="${bin_dir}:${PATH}"

run_sync() { bash "${ROOT_DIR}/scripts/backup/mirror-from-s3.sh" >/dev/null 2>&1; }
fail() { echo "FAIL: $1" >&2; exit 1; }

# 1) Sync normale: mirrora i 2 piu' recenti, non scarica il piu' vecchio.
run_sync
[ -f "${mirror_dir}/20260103T000000Z.dump" ] || fail 'newest backup not mirrored.'
[ -f "${mirror_dir}/20260102T000000Z.dump" ] || fail '2nd newest backup not mirrored.'
[ ! -f "${mirror_dir}/20260101T000000Z.dump" ] || fail 'oldest backup should not be fetched.'
count="$(find "${mirror_dir}" -maxdepth 1 -type f -name '*.dump' | wc -l | tr -d ' ')"
[ "${count}" = 2 ] || fail "expected 2 dumps in the mirror, got ${count}."

# 2) Il .sha256 del mirror e' normalizzato a basename (restore fa `sha256sum -c`).
(cd "${mirror_dir}" && sha256sum -c 20260103T000000Z.dump.sha256 >/dev/null) \
  || fail 'mirror checksum not normalized to basename.'

# 3) Un backup piu' recente ruota il set: entra il nuovo, esce il piu' vecchio tenuto.
make_dump 20260104T000000Z ddd
run_sync
[ -f "${mirror_dir}/20260104T000000Z.dump" ] || fail 'newer backup not mirrored on next run.'
[ ! -f "${mirror_dir}/20260102T000000Z.dump" ] || fail 'rotated-out backup not pruned.'

# 4) Cloud giu' (aws fallisce): il mirror NON deve essere toccato.
before="$(find "${mirror_dir}" -maxdepth 1 -type f | sort)"
if FAKE_S3_FAIL=1 bash "${ROOT_DIR}/scripts/backup/mirror-from-s3.sh" >/dev/null 2>&1; then
  fail 'sync must exit non-zero when S3 is unreachable.'
fi
after="$(find "${mirror_dir}" -maxdepth 1 -type f | sort)"
[ "${before}" = "${after}" ] || fail 'mirror was modified during an S3 outage.'

# 5) Checksum non combaciante su S3: quel backup viene rifiutato, non mirrorato.
printf 'eee' >"${fake_s3}/20260105T000000Z.dump"
printf '%s  /work/postgres-20260105T000000Z.dump\n' \
  '0000000000000000000000000000000000000000000000000000000000000000' \
  >"${fake_s3}/20260105T000000Z.dump.sha256"
run_sync
[ ! -f "${mirror_dir}/20260105T000000Z.dump" ] || fail 'corrupt backup was accepted.'

echo 'Backup mirror behavior tests passed.'
