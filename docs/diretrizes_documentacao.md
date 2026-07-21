# Diretrizes de Documentação

Por que documentamos nossos sistemas? Em ambientes de ritmo acelerado, a documentação técnica é frequentemente tratada como um subproduto secundário. No entanto, ela é a espinha dorsal que sustenta o onboarding de novos engenheiros, reduz a carga cognitiva durante incidentes críticos de infraestrutura e garante a continuidade do conhecimento. Esta política estabelece o modelo de "documentação como código", garantindo que manuais, diagramas e arquiteturas evoluam no mesmo ritmo que a base de código do projeto.

---

## 1. Princípios Fundamentais

Nossos pilares de documentação baseiam-se em três conceitos operacionais primordiais:

*   **Documentação Viva (Docs as Code):** Todos os manuais técnicos devem residir no mesmo repositório do código sob a pasta `docs/`. Atualizações de infraestrutura ou fluxos de negócio requerem commits de documentação na mesma janela de entrega da funcionalidade.
*   **Segurança por Padrão (Security by Design):** Arquivos de documentação são públicos dentro da organização. Portanto, é terminantemente proibido incluir senhas, tokens de webhook ou chaves privadas reais. Utilize sempre placeholders como `<MATTERMOST_WEBHOOK_URL>` ou `<DB_PASSWORD>`.
*   **Alta Escaneabilidade:** Textos longos e densos reduzem a eficiência no momento do incidente. Prefira tabelas, listas curtas numeradas e blocos de alerta visual.

---

## 2. Estrutura de Arquivos da Documentação

A tabela abaixo descreve o ecossistema de arquivos sob a pasta `docs/` e o papel individual de cada um:

| Arquivo | Finalidade | Responsabilidade |
| :--- | :--- | :--- |
| [README.md](../README.md) | Visão geral do repositório, requisitos e diagrama de arquitetura | Toda a equipe |
| [diretrizes_documentacao.md](./diretrizes_documentacao.md) | Regras de governança da documentação, ADRs e alertas | Arquiteto de Soluções |
| [estrategia_execucao.md](./estrategia_execucao.md) | Padrões de branch, ambientes de CI/CD e planos de rollback | DevOps |
| [migration_guide.md](./migration_guide.md) | Roteiro de migração física/lógica e onboarding em novos servidores | DevOps |
| [ajuda_infra.md](./ajuda_infra.md) | Configurações Docker, variáveis de ambiente e mapeamento de portas | DevOps / Arquiteto |
| [postmortem.md](./postmortem.md) | Registro não-culpável de incidentes de produção e lições aprendidas | Engenharia / Operações |
| [troubleshooting.md](./troubleshooting.md) | Guia prático de autoajuda e diagnósticos de erros frequentes | Suporte / DevOps |
| [politica_backup.md](./politica_backup.md) | Regras de backup 3-2-1, criptografia GPG e envio ao Google Drive | Especialista em Segurança |
| [prompt_ia.md](./prompt_ia.md) | Prompt de contexto fixo para assistentes de inteligência artificial | Arquiteto |

---

## 3. Regras de Atualização e Fluxo Git

Como garantimos que os documentos não fiquem defasados? Todo Pull Request que altere a infraestrutura do projeto (portas, volumes, pacotes, variáveis de ambiente) **deve** incluir as respectivas alterações nos arquivos markdown da pasta `docs/`.

### 3.1 Padrão de Mensagem de Commit para Documentação
Para commits focados estritamente na melhoria ou ajuste de manuais, utilize o prefixo `docs:` conforme a convenção do *Conventional Commits*:

1.  Acesse o terminal do projeto.
2.  Adicione as modificações da pasta `docs/` ao stage:
    ```bash
    git add docs/ajuda_infra.md
    ```
3.  Faça o commit utilizando a mensagem padronizada:
    ```bash
    git commit -m "docs: atualiza portas expostas e variaveis do compose no guia de infra"
    ```

---

## 4. Governança e Segurança do Mattermost

O Mattermost atua como a nossa central de telemetria operacional humana. Para evitar ruídos e manter a integridade, siga as regras de governança abaixo:

### 4.1 Organização de Canais de Alerta
Os alertas gerados por webhooks estão categorizados por severidade e canal de destino:

| Canal | Tipo de Notificação | Nível de Urgência | Ação Requerida |
| :--- | :--- | :--- | :--- |
| `#ops-deploy` | Sucesso ou falha de deploys de código ou atualizações de infraestrutura | Médio | Validação do time de DevOps |
| `#ops-alerts` | Alertas de healthcheck, uso elevado de disco/CPU ou falha de backup | Crítico | Acionamento imediato do time de plantão |
| `#ops-logs` | Notificação de rotina diária (backups concluídos, relatórios periódicos) | Baixo | Apenas leitura e auditoria |

### 4.2 Proteção e Mascaramento de Webhooks
Os endereços e tokens dos Webhooks de Entrada (Incoming Webhooks) do Mattermost são segredos corporativos. A exposição de um webhook permite que agentes externos enviem payloads maliciosos ou mensagens falsas aos canais oficiais.

1.  **NUNCA** adicione a URL do webhook em arquivos estáticos de código ou scripts rastreados no Git.
2.  Armazene a URL unicamente na variável de ambiente `<MATTERMOST_WEBHOOK_URL>` contida no arquivo `.env` do servidor (que deve estar listado no `.gitignore`).
3.  Ao documentar chamadas HTTP via `curl` ou simulações, utilize o placeholder genérico:
    ```bash
    curl -i -X POST -H 'Content-Type: application/json' --data '{"text":"Mensagem de teste"}' <MATTERMOST_WEBHOOK_URL>
    ```

---

## 5. Checklist para Pull Requests (PR)

Antes de aprovar e realizar o merge de um Pull Request no repositório, certifique-se de que os seguintes pontos da documentação foram validados:

*   [ ] O arquivo [README.md](../README.md) reflete eventuais novas dependências de infraestrutura?
*   [ ] Caso novas variáveis tenham sido introduzidas, elas foram documentadas com placeholders no arquivo `.env.example` e na [Ajuda de Infraestrutura](./ajuda_infra.md)?
*   [ ] Se o PR envolve modificações em rotinas de banco, o guia de migração foi atualizado?
*   [ ] Não há senhas, tokens ou dados sensíveis reais inseridos no código ou na documentação técnica?

---

## 6. Processo de Architectural Decision Records (ADR)

Quando tomamos decisões que impactam permanentemente a arquitetura do projeto (como mudar o banco de dados de MySQL para PostgreSQL, ou adotar criptografia simétrica GPG para backups), criamos um ADR na pasta `docs/adr/`.

### Estrutura de um ADR (Registro de Decisão)
Crie um novo arquivo markdown na pasta `docs/adr/` nomeado sequencialmente (ex: `0001-uso-de-criptografia-gpg.md`) contendo:

1.  **Título:** `ADR <número> - <Breve Título>`
2.  **Status:** `Proposto / Aceito / Rejeitado / Superado`
3.  **Contexto:** O que nos levou a precisar tomar essa decisão técnica?
4.  **Decisão:** Qual foi a solução adotada e quais foram as alternativas rejeitadas?
5.  **Consequências:** O que muda na operação a partir do aceite desta decisão? (Ex: nova dependência do binário do GPG instalado nos servidores).
