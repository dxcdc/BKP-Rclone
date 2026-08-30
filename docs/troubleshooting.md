# Manual de Diagnóstico e Resolução de Problemas (Troubleshooting)

> **Aviso de escopo:** as seções de Docker Compose abaixo são referências históricas para aplicações externas. A Central de Backup roda no host; verifique o código de saída do script, o log do agendador e o relatório consolidado.

Como agimos quando o sistema falha repentinamente? Em momentos de instabilidade em produção, a pressão emocional pode prejudicar nossa capacidade de análise técnica. Ter um guia de referência passo a passo, estruturado de forma clara e com comandos prontos para execução, reduz o tempo de resposta (MTTR) e garante uma depuração lógica dos sistemas. Este documento lista procedimentos operacionais rápidos e diagnósticos recorrentes de infraestrutura.

---

## 1. Guia Histórico Incremental de Solução de Problemas

> [!IMPORTANT]
> **REGRA DE PRESERVAÇÃO HISTÓRICA:** Novas falhas identificadas e suas respectivas resoluções devem ser adicionadas incrementalmente no **topo** desta seção, servindo como base de conhecimento contínuo para o time de suporte.

### Falha 002: Erro 403 Forbidden no Webhook do Mattermost
*   **Sintomas:** Falha no envio de notificações automáticas de deploy ou backup. Logs do container registram erro HTTP 403.
*   **Causa Raiz:** O token de webhook gerado no painel do Mattermost foi revogado ou a URL de destino foi alterada.
*   **Resolução:**
    1. Acesse as configurações de integrações no console do Mattermost.
    2. Gere um novo **Incoming Webhook** para o canal correspondente.
    3. Atualize a variável `MATTERMOST_WEBHOOK_URL` no arquivo `.env` do servidor de produção.
    4. Recarregue os containers:
       ```bash
       docker compose up -d --force-recreate web-app backup-scheduler
       ```

### Falha 001: Erro de Permissão de Gravação em Volume Docker postgres_data
*   **Sintomas:** O container PostgreSQL entra em loop de reinicialização (`Restarting`) com logs apontando `Permission denied`.
*   **Causa Raiz:** O diretório de dados local no host possui permissões de proprietário pertencentes ao usuário root, impossibilitando a gravação pelo usuário interno `postgres` (UID 70).
*   **Resolução:**
    1. Altere o proprietário do diretório físico mapeado para o container no host:
       ```bash
       sudo chown -R 70:70 /home/vier/Documentos/Code/CDC/BKP\ Rclone/data/postgres
       ```
    2. Ajuste as permissões de leitura/escrita:
       ```bash
       sudo chmod -R 700 /home/vier/Documentos/Code/CDC/BKP\ Rclone/data/postgres
       ```
    3. Re-inicie o serviço de banco de dados:
       ```bash
       docker compose up -d postgres-db
       ```

---

## 2. Diagnóstico de Sistemas e Comandos de Correção

Abaixo estão listadas as rotinas de verificação para depurar falhas específicas em cada componente da nossa stack.

### 2.1 Diagnóstico de Containers Docker
Se algum container essencial estiver listado como `Exit` ou falhar no healthcheck:

1.  Verifique o status de todos os containers ativos e inativos:
    ```bash
    docker compose ps -a
    ```
2.  Inspecione os logs do container com falha em busca de erros de inicialização:
    ```bash
    docker compose logs --tail=100 web-app
    ```
3.  Reinicie um container travado ou com falha:
    ```bash
    docker compose restart web-app
    ```

### 2.2 Diagnóstico do Banco de Dados (PostgreSQL)
Se a aplicação relatar falhas de conexão SQL:

1.  Verifique se o banco de dados está ouvindo conexões:
    ```bash
    docker compose exec postgres-db pg_isready -U app_db_user -d bkp_rclone_production
    ```
2.  Inspecione a quantidade de conexões ativas no PostgreSQL:
    ```bash
    docker compose exec postgres-db psql -U app_db_user -d bkp_rclone_production -c "SELECT count(*) FROM pg_stat_activity;"
    ```

### 2.3 Diagnóstico de SMTP de E-mail
Se os e-mails transacionais de recuperação de senha ou notificações não forem entregues:

1.  Acesse o container de aplicação e use um comando curl/nc para testar a comunicação com a porta de saída do provedor SMTP:
    ```bash
    docker compose exec web-app nc -zv smtp.sendgrid.net 587
    ```
2.  Verifique nos logs da aplicação se há erros de autenticação SMTP (`Invalid username or password`).

### 2.4 Diagnóstico de Falhas de Webhook do Mattermost
Se as notificações de alertas pararem de funcionar repentinamente:

1.  Valide a resolução DNS do servidor do Mattermost a partir do container:
    ```bash
    docker compose exec backup-scheduler ping -c 3 mattermost.empresa.com
    ```
2.  Execute uma requisição manual simulada no host utilizando a variável configurada no `.env`:
    ```bash
    curl -i -X POST -H 'Content-Type: application/json' --data '{"text":"Alerta manual de teste"}' <MATTERMOST_WEBHOOK_URL>
    ```

---

## 3. Inspeção e Filtragem de Logs em Tempo Real

Depurar logs extensos pode ser ineficiente. Utilize filtros específicos para extrair apenas as linhas relevantes durante uma investigação.

### 3.1 Acompanhar Logs em Tempo Real (Tail)
Para acompanhar a saída de logs de todos os containers simultaneamente:
```bash
docker compose logs -f
```

### 3.2 Filtrar Logs do Banco por Erros Específicos (Grepping)
Para buscar termos específicos de falha, como erros de chave duplicada ou conexões recusadas:
```bash
docker compose logs postgres-db | grep -iE 'error|fatal|fail'
```

---

## 4. Checklist de Emergência (Serviço Totalmente Fora do Ar)

Se a aplicação estiver inacessível e todos os serviços pararem de responder, execute este protocolo na ordem exata indicada abaixo:

*   [ ] **Passo 1:** Conecte via SSH no servidor de produção e execute `df -h` para verificar se há espaço disponível em disco.
*   [ ] **Passo 2:** Verifique a memória RAM livre executando `free -h` para garantir que o sistema não entrou em travamento por falta de memória swap/RAM.
*   [ ] **Passo 3:** Pare toda a orquestração para liberar recursos travados em memória:
    ```bash
    docker compose down
    ```
*   [ ] **Passo 4:** Limpe containers órfãos, redes não utilizadas e caches temporários do Docker (Atenção: isto não exclui volumes persistentes):
    ```bash
    docker system prune -f
    ```
*   [ ] **Passo 5:** Re-inicie os serviços em segundo plano:
    ```bash
    docker compose up -d
    ```
*   [ ] **Passo 6:** Execute o teste de conexão de webhooks do Mattermost descrito na seção 4 de [ajuda_infra.md](./ajuda_infra.md#L96-L107) para confirmar o reestabelecimento das comunicações do sistema.
