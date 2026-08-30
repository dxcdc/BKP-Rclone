#!/usr/bin/env bash
set -Eeuo pipefail
umask 077

PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SERVICES_DIR="${PROJECT_DIR}/services"
TIMESTAMP="$(date +%Y%m%d_%H%M%S)"; TODAY_DATE="$(date +%Y%m%d)"
REMOTE_ROOT="${RCLONE_REMOTE_ROOT:-gdrive:Central de BKP}"
DEFAULT_RETENTION_DAYS="${DEFAULT_RETENTION_DAYS:-15}"
MINIMUM_REMOTE_BACKUPS="${MINIMUM_REMOTE_BACKUPS:-2}"
LOCK_FILE="${BACKUP_LOCK_FILE:-/tmp/cdc-backup.lock}"
FILTER_SERVICE="${1:-}"; FORCE_ACTION="${2:-}"
TOTAL_SUCCESS=0; TOTAL_FAILURES=0; TOTAL_SKIPPED=0; TOTAL_INACTIVE=0
RUNTIME_DIR=""; SUMMARY_FILE=""; CURRENT_SERVICE="inicialização"; NOTIFIED=false

log() { printf '%s\n' "$*"; }

load_config() {
  local file="$1" allowed="$2" line key value
  [[ -f "$file" ]] || return 0
  while IFS= read -r line || [[ -n "$line" ]]; do
    line="${line%$'\r'}"
    [[ -z "${line//[[:space:]]/}" || "$line" =~ ^[[:space:]]*# ]] && continue
    [[ "$line" =~ ^[[:space:]]*([A-Z][A-Z0-9_]*)[[:space:]]*=[[:space:]]*(.*)[[:space:]]*$ ]] || { log "[-] Linha inválida em $file"; return 1; }
    key="${BASH_REMATCH[1]}"; value="${BASH_REMATCH[2]}"
    [[ " $allowed " == *" $key "* ]] || { log "[-] Chave não permitida em $file: $key"; return 1; }
    if [[ "$value" == \"*\" && "$value" == *\" ]] || [[ "$value" == \'*\' && "$value" == *\' ]]; then value="${value:1:${#value}-2}"; fi
    [[ "$value" != *';'* && "$value" != *'`'* && "$value" != *'$('* ]] || { log "[-] Valor inseguro em $file: $key"; return 1; }
    printf -v "$key" '%s' "$value"
  done < "$file"
}

notify() {
  [[ "$NOTIFIED" == true ]] && return 0; NOTIFIED=true
  [[ -n "${MATTERMOST_WEBHOOK_URL:-}" && -f "${SUMMARY_FILE:-}" ]] || return 0
  local heading body json
  heading='### :white_check_mark: **Relatório Geral de Backups - CDC (Sucesso)**'
  (( TOTAL_FAILURES > 0 )) && heading='### :warning: **Relatório Geral de Backups - CDC (Com falhas)**'
  body="$heading\n\n* **Host:** $(hostname)\n* **Sucessos:** $TOTAL_SUCCESS\n* **Falhas:** $TOTAL_FAILURES\n* **Pulados:** $TOTAL_SKIPPED\n* **Inativos:** $TOTAL_INACTIVE\n\n$(cat "$SUMMARY_FILE")"
  json="$(printf '%s' "$body" | sed ':a;N;$!ba;s/\\/\\\\/g;s/"/\\"/g;s/\n/\\n/g')"
  curl --fail --silent --show-error --connect-timeout 10 --max-time 30 -H 'Content-Type: application/json' --data "{\"text\":\"$json\"}" "$MATTERMOST_WEBHOOK_URL" >/dev/null
}

cleanup() {
  local code=$?; trap - EXIT INT TERM
  if (( code != 0 )) && [[ -f "${SUMMARY_FILE:-}" ]] && (( TOTAL_FAILURES == 0 )); then
    printf '| **%s** | :x: FALHA | - | - | - | Execução interrompida |\n' "$CURRENT_SERVICE" >> "$SUMMARY_FILE"; TOTAL_FAILURES=1
  fi
  notify || code=1
  [[ -n "$RUNTIME_DIR" && -d "$RUNTIME_DIR" ]] && rm -rf -- "$RUNTIME_DIR"
  exit "$code"
}
trap cleanup EXIT; trap 'exit 130' INT TERM

require_tools() { local c missing=(); for c in docker flock gpg rclone sha256sum tar curl; do command -v "$c" >/dev/null || missing+=("$c"); done; ((${#missing[@]}==0)) || { log "[-] Dependências ausentes: ${missing[*]}"; return 1; }; }

resolve_container() {
  local selector="$1" matches count
  docker container inspect "$selector" >/dev/null 2>&1 && { printf '%s\n' "$selector"; return; }
  matches="$(docker ps --filter status=running --format '{{.Names}}' | awk -v selector="$selector" '$0 == selector || index($0, selector ".1.") == 1')"; count="$(sed '/^$/d' <<<"$matches" | wc -l)"
  [[ "$count" -eq 1 ]] || { log "[-] Seletor '$selector' encontrou $count containers." >&2; return 1; }
  printf '%s\n' "$matches"
}

container_env() { docker inspect --format='{{range .Config.Env}}{{println .}}{{end}}' "$1" | sed -n -E "s/^($2)=(.*)$/\\2/p" | head -n1 || true; }
sanitize_error() { tr '\n|' ' -' < "$1" | cut -c1-500; }

record_log() {
  local service="$1" status="$2" detail="$3" file="${SERVICES_DIR}/$1/logs.txt" tmp
  tmp="$(mktemp "$RUNTIME_DIR/log.XXXXXX")"
  printf '[%s] [%s] [Host: %s] [Serviço: %s] %s\n' "$(date +'%F %T %Z')" "$status" "$(hostname)" "$service" "$detail" > "$tmp"
  [[ -f "$file" ]] && cat "$file" >> "$tmp"; mv "$tmp" "$file"
  rclone copyto "$file" "$REMOTE_ROOT/$service/logs.txt" --log-level ERROR
}

failure() {
  local service="$1" type="$2" detail="${3:-Erro não detalhado}"
  TOTAL_FAILURES=$((TOTAL_FAILURES+1)); record_log "$service" FALHA "$detail" || true
  printf '| **%s** | :x: FALHA | %s | - | - | %s |\n' "$service" "$type" "$detail" >> "$SUMMARY_FILE"
}

process_service() {
  local path="$1" service config target remote base archive encrypted err started container='' container_copy='' password command hash size duration retention count
  service="$(basename "$path")"; CURRENT_SERVICE="$service"; config="$path/backup.conf"; log "[+] Processando: $service"
  rclone mkdir "$REMOTE_ROOT/$service/db" --log-level ERROR; rclone mkdir "$REMOTE_ROOT/$service/files" --log-level ERROR
  [[ -f "$path/info.txt" ]] && rclone copyto "$path/info.txt" "$REMOTE_ROOT/$service/info.txt" --log-level ERROR
  if [[ ! -f "$config" ]]; then TOTAL_INACTIVE=$((TOTAL_INACTIVE+1)); printf '| **%s** | :white_circle: INATIVO | - | - | - | Sem backup.conf |\n' "$service" >> "$SUMMARY_FILE"; return; fi
  unset BACKUP_TYPE DB_CONTAINER DB_USER DB_NAME SOURCE_PATH RETENCAO_DIAS
  load_config "$config" 'BACKUP_TYPE DB_CONTAINER DB_USER DB_NAME SOURCE_PATH RETENCAO_DIAS FRAPPE_CONTAINER FRAPPE_SITE EXTERNAL_REMOTE_SUBDIR' || { failure "$service" '?' 'Configuração inválida'; return; }
  [[ "${BACKUP_TYPE:-}" =~ ^(postgres|mysql|mariadb|sqlite|container_sqlite|files|container_files|vaultwarden|frappe)$ ]] || { failure "$service" "${BACKUP_TYPE:-?}" 'Tipo inválido'; return; }
  target=db; [[ "$BACKUP_TYPE" == files || "$BACKUP_TYPE" == container_files || "$BACKUP_TYPE" == vaultwarden ]] && target=files; [[ "$BACKUP_TYPE" == frappe ]] && target="${EXTERNAL_REMOTE_SUBDIR:-full}"; remote="$REMOTE_ROOT/$service/$target"
  if [[ "$BACKUP_TYPE" == frappe ]]; then
    if rclone lsf "$remote" --files-only --include "*${TODAY_DATE}*.gpg" --log-level ERROR 2>/dev/null | grep -q .; then
      TOTAL_SUCCESS=$((TOTAL_SUCCESS+1)); record_log "$service" SUCESSO 'Backup Frappe externo de hoje confirmado'; printf '| **%s** | :white_check_mark: SUCESSO | frappe | - | - | Backup externo confirmado |\n' "$service" >> "$SUMMARY_FILE"; return
    fi
    failure "$service" frappe 'Backup Frappe externo de hoje não encontrado'; return
  fi
  if [[ "$FORCE_ACTION" != force ]] && rclone lsf "$remote" --files-only --include "*_${TODAY_DATE}_*.gpg" --log-level ERROR 2>/dev/null | grep -q .; then
    TOTAL_SKIPPED=$((TOTAL_SKIPPED+1)); record_log "$service" PULADO 'Backup de hoje já existe'; printf '| **%s** | :double_vertical_bar: PULADO | %s | - | - | Já realizado hoje |\n' "$service" "$BACKUP_TYPE" >> "$SUMMARY_FILE"; return
  fi
  base="$RUNTIME_DIR/dump_${service//\//_}_$TIMESTAMP"; archive="$base.tar.gz"; encrypted="$archive.gpg"; err="$(mktemp "$RUNTIME_DIR/error.XXXXXX")"; started="$(date +%s)"
  log "[+] Gerando origem do backup ($BACKUP_TYPE)..."
  case "$BACKUP_TYPE" in
    postgres)
      container="$(resolve_container "${DB_CONTAINER:?DB_CONTAINER obrigatório}")" || { failure "$service" "$BACKUP_TYPE" 'Container ausente ou ambíguo'; return; }
      DB_USER="${DB_USER:-$(container_env "$container" 'POSTGRES_USER|PGUSER')}"; DB_USER="${DB_USER:-postgres}"; DB_NAME="${DB_NAME:-$(container_env "$container" 'POSTGRES_DB|PGDATABASE')}"; DB_NAME="${DB_NAME:-postgres}"; password="$(container_env "$container" 'POSTGRES_PASSWORD|PGPASSWORD')"
      PGPASSWORD="$password" docker exec -i -e PGPASSWORD "$container" pg_dump -U "$DB_USER" -d "$DB_NAME" -F p > "$base.sql" 2>"$err" || { failure "$service" "$BACKUP_TYPE" "$(sanitize_error "$err")"; return; }
      tar -czf "$archive" -C "$RUNTIME_DIR" "$(basename "$base").sql"; rm -f -- "$base.sql" ;;
    mysql|mariadb)
      container="$(resolve_container "${DB_CONTAINER:?DB_CONTAINER obrigatório}")" || { failure "$service" "$BACKUP_TYPE" 'Container ausente ou ambíguo'; return; }
      DB_USER="${DB_USER:-$(container_env "$container" 'MYSQL_USER|MARIADB_USER')}"; DB_USER="${DB_USER:-root}"; DB_NAME="${DB_NAME:-$(container_env "$container" 'MYSQL_DATABASE|MARIADB_DATABASE')}"; [[ -n "$DB_NAME" ]] || { failure "$service" "$BACKUP_TYPE" 'DB_NAME não identificado'; return; }; password="$(container_env "$container" 'MYSQL_ROOT_PASSWORD|MYSQL_PASSWORD|MARIADB_ROOT_PASSWORD|MARIADB_PASSWORD')"
      command=mysqldump; docker exec "$container" sh -c 'command -v mariadb-dump >/dev/null' >/dev/null 2>&1 && command=mariadb-dump
      MYSQL_PWD="$password" docker exec -i -e MYSQL_PWD "$container" "$command" -u "$DB_USER" -- "$DB_NAME" > "$base.sql" 2>"$err" || { failure "$service" "$BACKUP_TYPE" "$(sanitize_error "$err")"; return; }
      tar -czf "$archive" -C "$RUNTIME_DIR" "$(basename "$base").sql"; rm -f -- "$base.sql" ;;
    sqlite)
      [[ -f "${SOURCE_PATH:-}" ]] && command -v sqlite3 >/dev/null || { failure "$service" sqlite 'SQLite ou sqlite3 indisponível'; return; }
      sqlite3 "$SOURCE_PATH" ".backup '$base.db'" 2>"$err" || { failure "$service" sqlite "$(sanitize_error "$err")"; return; }; tar -czf "$archive" -C "$RUNTIME_DIR" "$(basename "$base").db"; rm -f -- "$base.db" ;;
    container_sqlite)
      container="$(resolve_container "${DB_CONTAINER:?DB_CONTAINER obrigatório}")" || { failure "$service" container_sqlite 'Container ausente ou ambíguo'; return; }
      [[ -n "${SOURCE_PATH:-}" ]] || { failure "$service" container_sqlite 'SOURCE_PATH obrigatório'; return; }
      container_copy="/tmp/cdc-backup-${TIMESTAMP}.sqlite3"
      docker exec "$container" python -c 'import sqlite3,sys; src=sqlite3.connect("file:"+sys.argv[1]+"?mode=ro",uri=True); dst=sqlite3.connect(sys.argv[2]); src.backup(dst); dst.close(); src.close()' "$SOURCE_PATH" "$container_copy" 2>"$err" || { failure "$service" container_sqlite "$(sanitize_error "$err")"; return; }
      docker cp "$container:$container_copy" "$base.db"; docker exec "$container" rm -f "$container_copy"; tar -czf "$archive" -C "$RUNTIME_DIR" "$(basename "$base").db"; rm -f -- "$base.db" ;;
    files)
      [[ -e "${SOURCE_PATH:-}" ]] || { failure "$service" files 'Origem não encontrada'; return; }
      tar --warning=no-file-changed --ignore-failed-read -czf "$archive" -C "$(dirname "$SOURCE_PATH")" "$(basename "$SOURCE_PATH")" 2>"$err" || { failure "$service" files "$(sanitize_error "$err")"; return; } ;;
    container_files)
      container="$(resolve_container "${DB_CONTAINER:?DB_CONTAINER obrigatório}")" || { failure "$service" container_files 'Container ausente ou ambíguo'; return; }
      [[ -n "${SOURCE_PATH:-}" ]] || { failure "$service" container_files 'SOURCE_PATH obrigatório'; return; }
      docker exec "$container" test -e "$SOURCE_PATH" || { failure "$service" container_files 'Origem não encontrada no container'; return; }
      docker exec "$container" tar -czf - -C "$(dirname "$SOURCE_PATH")" "$(basename "$SOURCE_PATH")" > "$archive" 2>"$err" || { failure "$service" container_files "$(sanitize_error "$err")"; return; } ;;
    vaultwarden)
      [[ -d "${SOURCE_PATH:-}" && -f "$SOURCE_PATH/db.sqlite3" ]] && command -v sqlite3 >/dev/null || { failure "$service" vaultwarden 'Volume, db.sqlite3 ou sqlite3 indisponível'; return; }
      sqlite3 "$SOURCE_PATH/db.sqlite3" ".backup '$RUNTIME_DIR/db.sqlite3'" 2>"$err" || { failure "$service" vaultwarden "$(sanitize_error "$err")"; return; }
      tar --warning=no-file-changed --ignore-failed-read -czf "$archive" --exclude='./db.sqlite3' --exclude='./db.sqlite3-shm' --exclude='./db.sqlite3-wal' -C "$SOURCE_PATH" . -C "$RUNTIME_DIR" db.sqlite3 2>"$err" || { failure "$service" vaultwarden "$(sanitize_error "$err")"; return; }
      rm -f -- "$RUNTIME_DIR/db.sqlite3" ;;
  esac
  log '[+] Compactação concluída; iniciando criptografia...'
  printf '%s' "$GPG_PASSPHRASE" | gpg --batch --yes --pinentry-mode loopback --passphrase-fd 0 --symmetric --cipher-algo AES256 -o "$encrypted" "$archive"; rm -f -- "$archive"
  hash="$(sha256sum "$encrypted" | cut -d' ' -f1)"; printf '%s  %s\n' "$hash" "$(basename "$encrypted")" > "$encrypted.sha256"
  log '[+] Enviando e verificando o objeto remoto...'
  rclone copy "$encrypted" "$remote" --log-level ERROR; rclone copy "$encrypted.sha256" "$remote" --log-level ERROR
  mkdir -p "$RUNTIME_DIR/verify"; rclone copyto "$remote/$(basename "$encrypted")" "$RUNTIME_DIR/verify/$(basename "$encrypted")" --log-level ERROR
  printf '%s  %s\n' "$hash" "$RUNTIME_DIR/verify/$(basename "$encrypted")" | sha256sum -c - >/dev/null
  log '[+] Upload verificado; avaliando retenção...'
  retention="${RETENCAO_DIAS:-$DEFAULT_RETENTION_DAYS}"; [[ "$retention" =~ ^[0-9]+$ && "$retention" -ge 1 ]] || { failure "$service" "$BACKUP_TYPE" 'Retenção inválida'; return; }
  count="$(rclone lsf "$remote" --files-only --include '*.gpg' --log-level ERROR | sed '/^$/d' | wc -l)"
  if (( count > MINIMUM_REMOTE_BACKUPS )); then rclone delete "$remote" --min-age "${retention}d" --include '*.gpg' --include '*.gpg.sha256' --log-level ERROR; else log "[i] Retenção adiada: somente $count backup(s)."; fi
  duration=$(( $(date +%s)-started )); size="$(du -h "$encrypted" | cut -f1)"; record_log "$service" SUCESSO "[Arquivo: $(basename "$encrypted")] [Tamanho: $size] [Tempo: ${duration}s] [SHA256: $hash]"
  printf '| **%s** | :white_check_mark: SUCESSO | %s | %s | %ss | Upload verificado |\n' "$service" "$BACKUP_TYPE" "$size" "$duration" >> "$SUMMARY_FILE"; TOTAL_SUCCESS=$((TOTAL_SUCCESS+1))
}

main() {
  load_config "$PROJECT_DIR/.env" 'GPG_PASSPHRASE MATTERMOST_WEBHOOK_URL DEFAULT_RETENTION_DAYS MINIMUM_REMOTE_BACKUPS RCLONE_REMOTE_ROOT BACKUP_LOCK_FILE'
  REMOTE_ROOT="${RCLONE_REMOTE_ROOT:-$REMOTE_ROOT}"; LOCK_FILE="${BACKUP_LOCK_FILE:-$LOCK_FILE}"
  [[ -n "${GPG_PASSPHRASE:-}" ]] || { log '[-] GPG_PASSPHRASE não configurada'; return 1; }
  [[ "$DEFAULT_RETENTION_DAYS" =~ ^[0-9]+$ && "$DEFAULT_RETENTION_DAYS" -ge 1 ]] || { log '[-] DEFAULT_RETENTION_DAYS inválido'; return 1; }
  [[ "$MINIMUM_REMOTE_BACKUPS" =~ ^[0-9]+$ && "$MINIMUM_REMOTE_BACKUPS" -ge 1 ]] || { log '[-] MINIMUM_REMOTE_BACKUPS inválido'; return 1; }; require_tools
  exec 9>"$LOCK_FILE"; flock -n 9 || { log '[-] Outra rotina já está em execução'; return 75; }
  RUNTIME_DIR="$(mktemp -d /tmp/cdc-backup.XXXXXX)"; SUMMARY_FILE="$RUNTIME_DIR/summary.md"; printf '| Serviço | Status | Tipo | Tamanho | Tempo | Detalhes |\n| :--- | :---: | :---: | :---: | :---: | :--- |\n' > "$SUMMARY_FILE"
  local path found=false; for path in "$SERVICES_DIR"/*; do [[ -d "$path" ]] || continue; [[ -n "$FILTER_SERVICE" && "$(basename "$path")" != "$FILTER_SERVICE" ]] && continue; found=true; process_service "$path"; done
  [[ "$found" == true ]] || { log "[-] Serviço não encontrado: $FILTER_SERVICE"; return 64; }; notify; (( TOTAL_FAILURES == 0 )) || return 1; log '[+] Rotina finalizada sem falhas.'
}
main "$@"
