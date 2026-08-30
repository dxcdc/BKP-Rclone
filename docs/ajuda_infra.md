# Manual de Infraestrutura

## 1. Arquitetura real

O motor de backup é executado no host que já possui Docker e acesso aos serviços. Não há `docker-compose.yml` próprio neste repositório.

O host precisa ter:

- acesso somente leitura às configurações necessárias e acesso de dump aos bancos;
- Docker CLI, Bash, `flock`, tar, GPG, Rclone, curl e SHA-256;
- `sqlite3` para backups SQLite;
- remote Rclone configurado;
- saída HTTPS para o armazenamento e, opcionalmente, Mattermost.

## 2. Instalação segura

```bash
cp .env.example .env
chmod 600 .env
bash -n scripts/backup_run.sh
bash tests/test_backup.sh
```

Configure o agendador do host para executar uma única instância. O próprio script usa `flock`, mas o agendador também deve registrar stdout, stderr e código de saída.

Exemplo de cron, ajustando o caminho real:

```cron
0 2 * * * cd /caminho/BKP-Rclone && ./scripts/backup_run.sh >> /var/log/cdc-backup.log 2>&1
```

## 3. Containers

`DB_CONTAINER` deve usar nome estável de serviço. O script tenta primeiro um nome exato; se ele não existir, pesquisa containers ativos pelo seletor e exige exatamente um resultado. Zero ou múltiplos resultados geram falha segura.

Não grave senhas nos `backup.conf`. Usuário e banco podem ser definidos quando a autodetecção não for adequada.

## 4. Homologação

Antes do uso em produção:

1. configure um remote e uma raiz exclusivos de homologação;
2. execute um serviço com `force`;
3. confirme código de saída zero;
4. confira `.gpg`, `.sha256` e `logs.txt` no destino;
5. baixe, valide, descriptografe e restaure em ambiente isolado;
6. simule falhas de Docker, Rclone, GPG e Mattermost;
7. confirme que nenhuma falha é reportada como sucesso.

## 5. Rclone Web GUI

Uma interface Rclone, se utilizada, é infraestrutura externa a este repositório. Não exponha a API administrativa diretamente à internet. Use autenticação forte, TLS, restrição de rede e privilégio mínimo. A existência da interface não comprova a saúde nem a restaurabilidade dos backups.
