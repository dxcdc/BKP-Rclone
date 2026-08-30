# Auditoria de Cobertura da VPS — 2026-08-29

Escopo: inventário somente leitura do host `srv1752033`, comparação de containers/volumes ativos com a Central de Backup e validações realizadas após as correções. Endereços, credenciais, tokens e conteúdo dos dados não são registrados neste documento.

## Resultado

A VPS passou a ter uma entrada offsite para todos os conjuntos persistentes
identificados no inventário. As exceções e riscos estruturais remanescentes estão
registrados ao fim deste documento.

### Backups atuais confirmados no remote

| Serviço | Cobertura confirmada | Último resultado validado |
|---|---|---|
| Vaultwarden | PostgreSQL | Upload, download, SHA-256 e restore temporário aprovados |
| Vaultwarden Files | Chaves e arquivos auxiliares | Upload e download verificados |
| Easypanel | `/etc/easypanel` | Arquivo diário presente; não substitui dumps consistentes dos bancos contidos em bind mounts |
| Mattermost | PostgreSQL | Sucesso após correção do seletor Swarm |
| ERP Compras | PostgreSQL | Sucesso após correção do seletor Swarm |
| Moodle | MariaDB | Sucesso após seletor exato e suporte a variáveis MariaDB |
| NextERP/Estoque | Backup Frappe completo | Job separado com banco, arquivos públicos, privados e configuração |
| Postal | MariaDB | Sucesso após suporte a variáveis MariaDB |
| Transportes | PostgreSQL | Sucesso após correção do seletor Swarm |
| Wiki.js | PostgreSQL | Sucesso após correção do seletor Swarm |
| Core CDC | SQLite no contêiner | Cópia consistente pela API de backup do SQLite |
| Site CDC | PostgreSQL e uploads | Pacotes separados, com verificação remota |
| VPN | PostgreSQL e WireGuard | Banco e perfis/configuração em pacotes separados |
| Orion/CDC Admin | PostgreSQL | Dump nativo e verificação remota |
| Semaphore | MariaDB e Ansible | Banco e volume operacional em pacotes separados |
| OpenBao | armazenamento em arquivos | Volume de dados criptografado e verificado |
| n8n | PostgreSQL e dados | Banco e dados da aplicação em pacotes separados |
| Mattermost Files | anexos, plugins e configuração | Pacote offsite dedicado |
| Moodle Files | `moodledata` | Pacote offsite dedicado |
| Wiki.js Files | conteúdo | Coleta pelo caminho estável dentro do contêiner |
| Postal Files | configuração | Pacote offsite dedicado |

### Riscos e melhorias estruturais

- a central mantém produção + uma cópia offsite; isso ainda não constitui
  3-2-1 completo nem armazenamento imutável;
- backups de diretórios ativos são pacotes de arquivos, não snapshots de
  filesystem; serviços críticos devem ser pausados em testes de recuperação;
- o `moodledata` foi encontrado inicialmente na camada gravável do contêiner;
  em 2026-08-30 foi migrado, com modo de manutenção, para bind mount declarado,
  preservando 3.293 arquivos e convergindo novamente em `1/1`;
- o Core CDC ainda usa SQLite na aplicação; agora há cópia consistente, mas uma
  migração de banco deve ser tratada no repositório do Core, com testes próprios;
- o OpenBao usa backend de arquivos; além da rotina diária, foi realizado um
  backup frio validado e o serviço retornou a `1/1`. Esse procedimento deve ser
  repetido nos testes periódicos de desastre.

## Testes de recuperação

- Vaultwarden PostgreSQL: restauração temporária aprovada, 29 tabelas;
- Core CDC SQLite: download, descriptografia e `integrity_check=ok`, 32 tabelas;
- Site CDC PostgreSQL: restauração temporária aprovada, 30 tabelas;
- todos os bancos temporários e arquivos locais de teste foram removidos.

## Saúde do host

Foram identificados 8.743 processos zumbis, todos filhos do contêiner legado
`wiki-app`. A reinicialização controlada da Wiki.js zerou a contagem, a conexão
PostgreSQL voltou normalmente e o backup de conteúdo foi validado depois. Como
novos zumbis reapareceram, o Compose da Wiki passou a declarar `init: true`; o
contêiner foi recriado com init habilitado. Após um ciclo completo de pull/push
Git, a contagem permaneceu zerada e o endpoint público respondeu normalmente.

## Migração do Vaultwarden

- origem: SQLite íntegro, sem usuários, cofres ou organizações;
- destino: PostgreSQL 17 dedicado, volume persistente e credenciais em Docker Secrets;
- serviço e banco: `1/1`, healthcheck saudável;
- rollback: SQLite original, especificação anterior e backup pré-migração criptografado preservados;
- restore: backup PostgreSQL restaurado em banco temporário, com 29 tabelas e contagens equivalentes; banco de teste removido.

## Pendência externa

O Rclone avisou que o `client_id` compartilhado do Google Drive será descontinuado durante 2026. Deve-se configurar um `client_id` próprio antes da interrupção anunciada.

A VM GCP disponível usa uma service account limitada a Storage e telemetria. Ela
não possui escopo para consultar o projeto nem administrar APIs/OAuth; a criação
do cliente exige acesso administrativo ao Console Google Cloud ou ampliação
coordenada de IAM e dos access scopes da VM.
