#!/usr/bin/env bash
set -Eeuo pipefail

readonly PROJECT_DIR="/opt/bkp-rclone"
readonly CONFIG_FILE="${PROJECT_DIR}/services/Estoque - Gestao de Estoque/backup.conf"
readonly SECRETS_FILE="${PROJECT_DIR}/.env"
readonly REMOTE_DIR="gdrive:Central de BKP/Estoque - Gestao de Estoque/full"
readonly LOCK_FILE="/run/lock/nexterp-rclone-backup.lock"

load_config() {
  local file="$1" allowed="$2" line key value
  while IFS= read -r line || [[ -n "$line" ]]; do
    line="${line%$'\r'}"
    [[ -z "${line//[[:space:]]/}" || "$line" =~ ^[[:space:]]*# ]] && continue
    [[ "$line" =~ ^[[:space:]]*([A-Z][A-Z0-9_]*)[[:space:]]*=[[:space:]]*(.*)[[:space:]]*$ ]] || { echo "Linha inválida em ${file}" >&2; return 1; }
    key="${BASH_REMATCH[1]}"; value="${BASH_REMATCH[2]}"
    [[ " $allowed " == *" $key "* ]] || { echo "Chave não permitida em ${file}: ${key}" >&2; return 1; }
    if [[ "$value" == \"*\" && "$value" == *\" ]] || [[ "$value" == \'*\' && "$value" == *\' ]]; then value="${value:1:${#value}-2}"; fi
    [[ "$value" != *';'* && "$value" != *'`'* && "$value" != *'$('* ]] || { echo "Valor inseguro em ${file}: ${key}" >&2; return 1; }
    printf -v "$key" '%s' "$value"
  done < "$file"
}

exec 9>"${LOCK_FILE}"
flock -n 9 || { echo "Outro backup NextERP está em execução." >&2; exit 1; }

load_config "${SECRETS_FILE}" 'GPG_PASSPHRASE MATTERMOST_WEBHOOK_URL DEFAULT_RETENTION_DAYS MINIMUM_REMOTE_BACKUPS RCLONE_REMOTE_ROOT BACKUP_LOCK_FILE'
load_config "${CONFIG_FILE}" 'BACKUP_TYPE FRAPPE_CONTAINER FRAPPE_SITE RETENCAO_DIAS EXTERNAL_REMOTE_SUBDIR'

: "${GPG_PASSPHRASE:?GPG_PASSPHRASE não configurada}"
: "${FRAPPE_CONTAINER:?FRAPPE_CONTAINER não configurado}"
: "${FRAPPE_SITE:?FRAPPE_SITE não configurado}"

timestamp="$(date +%Y%m%d_%H%M%S)"
work_dir="$(mktemp -d /tmp/nexterp-backup.XXXXXX)"
container_dir="/tmp/cdc_backup_${timestamp}"
archive="${work_dir}/nexterp_full_${timestamp}.tar.gz"
encrypted="${archive}.gpg"
checksum="${encrypted}.sha256"
verify="${work_dir}/verify/$(basename "${encrypted}")"

cleanup() {
  docker exec "${FRAPPE_CONTAINER}" rm -rf "${container_dir}" >/dev/null 2>&1 || true
  rm -rf "${work_dir}"
}
trap cleanup EXIT

docker inspect "${FRAPPE_CONTAINER}" >/dev/null
docker exec "${FRAPPE_CONTAINER}" mkdir -p "${container_dir}"
docker exec -w /home/frappe/frappe-bench "${FRAPPE_CONTAINER}" \
  bench --site "${FRAPPE_SITE}" backup --with-files --compress \
  --backup-path-db "${container_dir}/database.sql.gz" \
  --backup-path-files "${container_dir}/public-files.tar" \
  --backup-path-private-files "${container_dir}/private-files.tar" \
  --backup-path-conf "${container_dir}/site_config_backup.json"

mkdir -p "${work_dir}/payload"
docker cp "${FRAPPE_CONTAINER}:${container_dir}/." "${work_dir}/payload/"
for required in database.sql.gz public-files.tar private-files.tar site_config_backup.json; do
  test -s "${work_dir}/payload/${required}"
done

tar -czf "${archive}" -C "${work_dir}" payload
printf '%s' "${GPG_PASSPHRASE}" | gpg --batch --yes --pinentry-mode loopback \
  --passphrase-fd 0 --symmetric --cipher-algo AES256 \
  --output "${encrypted}" "${archive}"
sha256sum "${encrypted}" > "${checksum}"

rclone copyto "${encrypted}" "${REMOTE_DIR}/$(basename "${encrypted}")" --log-level ERROR
rclone copyto "${checksum}" "${REMOTE_DIR}/$(basename "${checksum}")" --log-level ERROR
mkdir -p "$(dirname "${verify}")"
rclone copyto "${REMOTE_DIR}/$(basename "${encrypted}")" "${verify}" --log-level ERROR
printf '%s  %s\n' "$(sha256sum "${encrypted}" | cut -d' ' -f1)" "${verify}" | sha256sum -c - >/dev/null

remote_count="$(rclone lsf "${REMOTE_DIR}" --files-only --include '*.gpg' --log-level ERROR | sed '/^$/d' | wc -l)"
if [[ "${SKIP_RETENTION:-0}" != "1" && "${remote_count}" -gt "${MINIMUM_REMOTE_BACKUPS:-2}" ]]; then
  rclone delete --min-age "${RETENCAO_DIAS:-30}d" "${REMOTE_DIR}/" --log-level ERROR
fi

printf 'BACKUP_OK file=%s sha256=%s\n' "$(basename "${encrypted}")" "$(sha256sum "${encrypted}" | cut -d' ' -f1)"
