#!/usr/bin/env bash

# ==============================================================================
# SCRIPT DE BACKUP AUTOMATIZADO - ESTRATÉGIA 3-2-1
# ==============================================================================
# Diretivas estritas de tratamento de erro do Bash
set -Eeuo pipefail

# Variáveis globais obtidas do ambiente (.env)
TIMESTAMP=$(date +"%Y%m%d_%H%M%S")
BACKUP_DIR="/tmp/backups"
DB_HOST="${DB_HOST:-postgres-db}"
DB_USER="${DB_USER:-app_db_user}"
DB_NAME="${DB_NAME:-bkp_rclone_production}"
GPG_PASSPHRASE="${GPG_PASSPHRASE:-}"
RCLONE_DRIVE_FOLDER="${RCLONE_DRIVE_FOLDER:-backups_db_production}"
MATTERMOST_WEBHOOK_URL="${MATTERMOST_WEBHOOK_URL:-}"

# Nomes de arquivos
DUMP_FILE="${BACKUP_DIR}/dump_${DB_NAME}_${TIMESTAMP}.sql"
COMPRESSED_FILE="${DUMP_FILE}.tar.gz"
ENCRYPTED_FILE="${COMPRESSED_FILE}.gpg"
HASH_FILE="${ENCRYPTED_FILE}.sha256"

# Função executada em caso de falhas inesperadas
trap 'handle_error $LINENO' ERR

handle_error() {
  local line_num="$1"
  echo "[-] ERRO: Script falhou na linha ${line_num}"
  
  # Envia alerta crítico de falha ao Mattermost se a URL estiver configurada
  if [[ -n "${MATTERMOST_WEBHOOK_URL}" ]]; then
    curl -s -X POST -H 'Content-Type: application/json' \
    -d "{
      \"username\": \"Notificador de Backup\",
      \"text\": \"### :x: **FALHA NO BACKUP DIÁRIO**\n* **Ambiente:** Produção\n* **Falha detectada na linha:** ${line_num}\n* **Ação Requerida:** Verifique imediatamente o status do banco e o espaço em disco do servidor.\"
    }" "${MATTERMOST_WEBHOOK_URL}" > /dev/null
  fi
  exit 1
}

# Inicialização e preparação
mkdir -p "${BACKUP_DIR}"

echo "[+] Iniciando dump do banco de dados ${DB_NAME}..."
# Define PGPASSWORD temporariamente no subshell para autenticação segura
PGPASSWORD="${DB_PASSWORD}" pg_dump -h "${DB_HOST}" -U "${DB_USER}" -d "${DB_NAME}" -F p -f "${DUMP_FILE}"

echo "[+] Compactando o arquivo de dump..."
tar -czf "${COMPRESSED_FILE}" -C "${BACKUP_DIR}" "$(basename "${DUMP_FILE}")"
rm -f "${DUMP_FILE}"

echo "[+] Criptografando o arquivo compactado..."
if [[ -z "${GPG_PASSPHRASE}" ]]; then
  echo "[-] ERRO: Variável GPG_PASSPHRASE não está definida."
  exit 1
fi
gpg --batch --yes --passphrase "${GPG_PASSPHRASE}" --symmetric --cipher-algo AES256 -o "${ENCRYPTED_FILE}" "${COMPRESSED_FILE}"
rm -f "${COMPRESSED_FILE}"

echo "[+] Gerando assinatura SHA-256..."
sha256sum "${ENCRYPTED_FILE}" > "${HASH_FILE}"

echo "[+] Enviando arquivos ao Google Drive via Rclone..."
rclone copy "${ENCRYPTED_FILE}" "gdrive:${RCLONE_DRIVE_FOLDER}"
rclone copy "${HASH_FILE}" "gdrive:${RCLONE_DRIVE_FOLDER}"

# Limpeza local de temporários
rm -f "${ENCRYPTED_FILE}"
rm -f "${HASH_FILE}"

echo "[+] Backup concluído e enviado offsite com sucesso!"

# Envia notificação de sucesso ao Mattermost
if [[ -n "${MATTERMOST_WEBHOOK_URL}" ]]; then
  FILE_SIZE=$(rclone size "gdrive:${RCLONE_DRIVE_FOLDER}/$(basename "${ENCRYPTED_FILE}")" --json | grep -oP '"bytes":\s*\K\d+' || echo "desconhecido")
  curl -s -X POST -H 'Content-Type: application/json' \
  -d "{
    \"username\": \"Notificador de Backup\",
    \"text\": \"### :white_check_mark: **BACKUP DIÁRIO EXECUTADO**\n* **Ambiente:** Produção\n* **Status:** Sucesso e Sincronizado Offsite\n* **Arquivo:** \`$(basename "${ENCRYPTED_FILE}")\`\n* **Tamanho do Arquivo:** ${FILE_SIZE} bytes\n* **Destino:** Google Drive /${RCLONE_DRIVE_FOLDER}\n* **Integridade:** Checksum SHA-256 gravado na nuvem.\"
  }" "${MATTERMOST_WEBHOOK_URL}" > /dev/null
fi
