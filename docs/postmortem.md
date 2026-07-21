# Orientador de Análise Blameless de Incidentes (Postmortem)

Por que conduzimos análises de incidentes de forma não-culpável (blameless)? Em sistemas complexos de software, falhas são inevitáveis. Culpar indivíduos ou times por incidentes desencoraja a transparência, oculta falhas estruturais e nos impede de aprender com os erros. Um postmortem não busca encontrar culpados, mas sim identificar fraquezas em nossos processos, arquitetura e automações para tornar nossos sistemas cada vez mais resilientes.

---

## 1. Modelo Padrão de Relatório de Incidentes

> [!NOTE]
> Copie este modelo vazio abaixo para criar um novo documento de postmortem sempre que um incidente de severidade Alta ou Crítica for detectado em produção.

```markdown
# Postmortem - Incidente: <Breve Descrição do Incidente>

## Cabeçalho de Identificação
*   **Data do Incidente:** <AAAA-MM-DD>
*   **Severidade:** <Crítico / Alto / Médio / Baixo>
*   **Tempo Total de Indisponibilidade (Downtime):** <Tempo em minutos/horas>
*   **Canal do Mattermost Utilizado para Resposta:** #ops-alerts
*   **Engenheiro Responsável pela Condução:** <Nome do Engenheiro>

## Resumo Executivo
<Forneça um parágrafo amigável descrevendo o que aconteceu, o impacto percebido pelos usuários finais e como o sistema foi restaurado.>

## Sintomas e Impacto
*   **Sintomas observados:** <Ex: Latência de rede saltou de 100ms para 15s; banco de dados parou de responder na porta 5432.>
*   **Impacto no usuário final:** <Ex: Os clientes não conseguiram finalizar compras ou autenticar-se no painel.>

## Timeline Cronológica
| Horário (UTC-3) | Ação / Evento |
| :--- | :--- |
| <HH:MM> | O incidente se inicia de forma silenciosa ou ativa. |
| <HH:MM> | O alerta automático é disparado no canal `#ops-alerts`. |
| <HH:MM> | Engenheiro de plantão inicia a triagem e investigação dos logs. |
| <HH:MM> | Ação corretiva provisória é aplicada para restaurar o serviço. |
| <HH:MM> | Sistema está totalmente estabilizado. |

## Eficiência dos Alertas Automáticos (Mattermost)
*   **O alerta disparou corretamente?** <Sim/Não>
*   **Canal de Notificação:** `#ops-alerts`
*   **Métricas dos alertas:** <Ex: O alerta de healthcheck falhou em menos de 1 minuto, permitindo tempo de resposta ágil.>

## Análise de Causa Raiz (Metodologia dos 5 Porquês)
1.  **Por que** a aplicação parou de funcionar?
    *   *Porque o banco de dados parou de responder às conexões.*
2.  **Por que** o banco parou de responder?
    *   *Porque o disco do container PostgreSQL atingiu 100% de capacidade ocupada.*
3.  **Por que** o disco atingiu 100% de capacidade?
    *   *Porque o script de backup gerou dumps temporários sem executar a limpeza posterior.*
4.  **Por que** a limpeza posterior falhou?
    *   *Porque o script não possuía uma diretiva de remoção de arquivos locais após o envio via Rclone.*
5.  **Por que** o script não possuía essa diretiva?
    *   *Porque o script de backup foi criado de forma ágil sem passar por uma revisão formal de segurança e infraestrutura.*

## Plano de Ação (Ações Corretivas e Preventivas)
| Ação | Tipo | Responsável | Prazo | Prioridade |
| :--- | :--- | :--- | :--- | :--- |
| Implementar limpeza automática no script de backup | Corretiva | DevOps | 2 dias | Crítica |
| Criar alerta de monitoramento de espaço em disco no Host | Preventiva | DevOps | 5 dias | Alta |
```

---

## 2. Registro Histórico Incremental de Incidentes

> [!IMPORTANT]
> **REGRA DE PRESERVAÇÃO HISTÓRICA:** Nunca apague ou altere os registros abaixo. Sempre insira novos incidentes resolvidos no **topo** desta lista, logo abaixo deste alerta, para fins de auditoria e conformidade técnica.

### Incidente 001: Falha na Comunicação de Notificações de Backup
*   **Data:** 2026-07-20
*   **Severidade:** Média
*   **Downtime:** 0 minutos (sem impacto aos usuários finais).
*   **Causa Raiz:** O webhook do Mattermost retornou erro HTTP **400 Bad Request** devido a um payload JSON malformado (caractere de aspa dupla não escapado no script de backup).
*   **Resolução:** Ajuste no script Bash para sanitizar variáveis e escape correto dos caracteres antes de submeter a requisição curl.
*   **Ação Preventiva:** Criação do guia de testes de webhooks em [ajuda_infra.md](./ajuda_infra.md#L96-L107).
