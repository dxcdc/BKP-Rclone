# Prompt de Contexto e Instruções Permanentes para Inteligência Artificial (System Prompt)

Por que mantemos um arquivo de contexto dedicado para Inteligência Artificial? À medida que as bases de código crescem e os ecossistemas de infraestrutura se tornam mais complexos, os assistentes de IA que auxiliam a equipe de engenharia precisam entender instantaneamente os limites de design, as restrições de segurança e os padrões de codificação específicos do nosso projeto. Este arquivo funciona como uma "memória permanente", garantindo que qualquer IA produza código aderente ao nosso ecossistema sem reintroduzir bugs ou quebrar padrões arquiteturais.

---

## 1. Contexto Permanente do Sistema (System Context)

Ao atuar no projeto **BKP Rclone**, a Inteligência Artificial deve assumir e respeitar rigorosamente as seguintes premissas arquiteturais e de segurança:

### 1.1 Stack de Referência do Projeto
*   **Linguagem/Runtime:** Node.js (V18 Alpine)
*   **Banco de Dados:** PostgreSQL (V15 Alpine)
*   **Servidor Web / Proxy:** Nginx (V1.25 Alpine)
*   **Operações Offsite:** Rclone (sincronização de arquivos para o remote `gdrive:`)
*   **Segurança Local:** Criptografia simétrica com GPG (AES-256)
*   **Central de Alertas:** Webhooks de Entrada do Mattermost

### 1.2 Regras de Segurança e Restrições de Rede
*   **Redes Isoladas:** O banco de dados PostgreSQL (`postgres-db`) e o container de backups (`backup-scheduler`) residem estritamente na rede interna isolada `internal_net`. Eles não podem expor portas públicas para o host ou para a internet.
*   **Placeholder de Segredos:** NUNCA escreva senhas reais, tokens ou URLs de webhooks em suas respostas de código. Utilize placeholders como `<DB_PASSWORD>`, `<GPG_PASSPHRASE>` e `<MATTERMOST_WEBHOOK_URL>`.
*   **Preservação Histórica:** Nunca remova ou substitua registros antigos em arquivos de log ou históricos como [postmortem.md](./postmortem.md) ou [troubleshooting.md](./troubleshooting.md). Adicione novas entradas sempre de forma incremental no **topo** das tabelas ou listas.

---

## 2. Regras Obrigatórias de Resposta para a IA

Para que o código gerado seja imediatamente útil e seguro para a equipe, a IA deve seguir as regras de resposta abaixo:

1.  **Código Completo:** Não utilize reticências (`...`) ou comentários como `// restante do código aqui` para omitir trechos de scripts ou configurações YAML/JSON. Apresente o código de forma completa, pronta para execução.
2.  **Tratamento de Erros:** Todos os scripts em linguagem shell (Bash/Sh) devem iniciar obrigatoriamente com a diretiva `set -Eeuo pipefail` e conter tratamentos estruturados para capturar sinais de falha (ex: `trap`).
3.  **Links Relativos:** Ao referenciar arquivos do projeto, utilize sempre links markdown relativos (ex: [Manual de Infra](./ajuda_infra.md)) e nunca caminhos absolutos locais do seu sistema de sandbox.

---

## 3. Prompts Rápidos e Modelos de Comandos (Templates)

> [!TIP]
> Utilize as instruções abaixo como prompts diretos para a IA ao solicitar tarefas operacionais recorrentes.

### 3.1 Prompt para Rebuild de Containers de Aplicação
```
"Ajuste as configurações no docker-compose.yml e forneça os comandos completos para realizar o rebuild e reinicialização segura dos containers 'web-app' e 'nginx-proxy', garantindo que as variáveis de ambiente do host sejam recarregadas e as redes isoladas sejam preservadas."
```

### 3.2 Prompt para Diagnóstico de Logs em Tempo Real
```
"Forneça os comandos necessários utilizando 'docker compose logs' para inspecionar em tempo real apenas os registros do container 'postgres-db', filtrando por palavras-chave críticas de falha (como ERROR, FATAL ou DENIED), sem omitir nenhuma parte das linhas retornadas."
```

### 3.3 Prompt para Execução Manual de Backups
```
"Escreva o roteiro de execução manual do script '/scripts/backup_run.sh' no container 'backup-scheduler', demonstrando como passar variáveis de ambiente temporárias para teste rápido e como inspecionar a saída do comando no terminal."
```

### 3.4 Prompt para Restauração de Banco de Dados
```
"Crie um plano passo a passo para baixar um backup do Google Drive usando 'rclone copy', validar sua integridade usando sha256sum, descriptografar usando gpg com chave simétrica e realizar a restauração completa no banco PostgreSQL através de comandos executados dentro de um container Docker."
```

### 3.5 Prompt para Testar Webhook do Mattermost
```
"Escreva um comando curl completo e sanitizado para enviar um payload JSON de teste ao webhook do Mattermost, incluindo formatação markdown de título, ícone personalizado e mensagem simulando uma falha de conexão de rede."
```
