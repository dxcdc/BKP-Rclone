# Política Corporativa de Backup e Recuperação de Desastres

Por que planejamos políticas de backup tão rigorosas? No ciclo de vida de qualquer aplicação corporativa, a perda de dados é o cenário operacional mais destrutivo. Seja por exclusão acidental, falha física em servidores ou ataques maliciosos (como ransomware), a capacidade de recuperar dados de forma rápida, íntegra e confidencial determina a continuidade do negócio. Esta política define as metas de recuperação, as regras de armazenamento offsite utilizando o **Rclone** para o **Google Drive** e a implementação de criptografia simétrica local forte.

---

## 1. Estratégia de Backup 3-2-1 e Metas Operacionais

Adotamos a metodologia clássica da indústria para garantir redundância geográfica e física dos nossos ativos de dados:

*   **3 Cópias dos Dados:** Manter uma cópia em produção, um dump local temporário no servidor de banco de dados e uma cópia offsite em nuvem.
*   **2 Mídias Diferentes:** Armazenamento em volumes locais do servidor (SSD) e na infraestrutura de nuvem distribuída do Google Drive.
*   **1 Cópia Offsite:** Upload diário automatizado para um **Shared Drive** corporativo no Google Drive de forma totalmente isolada.

### Metas de Recuperação (SLAs)
*   **RPO (Recovery Point Objective):** 24 horas. No pior cenário possível de falha catastrófica, o limite máximo aceitável de perda de dados transacionais é de 1 dia de operações.
*   **RTO (Recovery Time Objective):** 2 horas. O tempo limite para reestabelecimento completo das operações do sistema e conexões de usuários pós-desastre.

---

## 2. Registro Histórico Incremental de Testes de Restauração

> [!IMPORTANT]
> **REGRA DE PRESERVAÇÃO HISTÓRICA:** É obrigatório executar testes de restauração semestrais para validar as chaves GPG e a integridade física dos dumps. Registre as execuções de teste de forma incremental no **topo** da lista abaixo.

### Teste de Restauração 001: Validação do Fluxo de Recuperação
*   **Data da Execução:** 2026-07-21
*   **Responsável:** Especialista em Segurança
*   **Origem do Backup:** Arquivo `backup_postgres_20260721_020000.sql.gpg` baixado do Google Drive via Rclone.
*   **Resultado:** Sucesso. O hash SHA-256 confere com a assinatura registrada e os dados foram importados com sucesso em ambiente de Staging em 4 minutos e 12 segundos.
*   **Status de Consistência:** 100% dos registros validados e acessíveis.

---

## 3. Script Automatizado de Backup (`backup_run.sh`)

Este script realiza o dump do banco de dados PostgreSQL, compacta o arquivo, criptografa localmente usando criptografia simétrica GPG de 256 bits, calcula o checksum de integridade SHA-256, sincroniza o resultado para o Google Drive via Rclone e envia notificações de sucesso ou falha detalhada ao Mattermost.

O script deve ser instalado em `/scripts/backup_run.sh` conforme detalhado em [ajuda_infra.md](./ajuda_infra.md#L45-L59).

```bash
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
```

---

## 4. Roteiro Completo de Restauração (Disaster Recovery)

Se ocorrer perda total ou corrupção de dados e for necessário aplicar o plano de disaster recovery, siga as etapas procedimentais abaixo na ordem indicada:

1.  Acesse o servidor de destino ou staging via SSH:
    ```bash
    ssh -i ~/.ssh/id_ed25519 <USER>@<SERVER_IP>
    ```
2.  Crie um diretório de trabalho temporário:
    ```bash
    mkdir -p /tmp/restore_working && cd /tmp/restore_working
    ```
3.  Listar os arquivos disponíveis no Google Drive para identificar a versão mais recente:
    ```bash
    rclone lsf gdrive:<RCLONE_DRIVE_FOLDER>
    ```
4.  Baixar o backup criptografado e o respectivo hash SHA-256 correspondente à data desejada (ex: `dump_bkp_rclone_production_20260721_020000.sql.tar.gz.gpg`):
    ```bash
    rclone copy gdrive:<RCLONE_DRIVE_FOLDER>/dump_bkp_rclone_production_20260721_020000.sql.tar.gz.gpg .
    rclone copy gdrive:<RCLONE_DRIVE_FOLDER>/dump_bkp_rclone_production_20260721_020000.sql.tar.gz.gpg.sha256 .
    ```
5.  Valide a integridade do arquivo antes de descriptografar:
    ```bash
    sha256sum -c dump_bkp_rclone_production_20260721_020000.sql.tar.gz.gpg.sha256
    ```
    **Critério de Validação:** A saída deve obrigatoriamente exibir: `dump_bkp_rclone_production_20260721_020000.sql.tar.gz.gpg: OK`.
6.  Descriptografe o backup usando a chave simétrica corporativa:
    ```bash
    gpg --batch --passphrase "<GPG_PASSPHRASE>" --decrypt -o dump_bkp_rclone_production_20260721_020000.sql.tar.gz dump_bkp_rclone_production_20260721_020000.sql.tar.gz.gpg
    ```
7.  Descompacte o dump de banco de dados gerado:
    ```bash
    tar -xzvf dump_bkp_rclone_production_20260721_020000.sql.tar.gz
    ```
8.  Importe o dump restaurado para o banco de dados ativo:
    ```bash
    PGPASSWORD="<DB_PASSWORD>" psql -h localhost -U app_db_user -d bkp_rclone_production -f dump_bkp_rclone_production_20260721_020000.sql
    ```
9.  Após a conclusão da restauração, limpe os arquivos sensíveis em texto claro do diretório temporário:
    ```bash
    rm -rf /tmp/restore_working
    ```
10. Comunique a conclusão do restore no canal `#ops-alerts` do Mattermost.
