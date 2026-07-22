#!/usr/bin/env bash

# ==============================================================================
# MOTOR DE BACKUP AUTOMATIZADO E CRIPTOGRAFADO (GITOPS) - COM RELATÓRIO CONSOLIDADO
# ==============================================================================
# Diretivas estritas de tratamento de erro do Bash
set -Eeuo pipefail

# Variáveis globais obtidas dinamicamente
TIMESTAMP=$(date +"%Y%m%d_%H%M%S")
PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
FILTER_SERVICE="${1:-}"
SERVICES_DIR="${PROJECT_DIR}/services"
LOCAL_TMP_DIR="/tmp/backups_runtime"

# Carrega as variáveis do arquivo .env local se ele existir
if [[ -f "${PROJECT_DIR}/.env" ]]; then
  set -a
  source "${PROJECT_DIR}/.env"
  set +a
fi

# Parâmetros de Criptografia, Notificação e Retenção Global (vindos do .env da VPS)
GPG_PASSPHRASE="${GPG_PASSPHRASE:-}"
MATTERMOST_WEBHOOK_URL="${MATTERMOST_WEBHOOK_URL:-}"
DEFAULT_RETENTION_DAYS="${DEFAULT_RETENTION_DAYS:-15}"

# Inicialização e preparação
mkdir -p "${LOCAL_TMP_DIR}"

# Arquivo temporário para acumular o relatório consolidado
SUMMARY_FILE=$(mktemp)
echo "| Serviço | Status | Tipo | Tamanho | Tempo | Detalhes |" > "${SUMMARY_FILE}"
echo "| :--- | :---: | :---: | :---: | :---: | :--- |" >> "${SUMMARY_FILE}"

# Sinalizadores de status geral para o relatório consolidado
TOTAL_SERVICES_BACKED_UP=0
TOTAL_FAILURES=0

echo "[+] ======================================================================"
echo "[+] INICIANDO ROTINA DA CENTRAL DE BACKUP: $(date)"
echo "[+] ======================================================================"

# Função para registrar logs no arquivo logs.txt (Local e Google Drive)
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
  
  # Adiciona a nova linha no topo do arquivo de logs local (incremental)
  local temp_log=$(mktemp)
  echo "${log_line}" > "${temp_log}"
  cat "${log_file}" >> "${temp_log}"
  mv "${temp_log}" "${log_file}"

  # Envia o log atualizado para o Google Drive
  rclone copy "${log_file}" "gdrive:Central de BKP/${servico}/"
}

# Varre todas as pastas de serviços declaradas no Git
for service_path in "${SERVICES_DIR}"/*; do
  if [[ ! -d "${service_path}" ]]; then
    continue
  fi

  SERVICE_NAME=$(basename "${service_path}")
  
  # Permite executar e testar apenas um serviço específico
  if [[ -n "${FILTER_SERVICE}" ]] && [[ "${SERVICE_NAME}" != "${FILTER_SERVICE}" ]]; then
    continue
  fi

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
  set +u
  source "${CONFIG_FILE}"
  set -u

  # Validação de Criptografia
  if [[ -z "${GPG_PASSPHRASE}" ]]; then
    err_msg="GPG_PASSPHRASE não configurada no servidor"
    echo "[-] ERRO: ${err_msg}"
    registrar_log "${SERVICE_NAME}" "FALHA" "BACKUP_RUN" "${err_msg}"
    echo "| **${SERVICE_NAME}** | :x: FALHA | ${BACKUP_TYPE:-?} | - | - | ${err_msg} |" >> "${SUMMARY_FILE}"
    TOTAL_FAILURES=$((TOTAL_FAILURES + 1))
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
      
      set +u
      if [[ -z "${DB_USER:-}" ]]; then
        DB_USER=$(docker inspect --format='{{range .Config.Env}}{{println .}}{{end}}' "${DB_CONTAINER}" | grep -iE 'POSTGRES_USER|PGUSER' | head -n1 | cut -d= -f2 || echo "postgres")
      fi
      if [[ -z "${DB_NAME:-}" ]]; then
        DB_NAME=$(docker inspect --format='{{range .Config.Env}}{{println .}}{{end}}' "${DB_CONTAINER}" | grep -iE 'POSTGRES_DB|PGDATABASE' | head -n1 | cut -d= -f2 || echo "postgres")
      fi
      set -u

      # Busca a senha dinamicamente do container
      DB_PASSWORD=$(docker inspect --format='{{range .Config.Env}}{{println .}}{{end}}' "${DB_CONTAINER}" | grep -iE 'POSTGRES_PASSWORD|PGPASSWORD' | head -n1 | cut -d= -f2 || echo "")
      
      # Redireciona stdout para o arquivo de dump e stderr para capturar o erro exato
      if [[ -n "${DB_PASSWORD}" ]]; then
        if ! docker exec -i -e PGPASSWORD="${DB_PASSWORD}" "${DB_CONTAINER}" pg_dump -U "${DB_USER}" -d "${DB_NAME}" -F p > "${DUMP_FILE}.sql" 2>/tmp/db_err.txt; then
          DUMP_SUCCESS=false
          ERROR_MSG=$(cat /tmp/db_err.txt || echo "Erro desconhecido pg_dump")
        fi
      else
        if ! docker exec -i "${DB_CONTAINER}" pg_dump -U "${DB_USER}" -d "${DB_NAME}" -F p > "${DUMP_FILE}.sql" 2>/tmp/db_err.txt; then
          DUMP_SUCCESS=false
          ERROR_MSG=$(cat /tmp/db_err.txt || echo "Erro desconhecido pg_dump")
        fi
      fi
      ;;

    mysql|mariadb)
      echo "[+] Executando dump MySQL/MariaDB para: ${SERVICE_NAME}..."
      
      set +u
      if [[ -z "${DB_USER:-}" ]]; then
        DB_USER=$(docker inspect --format='{{range .Config.Env}}{{println .}}{{end}}' "${DB_CONTAINER}" | grep -iE 'MYSQL_USER' | head -n1 | cut -d= -f2 || echo "root")
      fi
      if [[ -z "${DB_NAME:-}" ]]; then
        DB_NAME=$(docker inspect --format='{{range .Config.Env}}{{println .}}{{end}}' "${DB_CONTAINER}" | grep -iE 'MYSQL_DATABASE' | head -n1 | cut -d= -f2 || echo "")
      fi
      set -u

      # Busca a senha do container
      DB_PASSWORD=$(docker inspect --format='{{range .Config.Env}}{{println .}}{{end}}' "${DB_CONTAINER}" | grep -iE 'MYSQL_ROOT_PASSWORD|MYSQL_PASSWORD' | head -n1 | cut -d= -f2 || echo "")
      
      # Redireciona stderr para capturar falha exata
      if [[ -n "${DB_PASSWORD}" ]]; then
        if ! docker exec -i "${DB_CONTAINER}" mysqldump -u "${DB_USER}" -p"${DB_PASSWORD}" "${DB_NAME}" > "${DUMP_FILE}.sql" 2>/tmp/db_err.txt; then
          DUMP_SUCCESS=false
          ERROR_MSG=$(cat /tmp/db_err.txt || echo "Erro desconhecido mysqldump")
        fi
      else
        if ! docker exec -i "${DB_CONTAINER}" mysqldump -u "${DB_USER}" "${DB_NAME}" > "${DUMP_FILE}.sql" 2>/tmp/db_err.txt; then
          DUMP_SUCCESS=false
          ERROR_MSG=$(cat /tmp/db_err.txt || echo "Erro desconhecido mysqldump")
        fi
      fi
      ;;

    sqlite)
      echo "[+] Copiando base SQLite para: ${SERVICE_NAME}..."
      set +u
      if [[ -n "${SOURCE_PATH}" ]] && [[ -f "${SOURCE_PATH}" ]]; then
        cp "${SOURCE_PATH}" "${DUMP_FILE}.db"
      else
        DUMP_SUCCESS=false
        ERROR_MSG="Arquivo SQLite em '${SOURCE_PATH:-}' nao encontrado."
      fi
      set -u
      ;;

    files)
      echo "[+] Preparando backup de arquivos para: ${SERVICE_NAME}..."
      set +u
      if [[ ! -d "${SOURCE_PATH}" ]] && [[ ! -f "${SOURCE_PATH}" ]]; then
        DUMP_SUCCESS=false
        ERROR_MSG="Origem '${SOURCE_PATH:-}' nao existe."
      fi
      set -u
      ;;

    *)
      DUMP_SUCCESS=false
      ERROR_MSG="Tipo de backup '${BACKUP_TYPE}' desconhecido."
      ;;
  esac

  # Se o dump falhou, registra na tabela do resumo e avança
  if [[ "${DUMP_SUCCESS}" == "false" ]]; then
    # Higieniza a mensagem de erro para caber em uma linha de tabela sem quebrar o Markdown
    clean_err=$(echo "${ERROR_MSG}" | tr '\n' ' ' | tr '|' '-')
    echo "[-] FALHA ao gerar backup do serviço ${SERVICE_NAME}: ${clean_err}"
    registrar_log "${SERVICE_NAME}" "FALHA" "BACKUP_RUN" "${clean_err}"
    echo "| **${SERVICE_NAME}** | :x: FALHA | ${BACKUP_TYPE} | - | - | ${clean_err} |" >> "${SUMMARY_FILE}"
    TOTAL_FAILURES=$((TOTAL_FAILURES + 1))
    rm -rf "${DUMP_FILE}"*
    continue
  fi

  # 5. COMPACTAÇÃO E CRIPTOGRAFIA
  echo "[+] Compactando os dados..."
  set +u
  if [[ "${BACKUP_TYPE}" == "files" ]]; then
    tar -czf "${COMPRESSED_FILE}" -C "$(dirname "${SOURCE_PATH}")" "$(basename "${SOURCE_PATH}")"
  elif [[ "${BACKUP_TYPE}" == "sqlite" ]]; then
    tar -czf "${COMPRESSED_FILE}" -C "${LOCAL_TMP_DIR}" "$(basename "${DUMP_FILE}").db"
    rm -f "${DUMP_FILE}.db"
  else
    # Mapeamento do arquivo de dump PostgreSQL/MySQL exato sem curingas (resolve bug de globbing)
    tar -czf "${COMPRESSED_FILE}" -C "${LOCAL_TMP_DIR}" "$(basename "${DUMP_FILE}").sql"
    rm -f "${DUMP_FILE}.sql"
  fi
  set -u

  echo "[+] Criptografando com GPG (AES-256)..."
  gpg --batch --yes --passphrase "${GPG_PASSPHRASE}" --symmetric --cipher-algo AES256 -o "${ENCRYPTED_FILE}" "${COMPRESSED_FILE}"
  rm -f "${COMPRESSED_FILE}"

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

  # 8. REGISTRO DE SUCESSO NO RESUMO E LOGS
  LOG_DETAIL="[Método: ${BACKUP_TYPE}+tar+gpg_AES256] [Arquivo: $(basename "${ENCRYPTED_FILE}")] [Tamanho: ${METRIC_SIZE}] [Tempo: ${METRIC_DURATION}s] [SHA256: ${METRIC_HASH}]"
  registrar_log "${SERVICE_NAME}" "SUCESSO" "BACKUP_DB" "${LOG_DETAIL}"
  
  echo "| **${SERVICE_NAME}** | :white_check_mark: SUCESSO | ${BACKUP_TYPE} | ${METRIC_SIZE} | ${METRIC_DURATION}s | Backup finalizado |" >> "${SUMMARY_FILE}"
  TOTAL_SERVICES_BACKED_UP=$((TOTAL_SERVICES_BACKED_UP + 1))

  echo "[+] Serviço ${SERVICE_NAME} processado com sucesso!"
done

# Limpeza final do diretório temporário
rm -rf "${LOCAL_TMP_DIR}"

echo "[+] ======================================================================"
echo "[+] ENVIANDO NOTIFICAÇÃO CONSOLIDADA AO MATTERMOST: $(date)"
echo "[+] ======================================================================"

# 9. DISPARO DO WEBHOOK CONSOLIDADO AO MATTERMOST
if [[ -n "${MATTERMOST_WEBHOOK_URL}" ]]; then
  STATUS_GERAL="### :white_check_mark: **Relatório Geral de Backups - CDC (Sucesso)**"
  if [[ ${TOTAL_FAILURES} -gt 0 ]]; then
    STATUS_GERAL="### :warning: **Relatório Geral de Backups - CDC (Concluído com Alertas)**"
  fi

  # Concatena a tabela acumulada no corpo da mensagem
  TABELA_MARKDOWN=$(cat "${SUMMARY_FILE}")
  
  # Cria o JSON payload de forma higienizada
  PAYLOAD_JSON=$(cat <<EOF
{
  "username": "Central de Backup",
  "icon_url": "https://mattermost.com/wp-content/uploads/2022/02/icon.png",
  "text": "${STATUS_GERAL}\n\n* **Host:** $(hostname)\n* **Data:** $(date)\n* **Serviços com Sucesso:** ${TOTAL_SERVICES_BACKED_UP}\n* **Serviços com Falha:** ${TOTAL_FAILURES}\n\n${TABELA_MARKDOWN}"
}
EOF
)

  # Dispara o webhook consolidado
  curl -s -X POST -H 'Content-Type: application/json' -d "${PAYLOAD_JSON}" "${MATTERMOST_WEBHOOK_URL}" > /dev/null
fi

rm -f "${SUMMARY_FILE}"
echo "[+] Rotina finalizada com sucesso."
