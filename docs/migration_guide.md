# Guia de Migração de Servidores e Onboarding Seguro

> **Aviso de escopo:** os exemplos de aplicação, banco e Docker Compose abaixo são modelos históricos, não componentes deste repositório. A arquitetura vigente está no [README](../README.md).

O que acontece quando precisamos migrar nossa aplicação para uma nova infraestrutura física ou lógica? O medo de perda de dados e de indisponibilidade prolongada costuma assombrar esses processos. No entanto, com um protocolo rigoroso de migração, mapeamento prévio de recursos e canais transparentes de comunicação, podemos realizar transições de servidores com risco quase nulo. Este guia estabelece o procedimento passo a passo para configuração de acesso seguro, diagnóstico do sistema de origem, empacotamento, transferência de dados e comunicação operacional.

---

## 1. Configuração de Acesso SSH Seguro (Server Hardening)

Segurança é o primeiro requisito ao provisionar um novo servidor. Siga os passos abaixo no servidor de destino para desativar senhas e autenticar-se apenas via chaves SSH fortes.

### 1.1 Gerar Chave SSH na Máquina Local (Padrão ED25519)
1.  Abra o terminal local e execute:
    ```bash
    ssh-keygen -t ed25519 -C "admin-bkp-rclone" -f ~/.ssh/id_ed25519_bkp_rclone
    ```
2.  Copie a chave pública gerada para o servidor de destino:
    ```bash
    ssh-copy-id -i ~/.ssh/id_ed25519_bkp_rclone.pub <USER>@<DESTINATION_SERVER_IP>
    ```

### 1.2 Configurar o Arquivo de Configuração do SSH no Servidor
1.  Acesse o servidor de destino e abra o arquivo `/etc/ssh/sshd_config` utilizando privilégios de superusuário:
    ```bash
    sudo nano /etc/ssh/sshd_config
    ```
2.  Garanta que as seguintes diretivas estejam configuradas exatamente como abaixo para mitigar ataques de força bruta:
    ```ini
    PermitRootLogin no
    PasswordAuthentication no
    PubkeyAuthentication yes
    AuthorizedKeysFile .ssh/authorized_keys
    ```
3.  Salve o arquivo pressionando **CTRL+O**, confirme com **Enter** e saia com **CTRL+X**.
4.  Valide a sintaxe do arquivo de configuração do SSH:
    ```bash
    sudo sshd -t
    ```
5.  Se o teste de sintaxe for bem-sucedido, reinicie o serviço SSH:
    ```bash
    sudo systemctl restart ssh
    ```

---

## 2. Diagnóstico de Recursos do Servidor (Somente Leitura)

Antes de iniciar a migração, faça uma auditoria rápida no servidor de origem para entender a carga de recursos e garantir que as conexões de rede necessárias estejam ativas.

### 2.1 Verificar Portas Ativas e Processos escutando
Para listar todas as portas TCP sob escuta no servidor:
```bash
ss -tulpn
```

### 2.2 Diagnosticar Uso de CPU e Memória RAM
Para verificar a memória RAM livre e em uso no sistema de forma legível por humanos:
```bash
free -h
```
Para obter o uso em tempo real de CPU e memória RAM de containers Docker ativos:
```bash
docker stats --no-stream
```

### 2.3 Verificar Espaço em Disco
Para garantir que temos espaço suficiente para gerar dumps de banco de dados e arquivos compactados:
```bash
df -h
```

### 2.4 Testar Conectividade com Mattermost (Resolução de DNS e Latência)
Para garantir que o servidor consegue enviar notificações aos canais operacionais do Mattermost:
```bash
curl -i -X POST -H 'Content-Type: application/json' --data '{"text":"Teste de conexao"}' <MATTERMOST_WEBHOOK_URL>
```
Se a rede local possuir regras de firewall rígidas, verifique a resolução de DNS do domínio do Mattermost:
```bash
nslookup <TODO: DEFINIR — ex: mattermost.empresa.com>
```

---

## 3. Checklist de Congelamento de Dados e Dump do Banco

Para evitar inconsistências (incompatibilidade de transações entre o servidor antigo e o novo), devemos realizar o congelamento de gravação de dados antes de exportar o banco.

### 3.1 Procedimento de Congelamento de Dados
1.  Comunique a equipe de que a manutenção foi iniciada no canal do Mattermost.
2.  Interrompa o tráfego da aplicação web alterando a rota do Proxy Reverso (Nginx) para uma página de manutenção, ou simplesmente parando o container do backend:
    ```bash
    docker compose stop web
    ```

### 3.2 Executar Dump do Banco de Dados (PostgreSQL)
Para extrair os dados de produção de forma segura sem expor senhas no terminal, utilize as variáveis de ambiente integradas do Docker:
```bash
docker compose exec db pg_dump -U <TODO: DEFINIR — ex: postgres_user> -d <TODO: DEFINIR — ex: app_db> -F c -f /var/lib/postgresql/data/bkp_rclone_migration_dump.sql
```
*(Nota: O dump gerado ficará acessível no volume persistente mapeado localmente para o container de banco de dados).*

---

## 4. Compactação, Geração de Hashes e Transferência Segura

Após gerar o dump do banco, compacte-o junto com os demais volumes necessários (arquivos estáticos, uploads, etc.) e valide o arquivo antes do envio.

### 4.1 Compactar Arquivos e Volumes
Navegue até o diretório onde os volumes locais do Docker estão armazenados e compacte a estrutura:
```bash
tar -czvf bkp_rclone_volumes.tar.gz -C /home/vier/Documentos/Code/CDC/BKP\ Rclone/data .
```

### 4.2 Gerar Hash SHA-256 para Verificação de Integridade
Sempre gere uma assinatura hash do arquivo gerado para que possamos validar que nenhum bit foi corrompido durante a transferência pela rede:
```bash
sha256sum bkp_rclone_volumes.tar.gz > bkp_rclone_volumes.tar.gz.sha256
```

### 4.3 Transferir via SCP Utilizando a Chave SSH
Transfira os arquivos de dump compactados e as assinaturas hashes para o servidor de destino:
```bash
scp -i ~/.ssh/id_ed25519_bkp_rclone bkp_rclone_volumes.tar.gz bkp_rclone_volumes.tar.gz.sha256 <USER>@<DESTINATION_SERVER_IP>:/tmp/
```

### 4.4 Validar Integridade no Servidor de Destino
Acesse o servidor de destino, acesse o diretório `/tmp` e verifique a assinatura SHA-256:
```bash
cd /tmp
sha256sum -c bkp_rclone_volumes.tar.gz.sha256
```
**Critério de Validação:** A saída deve exibir obrigatoriamente: `bkp_rclone_volumes.tar.gz: OK`.

---

## 5. Roteiro de Comunicação de Janela de Manutenção no Mattermost

Toda intervenção em produção deve ser previamente acordada e notificada no canal `#ops-deploy` para manter a governança organizacional.

```
--- JANELA DE MANUTENÇÃO: MIGRACAO DE SERVIDOR ---
```

### 5.1 Mensagem de Início da Janela (Mattermost)
```json
{
  "username": "Esteira de Migração",
  "text": "### :warning: **Início de Janela de Manutenção**\n* **Ação:** Migração do servidor de banco e aplicação para nova infraestrutura física.\n* **Previsão de Indisponibilidade:** 15 minutos.\n* **Responsável:** Engenharia de Infraestrutura.\n* **Objetivo:** Melhoria na escalabilidade e atualização de segurança no SO base."
}
```

### 5.2 Mensagem de Status (Andamento)
```json
{
  "username": "Esteira de Migração",
  "text": "### :hourglass_flowing_sand: **Atualização de Status - Migração**\n* **Status:** Dados extraídos com sucesso. Compactação e transferência dos volumes em andamento.\n* **Próxima Etapa:** Importação dos dumps no servidor de destino e testes de sanidade operacional."
}
```

### 5.3 Mensagem de Conclusão da Janela (Mattermost)
```json
{
  "username": "Esteira de Migração",
  "text": "### :white_check_mark: **Janela de Manutenção Concluída**\n* **Status:** Todos os containers provisionados no servidor de destino.\n* **Validações:** Banco de dados restaurado, checksums de arquivos validados e testes de API com retorno **200 OK**.\n* **Sistema:** Online e totalmente operacional."
}
```
Se a migração apresentar problemas de rede ou falha ao restaurar banco no novo servidor, consulte imediatamente o documento [troubleshooting.md](./troubleshooting.md) para ações de mitigação rápida.
