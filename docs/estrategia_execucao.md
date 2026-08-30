# Estratégia de Execução, Versionamento e Deploy

> **Aviso de escopo:** este documento contém modelos históricos de deploy de aplicações Docker. A Central de Backup atual não possui `docker-compose.yml`; use o [README](../README.md) e o [manual de infraestrutura](./ajuda_infra.md).

Como garantimos que novas funcionalidades cheguem aos nossos usuários sem causar instabilidade na operação? A resposta está em uma estratégia de versionamento robusta e em um fluxo de deploy previsível. Este documento descreve as diretrizes para organizar nosso código, validar as entregas em diferentes ambientes e agir de forma ágil com planos de rollback estruturados quando ocorrem desvios de comportamento em produção.

---

## 1. Estratégia de Branches (Git Flow Simplificado)

Adotamos uma abordagem baseada no Git Flow simplificado para garantir a rastreabilidade das alterações e a estabilidade das releases.

### 1.1 Mapeamento das Branches
As branches abaixo organizam o ciclo de vida do nosso código:

*   **`main`**: Representa o código em produção. Apenas alterações homologadas e prontas para release são mescladas aqui através de Pull Requests vindos de `develop` ou `hotfix/*`.
*   **`develop`**: Branch de integração para novas funcionalidades. Recebe merges de branches `feature/*`.
*   **`feature/<codigo-tarefa>-<nome-breve>`**: Criada a partir de `develop`. Usada para o desenvolvimento de novas funcionalidades ou correções não-urgentes (ex: `feature/123-api-auth`).
*   **`hotfix/<codigo-tarefa>-<nome-breve>`**: Criada diretamente de `main` para corrigir incidentes urgentes de produção.

### 1.2 Procedimento para Criação de Feature e Pull Request
Para iniciar um novo desenvolvimento e submeter o código para validação, siga as etapas abaixo:

1.  Atualize a branch `develop` localmente e crie a branch de trabalho:
    ```bash
    git checkout develop
    git pull origin develop
    git checkout -b feature/456-ajuste-smtp
    ```
2.  Desenvolva a funcionalidade, commitando com mensagens claras e objetivas.
3.  Suba a branch para o repositório remoto:
    ```bash
    git push origin feature/456-ajuste-smtp
    ```
4.  Abra um **Pull Request** direcionando a branch `feature/456-ajuste-smtp` para `develop` no GitHub/GitLab.
5.  Preencha o checklist de PR e aguarde a revisão de pelo menos um engenheiro sênior antes de realizar o merge.

---

## 2. Mapeamento de Ambientes

Temos três ambientes isolados para garantir que testes rigorosos aconteçam antes do deploy em produção.

| Ambiente | Host / Domínio | Branch de Origem | Objetivo |
| :--- | :--- | :--- | :--- |
| **Desenvolvimento (Dev)** | `<TODO: DEFINIR — ex: dev.projeto.local>` | `develop` (Deploy Automático) | Validação contínua do time de engenharia |
| **Homologação (Staging)** | `<TODO: DEFINIR — ex: staging.projeto.com>` | Tags de Release (Deploy sob Demanda) | Testes de aceitação com clientes e auditorias |
| **Produção (Prod)** | `<TODO: DEFINIR — ex: app.projeto.com>` | `main` (Deploy Manual / Aprovado) | Ambiente final de entrega de valor aos usuários |

---

## 3. Notificações de Deploy no Mattermost

Todos os deploys executados pelas esteiras de CI/CD notificam automaticamente o canal `#ops-deploy` para manter a equipe informada sobre o status da infraestrutura.

### 3.1 Exemplo de Payload de Notificação de Deploy (Webhook)
A esteira de CI/CD dispara um webhook para o Mattermost com o payload formatado em JSON. Exemplo completo de script disparado no final do deploy:

```bash
curl -i -X POST -H 'Content-Type: application/json' \
-d '{
  "username": "Esteira de CI/CD",
  "text": "### :rocket: Deploy Executado com Sucesso\n* **Projeto:** BKP Rclone\n* **Ambiente:** Produção\n* **Versão:** v1.2.0\n* **Autor:** Engenheiro DevOps\n* **Status:** Concluído com sucesso. Healthcheck 200 OK verificado."
}' \
<MATTERMOST_WEBHOOK_URL>
```

---

## 4. Plano Detalhado de Rollback

Se um deploy introduzir um comportamento inesperado ou indisponibilidade, a velocidade de recuperação é nossa prioridade. Siga os planos de rollback descritos abaixo, conforme o componente afetado.

### 4.1 Rollback de Código e Container
Se a aplicação falhar ou apresentar erros após o deploy:

1.  Acesse o servidor de aplicação via SSH:
    ```bash
    ssh -i ~/.ssh/id_ed25519 <USER>@<SERVER_IP>
    ```
2.  Navegue até a pasta do projeto:
    ```bash
    cd /home/vier/Documentos/Code/CDC/BKP\ Rclone
    ```
3.  Edite o arquivo `.env` para apontar para a tag da imagem Docker anterior (ex: altere de `v1.2.0` para `v1.1.9`):
    ```ini
    APP_VERSION=v1.1.9
    ```
4.  Recrie o container com a imagem anterior:
    ```bash
    docker compose down
    docker compose up -d
    ```
5.  Valide o status da aplicação:
    ```bash
    docker compose ps
    ```

### 4.2 Rollback de Banco de Dados
Se uma migração de banco de dados (`migration`) falhar ou corromper dados:

1.  Identifique se há um backup recente realizado antes do deploy. Consulte o histórico de logs no canal `#ops-logs` do Mattermost.
2.  Derrube temporariamente o container da aplicação para interromper novas escritas:
    ```bash
    docker compose stop web
    ```
3.  Restaure o backup do banco de dados executando o roteiro detalhado na seção 5 de [politica_backup.md](./politica_backup.md).
4.  Re-inicie o container da aplicação:
    ```bash
    docker compose start web
    ```

### 4.3 Rollback do Proxy Reverso (Nginx)
Se as novas regras de roteamento do proxy reverso bloquearem o tráfego de rede:

1.  Acesse o servidor do proxy reverso.
2.  Restaure o arquivo de configuração anterior do Nginx a partir do backup automático gerado antes do deploy:
    ```bash
    cp /etc/nginx/nginx.conf.bak /etc/nginx/nginx.conf
    ```
3.  Valide a sintaxe do arquivo de configuração:
    ```bash
    nginx -t
    ```
4.  Se o teste retornar sucesso (`syntax is ok`), recarregue as configurações do proxy:
    ```bash
    systemctl reload nginx
    ```
