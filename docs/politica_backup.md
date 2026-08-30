# Política de Backup e Recuperação

## 1. Estado atual e objetivo 3-2-1

A implementação atual mantém os dados de produção e uma cópia persistente criptografada no remote Rclone. O arquivo temporário local é eliminado ao final e, portanto, não conta como cópia persistente.

Para atingir efetivamente 3-2-1 ainda é necessário manter uma terceira cópia em mídia ou provedor independente, preferencialmente imutável. Até isso existir e ser validado, a solução deve ser descrita como backup offsite criptografado, não como 3-2-1 completo.

Metas operacionais pretendidas:

- RPO: 24 horas;
- RTO: 2 horas;
- retenção diária padrão: 15 dias;
- teste de restauração: no mínimo semestral.

RPO e RTO são objetivos; só devem ser tratados como comprovados depois de exercícios de recuperação medidos.

## 2. Controles implementados

- criptografia simétrica GPG AES-256 antes do upload;
- SHA-256 local, download pós-upload e nova validação do objeto armazenado;
- execução exclusiva com `flock`;
- temporário privado e limpeza por `trap`;
- relatório consolidado e código de saída não zero diante de falhas;
- retenção adiada enquanto não houver mais que o mínimo de cópias configurado;
- arquivos de configuração interpretados por lista de chaves, sem execução via `source`.

O código vigente está somente em [`scripts/backup_run.sh`](../scripts/backup_run.sh). Não mantenha cópias integrais do script na documentação, pois elas divergem do executável.

## 3. Limites e requisitos

- Um checksum armazenado no mesmo provedor detecta corrupção, mas não protege contra comprometimento simultâneo do backup e do checksum.
- Backups do tipo `files` não são transacionalmente consistentes quando a origem muda durante o arquivamento. Bancos ativos exigem dump nativo, snapshot ou pausa coordenada.
- A passphrase deve ficar em cofre ou arquivo local com acesso mínimo, nunca no Git.
- O remote deve ter controle de acesso mínimo, lixeira/versionamento e, quando disponível, imutabilidade.
- Sucesso de upload não comprova restauração. O teste deve importar os dados em ambiente isolado e validar a aplicação.

## 4. Procedimento de restauração

1. Selecione um backup e seu `.sha256` sem alterar produção.
2. Baixe ambos para um diretório temporário com permissão `0700`.
3. Execute `sha256sum -c` antes de descriptografar.
4. Descriptografe com a passphrase obtida do cofre.
5. Extraia o arquivo e restaure em banco ou diretório isolado.
6. Valide esquema, quantidade de registros, consultas críticas e inicialização da aplicação.
7. Registre data, responsável, backup utilizado, duração, resultado e evidências.
8. Apague com segurança os dados claros temporários.

Uma restauração em produção exige janela autorizada, backup prévio do estado atual e plano de rollback.

## 5. Histórico de testes

O documento anterior registrava um teste em 2026-07-21 como bem-sucedido. Essa afirmação não foi revalidada nesta revisão local e não deve ser usada como evidência atual sem os logs e artefatos correspondentes. Novos testes devem ser adicionados aqui sem apagar os registros anteriores, distinguindo claramente resultado documentado de resultado comprovado.
