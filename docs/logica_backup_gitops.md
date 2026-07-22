# Lógica Operacional do Backup GitOps (Mapeamento e Sincronização)

Como garantimos que a nossa estrutura de pastas no Google Drive reflita fielmente nossos serviços sem que precisemos criar nada manualmente no painel web da nuvem? A resposta está na arquitetura GitOps (Configuração como Código). Ao declararmos nossos serviços no Git, usamos o repositório como a "fonte única da verdade". Este documento explica visual e conceitualmente a lógica de provisionamento de pastas e execução de backups.

---

## 1. Diagrama de Fluxo (Mapeamento Git -> VPS -> Google Drive)

O mapa abaixo ilustra como uma pasta criada no repositório Git é traduzida em diretórios organizados no Google Drive e como as cópias de segurança são enviadas:

```mermaid
flowchart TD
    %% Nós de Entrada (Git)
    subgraph Repositorio_Git [1. Repositório Git (Fonte da Verdade)]
        direction TB
        repo_servico["services/Educa - Moodle/"]
        repo_info["services/Educa - Moodle/info.txt"]
        repo_conf["services/Educa - Moodle/backup.conf (Opcional)"]
    end

    %% Processamento na VPS
    subgraph VPS_Server [2. Servidor VPS (Execução de Madrugada)]
        direction TB
        git_pull["1. git pull (Atualiza Estrutura)"]
        script_mestre["2. scripts/backup_run.sh (Executa)"]
        docker_inspect["3. docker inspect (Extrai Senhas do Container)"]
        gpg_encrypt["4. gpg --symmetric (Criptografa Dados)"]
        rclone_sync["5. rclone (Sincroniza para o Drive)"]
    end

    %% Destino (Google Drive)
    subgraph Google_Drive [3. Google Drive (Nuvem Offsite)]
        direction TB
        gdrive_root["Central de BKP/"]
        gdrive_servico["Central de BKP/Educa - Moodle/"]
        gdrive_info["Central de BKP/Educa - Moodle/info.txt"]
        gdrive_db["Central de BKP/Educa - Moodle/db/ (Arquivos .gpg)"]
        gdrive_files["Central de BKP/Educa - Moodle/files/ (Arquivos .gpg)"]
        gdrive_logs["Central de BKP/Educa - Moodle/logs.txt"]
    end

    %% Relações de Fluxo
    repo_servico -- "Git Push/Pull" --> git_pull
    git_pull --> script_mestre
    script_mestre -- "Lê backup.conf" --> docker_inspect
    docker_inspect -- "Gera Dump" --> gpg_encrypt
    gpg_encrypt --> rclone_sync

    %% Mapeamento do Drive
    rclone_sync -- "Cria pasta se não existir" --> gdrive_servico
    repo_info -- "Copiado pelo Script" --> gdrive_info
    rclone_sync -- "Upload do Backup" --> gdrive_db
    script_mestre -- "Atualiza Logs" --> gdrive_logs
```

---

## 2. A Lógica dos Dois Estágios de um Serviço

A grande vantagem deste modelo é a flexibilidade. Um serviço na pasta `services/` do Git pode estar em um de dois estágios possíveis:

### Estágio A: Apenas Mapeado (Sem Backup Ativo)
*   **O que significa:** A pasta do serviço existe no Git (ex: `services/Digital - Serviços Digitais/`) e contém apenas o arquivo `info.txt` descritivo. O arquivo `backup.conf` **não existe**.
*   **O que o script faz no Google Drive:**
    1. Ele detecta a pasta no Git.
    2. Ele acessa o Google Drive e cria a pasta `Central de BKP/Digital - Serviços Digitais/`.
    3. Ele envia o arquivo `info.txt` para essa pasta na nuvem.
    4. **Resultado:** A pasta fica pronta e documentada no seu Google Drive, mas vazia (sem backups), aguardando ativação futura.

### Estágio B: Ativo (Com Backup Executando)
*   **O que significa:** Você adicionou o arquivo `backup.conf` na pasta do serviço no Git.
*   **O que o script faz no Google Drive:**
    1. Executa todas as etapas do Estágio A (garante que pastas e `info.txt` existam).
    2. Lê as configurações do `backup.conf` (tipo de banco, container Docker).
    3. Extrai os dados do container Docker correspondente, compacta e criptografa localmente.
    4. Envia o arquivo criptografado `.gpg` para a pasta `/db` ou `/files` correspondente no Google Drive.
    5. Atualiza o arquivo `logs.txt` daquele serviço na nuvem indicando o sucesso ou falha da operação.

---

## 3. Guia Prático para Adicionar um Novo Serviço de Backup

Para qualquer engenheiro ou administrador da equipe adicionar um novo backup no futuro, o processo se resume a 3 passos simples no Git:

1.  **Criar a pasta e info.txt:**
    Crie a pasta com o nome amigável (ex: `services/Wiki - Wiki.js`) e coloque o arquivo `info.txt` explicando o que é o sistema.
2.  **Criar o arquivo `backup.conf`:**
    Defina os parâmetros do Docker:
    ```ini
    BACKUP_TYPE="postgres"
    DB_CONTAINER="easypanel-wiki-db"
    DB_USER="wikijs_user"
    DB_NAME="wiki_db"
    ```
3.  **Comitar e Enviar ao Git:**
    ```bash
    git add .
    git commit -m "docs: ativa backup para o Wiki.js"
    git push origin main
    ```

Quando a VPS executar o script na madrugada seguinte, ela lerá essa nova pasta do Git, criará o diretório correspondente no Google Drive e começará a popular a pasta `/db` com os backups criptografados.
