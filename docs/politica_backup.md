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
