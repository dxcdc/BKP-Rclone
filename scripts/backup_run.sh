#!/usr/bin/env bash

# ==============================================================================
# MOTOR DE BACKUP AUTOMATIZADO E CRIPTOGRAFADO (GITOPS)
# ==============================================================================
# Diretivas estritas de tratamento de erro do Bash
set -Eeuo pipefail

# Variáveis globais obtidas dinamicamente baseadas na localização do script
TIMESTAMP=$(date +"%Y%m%d_%H%M%S")
PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SERVICES_DIR="${PROJECT_DIR}/services"
LOCAL_TMP_DIR="/tmp/backups_runtime"

# Carrega as variáveis do arquivo .env local do projeto se ele existir
if [[ -f "${PROJECT_DIR}/.env" ]]; then
  # set -a garante que as variáveis do .env sejam exportadas para os subprocessos (docker, gpg, rclone)
  set -a
  source "${PROJECT_DIR}/.env"
  set +a
fi

# Parâmetros de Criptografia, Notificação e Retenção Global (vindos do .env da VPS)
GPG_PASSPHRASE="${GPG_PASSPHRASE:-}"
MATTERMOST_WEBHOOK_URL="${MATTERMOST_WEBHOOK_URL:-}"
DEFAULT_RETENTION_DAYS="${DEFAULT_RETENTION_DAYS:-15}" # Padrão global: 15 dias

# Inicialização do diretório temporário local
mkdir -p "${LOCAL_TMP_DIR}"

echo "[+] ======================================================================"
echo "[+] INICIANDO ROTINA DA CENTRAL DE BACKUP: $(date)"
echo "[+] ======================================================================"

# Função para registrar logs no formato objetivo (responde às 7 perguntas)
registrar_log() {
  local servico="$1"
  local status="$2"
  local op="$3"
  local extra_info="$4"
  local log_file="${SERVICES_DIR}/${servico}/logs.txt"
  
  local timestamp=$(date +"%Y-%m-%d %H:%M:%S %Z")
  local host=$(hostname)
  local log_line=""

  if [[ "${status}" == "SUCESSO" ]]; then
    log_line="[${timestamp}] [SUCESSO] [Host: ${host}] [Serviço: ${servico}] [Op: ${op}] ${extra_info}"
  else
    log_line="[${timestamp}] [FALHA] [Host: ${host}] [Serviço: ${servico}] [Op: ${op}] [Erro: ${extra_info}]"
  fi

  # Garante que o arquivo existe
  touch "${log_file}"
  
  # Adiciona a nova linha no topo do arquivo de logs local (preservação histórica incremental)
  local temp_log=$(mktemp)
  echo "${log_line}" > "${temp_log}"
  cat "${log_file}" >> "${temp_log}"
  mv "${temp_log}" "${log_file}"

  # Envia o log atualizado para o Google Drive
  rclone copy "${log_file}" "gdrive:Central de BKP/${servico}/"
}

# Função para enviar alertas ao Mattermost
enviar_alerta_mattermost() {
  local servico="$1"
  local status="$2"
  local msg="$3"
  
  if [[ -z "${MATTERMOST_WEBHOOK_URL}" ]]; then
    return 0
  fi

  local icon=":white_check_mark:"
  local title="SUCESSO NO BACKUP"
  if [[ "${status}" == "FALHA" ]]; then
    icon=":x:"
    title="FALHA NO BACKUP"
  fi

  curl -s -X POST -H 'Content-Type: application/json' \
  -d "{
    \"username\": \"Central de Backup\",
    \"text\": \"### ${icon} **${title}**\n* **Serviço:** ${servico}\n* **Detalhes:** ${msg}\n* **Host:** $(hostname)\n* **Data:** $(date)\"
  }" "${MATTERMOST_WEBHOOK_URL}" > /dev/null
}

# Varre todas as pastas de serviços declaradas no Git
for service_path in "${SERVICES_DIR}"/*; do
  if [[ ! -d "${service_path}" ]]; then
    continue
  fi

  SERVICE_NAME=$(basename "${service_path}")
  INFO_FILE="${service_path}/info.txt"
  CONFIG_FILE="${service_path}/backup.conf"

  echo "[+] Processando serviço: ${SERVICE_NAME}..."

  # 1. VALIDAÇÃO BIDIRECIONAL: Garante que a estrutura básica e o info.txt existam no Drive
  if ! rclone size "gdrive:Central de BKP/${SERVICE_NAME}/info.txt" &>/dev/null; then
    echo "[+] Pasta ou info.txt ausente no Drive. Criando e subindo metadados..."
    rclone mkdir "gdrive:Central de BKP/${SERVICE_NAME}/db"
    rclone mkdir "gdrive:Central de BKP/${SERVICE_NAME}/files"
    if [[ -f "${INFO_FILE}" ]]; then
      rclone copy "${INFO_FILE}" "gdrive:Central de BKP/${SERVICE_NAME}/"
    fi
  fi

  # 2. VERIFICA SE O BACKUP ESTÁ ATIVO (Verifica se backup.conf existe)
  if [[ ! -f "${CONFIG_FILE}" ]]; then
    echo "[i] Serviço '${SERVICE_NAME}' está mapeado, mas sem backup configurado (backup.conf ausente). Pulando..."
    continue
  fi

  # Reset de variáveis específicas de serviço para evitar contaminação entre loops
  set +u
  unset BACKUP_TYPE DB_CONTAINER DB_USER DB_NAME SOURCE_PATH RETENCAO_DIAS
  set -u

  # 3. LÊ AS CONFIGURAÇÕES DO SERVIÇO
  # Carrega as variáveis do arquivo backup.conf de forma segura
  set +u
  source "${CONFIG_FILE}"
  set -u

  # Validação de Criptografia
  if [[ -z "${GPG_PASSPHRASE}" ]]; then
    echo "[-] ERRO: Variável GPG_PASSPHRASE não está definida no ambiente da VPS."
    registrar_log "${SERVICE_NAME}" "FALHA" "BACKUP_RUN" "GPG_PASSPHRASE não configurada no host"
    enviar_alerta_mattermost "${SERVICE_NAME}" "FALHA" "GPG_PASSPHRASE não configurada no servidor."
    continue
  fi

  # Nomes dos arquivos temporários locais
  DUMP_FILE="${LOCAL_TMP_DIR}/dump_${SERVICE_NAME}_${TIMESTAMP}"
  COMPRESSED_FILE="${DUMP_FILE}.tar.gz"
  ENCRYPTED_FILE="${COMPRESSED_FILE}.gpg"

  # 4. EXECUÇÃO DO DUMP CONFORME O TIPO
  DUMP_SUCCESS=true
  ERROR_MSG=""
  METRIC_SIZE="0"
  METRIC_DURATION="0"
  METRIC_HASH=""

  START_TIME=$(date +%s)

  case "${BACKUP_TYPE}" in
    postgres)
      echo "[+] Executando dump PostgreSQL para: ${SERVICE_NAME}..."
      
      # Auto-extração inteligente de variáveis do container caso não informadas no backup.conf
      set +u
      if [[ -z "${DB_USER:-}" ]]; then
        DB_USER=$(docker inspect --format='{{range .Config.Env}}{{println .}}{{end}}' "${DB_CONTAINER}" | grep -iE 'POSTGRES_USER|PGUSER' | head -n1 | cut -d= -f2 || echo "postgres")
      fi
      if [[ -z "${DB_NAME:-}" ]]; then
        DB_NAME=$(docker inspect --format='{{range .Config.Env}}{{println .}}{{end}}' "${DB_CONTAINER}" | grep -iE 'POSTGRES_DB|PGDATABASE' | head -n1 | cut -d= -f2 || echo "postgres")
      fi
      set -u

      # Busca a senha dinamicamente do container para evitar salvá-la no Git
      DB_PASSWORD=$(docker inspect --format='{{range .Config.Env}}{{println .}}{{end}}' "${DB_CONTAINER}" | grep -iE 'POSTGRES_PASSWORD|PGPASSWORD' | head -n1 | cut -d= -f2 || echo "")
      
      if [[ -n "${DB_PASSWORD}" ]]; then
        if ! docker exec -i -e PGPASSWORD="${DB_PASSWORD}" "${DB_CONTAINER}" pg_dump -U "${DB_USER}" -d "${DB_NAME}" -F p > "${DUMP_FILE}.sql" 2>/tmp/db_err.txt; then
          DUMP_SUCCESS=false
          ERROR_MSG=$(cat /tmp/db_err.txt)
        fi
      else
        # Tenta sem senha caso seja trust local
        if ! docker exec -i "${DB_CONTAINER}" pg_dump -U "${DB_USER}" -d "${DB_NAME}" -F p > "${DUMP_FILE}.sql" 2>/tmp/db_err.txt; then
          DUMP_SUCCESS=false
          ERROR_MSG=$(cat /tmp/db_err.txt)
        fi
      fi
      ;;

    mysql|mariadb)
      echo "[+] Executando dump MySQL/MariaDB para: ${SERVICE_NAME}..."
      
      # Auto-extração inteligente de variáveis do container
      set +u
      if [[ -z "${DB_USER:-}" ]]; then
        DB_USER=$(docker inspect --format='{{range .Config.Env}}{{println .}}{{end}}' "${DB_CONTAINER}" | grep -iE 'MYSQL_USER' | head -n1 | cut -d= -f2 || echo "root")
      fi
      if [[ -z "${DB_NAME:-}" ]]; then
        DB_NAME=$(docker inspect --format='{{range .Config.Env}}{{println .}}{{end}}' "${DB_CONTAINER}" | grep -iE 'MYSQL_DATABASE' | head -n1 | cut -d= -f2 || echo "")
      fi
      set -u

      # Busca a senha de root ou de usuário do container
      DB_PASSWORD=$(docker inspect --format='{{range .Config.Env}}{{println .}}{{end}}' "${DB_CONTAINER}" | grep -iE 'MYSQL_ROOT_PASSWORD|MYSQL_PASSWORD' | head -n1 | cut -d= -f2 || echo "")
      
      if [[ -n "${DB_PASSWORD}" ]]; then
        if ! docker exec -i "${DB_CONTAINER}" mysqldump -u "${DB_USER}" -p"${DB_PASSWORD}" "${DB_NAME}" > "${DUMP_FILE}.sql" 2>/tmp/db_err.txt; then
          DUMP_SUCCESS=false
          ERROR_MSG=$(cat /tmp/db_err.txt)
        fi
      else
        if ! docker exec -i "${DB_CONTAINER}" mysqldump -u "${DB_USER}" "${DB_NAME}" > "${DUMP_FILE}.sql" 2>/tmp/db_err.txt; then
          DUMP_SUCCESS=false
          ERROR_MSG=$(cat /tmp/db_err.txt)
        fi
      fi
      ;;

    sqlite)
      echo "[+] Copiando base SQLite para: ${SERVICE_NAME}..."
      # SQLite é arquivo, então apenas copiamos o arquivo de banco
      set +u
      if [[ -n "${SOURCE_PATH}" ]] && [[ -f "${SOURCE_PATH}" ]]; then
        cp "${SOURCE_PATH}" "${DUMP_FILE}.db"
      else
        DUMP_SUCCESS=false
        ERROR_MSG="Arquivo SQLite em '${SOURCE_PATH:-}' não encontrado."
      fi
      set -u
      ;;

    files)
      echo "[+] Preparando backup de arquivos para: ${SERVICE_NAME}..."
      # Apenas define sucesso, a compactação tar.gz fará o trabalho direto
      set +u
      if [[ ! -d "${SOURCE_PATH}" ]] && [[ ! -f "${SOURCE_PATH}" ]]; then
        DUMP_SUCCESS=false
        ERROR_MSG="Diretório/Arquivo de origem '${SOURCE_PATH:-}' não existe."
      fi
      set -u
      ;;

    *)
      DUMP_SUCCESS=false
      ERROR_MSG="Tipo de backup '${BACKUP_TYPE}' desconhecido."
      ;;
  esac

  # Se o dump falhou, registra e vai para o próximo
  if [[ "${DUMP_SUCCESS}" == "false" ]]; then
    echo "[-] FALHA ao gerar backup do serviço ${SERVICE_NAME}: ${ERROR_MSG}"
    registrar_log "${SERVICE_NAME}" "FALHA" "BACKUP_RUN" "${ERROR_MSG}"
    enviar_alerta_mattermost "${SERVICE_NAME}" "FALHA" "Falha na extração de dados: ${ERROR_MSG}"
    rm -rf "${DUMP_FILE}"*
    continue
  fi

  # 5. COMPACTAÇÃO E CRIPTOGRAFIA
  echo "[+] Compactando os dados..."
  set +u
  if [[ "${BACKUP_TYPE}" == "files" ]]; then
    # Para arquivos físicos, compactamos a pasta de origem direto
    tar -czf "${COMPRESSED_FILE}" -C "$(dirname "${SOURCE_PATH}")" "$(basename "${SOURCE_PATH}")"
  else
    # Para dumps de banco, compactamos o dump gerado
    tar -czf "${COMPRESSED_FILE}" -C "${LOCAL_TMP_DIR}" "$(basename "${DUMP_FILE}")"*
    rm -f "${DUMP_FILE}"*
  fi
  set -u

  echo "[+] Criptografando com GPG (AES-256)..."
  gpg --batch --yes --passphrase "${GPG_PASSPHRASE}" --symmetric --cipher-algo AES256 -o "${ENCRYPTED_FILE}" "${COMPRESSED_FILE}"
  rm -f "${COMPRESSED_FILE}"

  # Gera a assinatura de integridade SHA-256
  METRIC_HASH=$(sha256sum "${ENCRYPTED_FILE}" | cut -d' ' -f1)
  sha256sum "${ENCRYPTED_FILE}" > "${ENCRYPTED_FILE}.sha256"

  # 6. ENVIO OFFSITE (GOOGLE DRIVE)
  echo "[+] Enviando arquivos ao Google Drive..."
  TARGET_SUBDIR="db"
  if [[ "${BACKUP_TYPE}" == "files" ]]; then
    TARGET_SUBDIR="files"
  fi

  rclone copy "${ENCRYPTED_FILE}" "gdrive:Central de BKP/${SERVICE_NAME}/${TARGET_SUBDIR}"
  rclone copy "${ENCRYPTED_FILE}.sha256" "gdrive:Central de BKP/${SERVICE_NAME}/${TARGET_SUBDIR}"

  # 7. LIMPEZA AUTOMÁTICA DE BACKUPS ANTIGOS (RETENÇÃO)
  set +u
  RETENTION_DAYS="${RETENCAO_DIAS:-${DEFAULT_RETENTION_DAYS}}"
  set -u
  echo "[+] Aplicando política de retenção: mantendo apenas os últimos ${RETENTION_DAYS} dias..."
  rclone delete --min-age "${RETENTION_DAYS}d" "gdrive:Central de BKP/${SERVICE_NAME}/${TARGET_SUBDIR}/"

  # Métricas finais
  END_TIME=$(date +%s)
  METRIC_DURATION=$((END_TIME - START_TIME))
  METRIC_SIZE=$(du -sh "${ENCRYPTED_FILE}" | cut -f1)

  # Limpeza dos arquivos locais temporários
  rm -f "${ENCRYPTED_FILE}"
  rm -f "${ENCRYPTED_FILE}.sha256"

  # 8. REGISTRO DE SUCESSO E ALERTAS
  LOG_DETAIL="[Método: ${BACKUP_TYPE}+tar+gpg_AES256] [Arquivo: $(basename "${ENCRYPTED_FILE}")] [Tamanho: ${METRIC_SIZE}] [Tempo: ${METRIC_DURATION}s] [SHA256: ${METRIC_HASH}]"
  registrar_log "${SERVICE_NAME}" "SUCESSO" "BACKUP_DB" "${LOG_DETAIL}"
  enviar_alerta_mattermost "${SERVICE_NAME}" "SUCESSO" "Backup realizado e enviado com sucesso. Tamanho: ${METRIC_SIZE}. Tempo: ${METRIC_DURATION}s."

  echo "[+] Serviço ${SERVICE_NAME} processado com sucesso!"
done

# Limpeza final do diretório temporário
rm -rf "${LOCAL_TMP_DIR}"
echo "[+] ======================================================================"
echo "[+] FIM DA ROTINA DA CENTRAL DE BACKUP: $(date)"
echo "[+] ======================================================================"
