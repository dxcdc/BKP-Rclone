# Vaultwarden em PostgreSQL

Estado de produção validado em 2026-08-30:

- aplicação: serviço Swarm `cdc-ezpoint_vaultwarden`;
- banco: PostgreSQL 17 no serviço `cdc-ezpoint_vaultwarden-db`;
- persistência: bind mount sob o projeto `cdc-ezpoint` do Easypanel;
- credenciais: Docker Secrets, nunca valores em Git ou argumentos de processo;
- endpoint público: `https://hub.cdc.org.br`;
- backup: dump PostgreSQL em `Auth - Vaultwarden/db` e arquivos auxiliares em
  `Auth - Vaultwarden Files/files`.

## Verificação operacional

```bash
docker service ls --filter name=cdc-ezpoint_vaultwarden
docker service ps cdc-ezpoint_vaultwarden --no-trunc
docker service ps cdc-ezpoint_vaultwarden-db --no-trunc
curl --fail --silent https://hub.cdc.org.br/alive
```

Antes de qualquer alteração, exporte as especificações dos dois serviços,
faça um backup forçado dos dois conjuntos e teste a restauração em um banco
temporário. Não recrie secrets com o mesmo nome: secrets do Docker Swarm são
imutáveis e uma rotação deve usar novos nomes e atualização coordenada dos
dois serviços.

## Rollback

O rollback da migração inicial permanece no diretório protegido de backups da
VPS. Para um incidente futuro, prefira restaurar o dump PostgreSQL mais recente;
o SQLite legado é apenas uma salvaguarda pré-migração e não recebe novos dados.
