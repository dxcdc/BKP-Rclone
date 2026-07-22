#!/usr/bin/env bash

# ==============================================================================
# MOTOR DE BACKUP AUTOMATIZADO E CRIPTOGRAFADO (GITOPS) - COM FILTROS E BOTÕES
# ==============================================================================
# Diretivas estritas de tratamento de erro do Bash
set -Eeuo pipefail

# Variáveis globais obtidas dinamicamente
TIMESTAMP=$(date +"%Y%m%d_%H%M%S")
TODAY_DATE=$(date +"%Y%m%d")
PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SERVICES_DIR="${PROJECT_DIR}/services"
LOCAL_TMP_DIR="/tmp/backups_runtime"

# Carrega as variáveis do arquivo .env local se ele existir
if [[ -f "${PROJECT_DIR}/.env" ]]; then
  set -a
  source "${PROJECT_DIR}/.env"
  set +a
fi

# Parâmetros de Criptografia, Notificação e Retenção (vindos do .env)
GPG_PASSPHRASE="${GPG_PASSPHRASE:-}"
MATTERMOST_WEBHOOK_URL="${MATTERMOST_WEBHOOK_URL:-}"
DEFAULT_RETENTION_DAYS="${DEFAULT_RETENTION_DAYS:-15}"
N8N_WEBHOOK_URL="${N8N_WEBHOOK_URL:-}" # URL do n8n para receber cliques do botão

# Argumentos passados ao script
# $1: Nome do serviço específico (opcional)
# $2: Ação ("force" para forçar mesmo se hoje já tiver backup)
FILTER_SERVICE="${1:-}"
FORCE_ACTION="${2:-}"

# Inicialização e preparação
mkdir -p "${LOCAL_TMP_DIR}"

# Arquivo temporário para acumular o relatório consolidado
SUMMARY_FILE=$(mktemp)
echo "| Serviço | Status | Tipo | Tamanho | Tempo | Detalhes |" > "${SUMMARY_FILE}"
echo "| :--- | :---: | :---: | :---: | :---: | :--- |" >> "${SUMMARY_FILE}"

# Estatísticas
TOTAL_SERVICES_BACKED_UP=0
TOTAL_FAILURES=0
TOTAL_SKIPPED=0

echo "[+] ======================================================================"
echo "[+] INICIANDO ROTINA DA CENTRAL DE BACKUP: $(date)"
echo "[+] ======================================================================"

# Função para registrar logs
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
  elif [[ "${status}" == "PULADO" ]]; then
    log_line="[${timestamp}] [PULADO] [Host: ${host}] [Serviço: ${servico}] [Op: ${op}] ${extra_info}"
  else
    log_line="[${timestamp}] [FALHA] [Host: ${host}] [Serviço: ${servico}] [Op: ${op}] [Erro: ${extra_info}]"
  fi

  touch "${log_file}"
  local temp_log=$(mktemp)
  echo "${log_line}" > "${temp_log}"
  cat "${log_file}" >> "${temp_log}"
  mv "${temp_log}" "${log_file}"

  rclone copy "${log_file}" "gdrive:Central de BKP/${servico}/"
}

# Varre as pastas no Git
for service_path in "${SERVICES_DIR}"/*; do
  if [[ ! -d "${service_path}" ]]; then
    continue
  fi

  SERVICE_NAME=$(basename "${service_path}")
  
  # Filtro de serviço
  if [[ -n "${FILTER_SERVICE}" ]] && [[ "${SERVICE_NAME}" != "${FILTER_SERVICE}" ]]; then
    continue
  fi

  INFO_FILE="${service_path}/info.txt"
  CONFIG_FILE="${service_path}/backup.conf"

  echo "[+] Processando serviço: ${SERVICE_NAME}..."

  # 1. VALIDAÇÃO BIDIRECIONAL
  if ! rclone size "gdrive:Central de BKP/${SERVICE_NAME}/info.txt" &>/dev/null; then
    echo "[+] Pasta ou info.txt ausente no Drive. Criando..."
    rclone mkdir "gdrive:Central de BKP/${SERVICE_NAME}/db"
    rclone mkdir "gdrive:Central de BKP/${SERVICE_NAME}/files"
    if [[ -f "${INFO_FILE}" ]]; then
      rclone copy "${INFO_FILE}" "gdrive:Central de BKP/${SERVICE_NAME}/"
    fi
  fi

  # 2. VERIFICA SE O BACKUP ESTÁ ATIVO
  if [[ ! -f "${CONFIG_FILE}" ]]; then
    echo "[i] Serviço '${SERVICE_NAME}' mapeado, mas sem backup ativo. Pulando..."
    continue
  fi

  # Reset de variáveis
  set +u
  unset BACKUP_TYPE DB_CONTAINER DB_USER DB_NAME SOURCE_PATH RETENCAO_DIAS
  set -u

  # 3. LÊ AS CONFIGURAÇÕES
  set +u
  source "${CONFIG_FILE}"
  set -u

  TARGET_SUBDIR="db"
  if [[ "${BACKUP_TYPE}" == "files" ]]; then
    TARGET_SUBDIR="files"
  fi

  # 3.1 VERIFICAÇÃO DE DUPLICIDADE (SE JÁ FOI FEITO HOJE)
  # Só executa se a ação não for "force"
  if [[ "${FORCE_ACTION}" != "force" ]]; then
    echo "[+] Verificando se backup de hoje (${TODAY_DATE}) já existe no Google Drive..."
    # Lista arquivos no diretório de destino e procura pela data de hoje
    if rclone lsf "gdrive:Central de BKP/${SERVICE_NAME}/${TARGET_SUBDIR}/" 2>/dev/null | grep -E "${TODAY_DATE}" &>/dev/null; then
      msg_skip="Backup de hoje ja existe"
      echo "[i] PULADO: ${msg_skip} para ${SERVICE_NAME}."
      registrar_log "${SERVICE_NAME}" "PULADO" "BACKUP_RUN" "${msg_skip}"
      echo "| **${SERVICE_NAME}** | :double_vertical_bar: PULADO | ${BACKUP_TYPE} | - | - | ${msg_skip} |" >> "${SUMMARY_FILE}"
      TOTAL_SKIPPED=$((TOTAL_SKIPPED + 1))
      continue
    fi
  fi

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

  # 4. EXECUÇÃO DO DUMP
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

      DB_PASSWORD=$(docker inspect --format='{{range .Config.Env}}{{println .}}{{end}}' "${DB_CONTAINER}" | grep -iE 'POSTGRES_PASSWORD|PGPASSWORD' | head -n1 | cut -d= -f2 || echo "")
      
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

      DB_PASSWORD=$(docker inspect --format='{{range .Config.Env}}{{println .}}{{end}}' "${DB_CONTAINER}" | grep -iE 'MYSQL_ROOT_PASSWORD|MYSQL_PASSWORD' | head -n1 | cut -d= -f2 || echo "")
      
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

  if [[ "${DUMP_SUCCESS}" == "false" ]]; then
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

  rm -f "${ENCRYPTED_FILE}"
  rm -f "${ENCRYPTED_FILE}.sha256"

  # 8. REGISTRO DE SUCESSO
  LOG_DETAIL="[Método: ${BACKUP_TYPE}+tar+gpg_AES256] [Arquivo: $(basename "${ENCRYPTED_FILE}")] [Tamanho: ${METRIC_SIZE}] [Tempo: ${METRIC_DURATION}s] [SHA256: ${METRIC_HASH}]"
  registrar_log "${SERVICE_NAME}" "SUCESSO" "BACKUP_DB" "${LOG_DETAIL}"
  
  echo "| **${SERVICE_NAME}** | :white_check_mark: SUCESSO | ${BACKUP_TYPE} | ${METRIC_SIZE} | ${METRIC_DURATION}s | Backup finalizado |" >> "${SUMMARY_FILE}"
  TOTAL_SERVICES_BACKED_UP=$((TOTAL_SERVICES_BACKED_UP + 1))

  echo "[+] Serviço ${SERVICE_NAME} processado com sucesso!"
done

# Limpeza final
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

  TEXT_CONTENT=$(cat <<EOF
${STATUS_GERAL}

* **Host:** $(hostname)
* **Data:** $(date)
* **Serviços com Sucesso:** ${TOTAL_SERVICES_BACKED_UP}
* **Serviços com Falha:** ${TOTAL_FAILURES}
* **Serviços Pulados (Já feitos hoje):** ${TOTAL_SKIPPED}

$(cat "${SUMMARY_FILE}")
EOF
)

  JSON_TEXT=$(echo "${TEXT_CONTENT}" | sed ':a;N;$!ba;s/\n/\\n/g' | sed 's/"/\\"/g')
  
  # Monta o JSON incluindo anotação de anexo interativo se n8n estiver configurado
  if [[ -n "${N8N_WEBHOOK_URL}" ]]; then
    PAYLOAD_JSON=$(cat <<EOF
{
  "text": "${JSON_TEXT}",
  "attachments": [
    {
      "text": "Deseja atualizar todos os backups agora ignorando o bloqueio diário?",
      "actions": [
        {
          "id": "force_all_backups",
          "name": "Forçar Atualização de Todos",
          "integration": {
            "url": "${N8N_WEBHOOK_URL}",
            "context": {
              "action": "force_all"
            }
          }
        }
      ]
    }
  ]
}
EOF
)
  else
    PAYLOAD_JSON="{\"text\": \"${JSON_TEXT}\"}"
  fi

  # Dispara o webhook consolidado
  curl -s -X POST -H 'Content-Type: application/json' -d "${PAYLOAD_JSON}" "${MATTERMOST_WEBHOOK_URL}" > /dev/null
fi

rm -f "${SUMMARY_FILE}"
echo "[+] Rotina finalizada com sucesso."
