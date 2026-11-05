# CLAUDE.md

Servidor PHP **sem painel** (substitui uma VM com CloudPanel). Dois artefatos:

- `setup.sh` — provisiona um Debian 13 zerado. **Deve continuar idempotente** (rodar de novo = só atualiza).
- `bin/site` — CLI de gestão (instalada em `/usr/local/sbin/site`). Toda lógica por-site vive aqui.

Contexto: alguns sites (mistura WordPress/Laravel, todos MySQL) atrás da Cloudflare. Na migração só vêm arquivos + banco; nenhuma configuração do servidor antigo. Usuário escreve em pt-BR — mensagens dos scripts e docs em pt-BR.

## Fluxo de mudança

1. Editar `bin/site` / `setup.sh` localmente; `bash -n` em ambos.
2. Testar no **servidor de laboratório** (nunca direto em produção): copiar e rodar
   `scp -r . root@LAB:/root/php-server-config/ && ssh root@LAB 'bash /root/php-server-config/setup.sh'`
3. Se mudou template de vhost/pool: `site regen --all`.
4. Validar de verdade (curl com `--resolve`, login SFTP, `wp core verify-checksums`), não só "rodou sem erro".
5. Atualizar `README.md` (uso) e este arquivo (decisões) quando algo mudar.

Dados do laboratório atual (IP, domínio de teste): ver `CLAUDE.local.md` (fora do Git).

## Arquitetura e decisões (com o porquê)

**Layout de um site**
```
/srv/www/<dominio>/     root:root 755   ← raiz do chroot SFTP (OpenSSH exige root e não gravável)
├── htdocs/             <user>:<user> 2770   (Laravel: web root = htdocs/public)
├── logs/               root:<user>   2770   (nginx access/error + php-error.log)
└── tmp/                <user>:<user> 2770   (upload_tmp_dir, sessões)
```
- Estado de cada site: `/etc/site/sites/<dominio>.env` (root 600) — inclui senhas de banco/WP. Fonte da verdade para a CLI.
- Usuário Linux por site (derivado do domínio, ex. `exemplo.com.br` → `exemplo`), home em `/home/<user>` (não no chroot, para git/composer terem `$HOME` gravável).

**Isolamento / permissões**
- Um pool PHP-FPM por site rodando como o usuário do site; socket `/run/php/site-<user>.sock` (independe da versão PHP → trocar versão não mexe no vhost).
- `www-data` (nginx) é adicionado ao grupo de cada site; nada é world-readable (`o=`).
- **umask 0007 em todo lugar** (systemd override do php-fpm, `internal-sftp -u 0007`, `as_site`): arquivos criados por PHP e por SFTP ficam editáveis pelo grupo. Bug já ocorrido: `umask 077` vazou de uma função e deixou tudo ilegível para o nginx — nunca usar `umask` global fora de subshell.

**SFTP**
- Usuários SFTP: grupo `sftponly`, home = `/srv/www/<dominio>`, grupo primário = grupo do site, shell `nologin`.
- `Match Group sftponly` com `ChrootDirectory %h` + `ForceCommand internal-sftp` em `/etc/ssh/sshd_config.d/99-sftp-sites.conf` (arquivo separado, último). Senha permitida só para esse grupo; root só por chave.
- Chaves em `/etc/ssh/authorized_keys/<usuario>` (vários usuários compartilham o mesmo home/chroot).
- Acesso é sempre de 1 site inteiro. Limite por subpasta **não implementado** (ideia: ChrootDirectory continua no site, mas home/permissões apontando para subpasta, ou bind mount).

**SSL**
- Let's Encrypt via `certbot certonly --webroot -w /var/www/acme` (webroot compartilhado, servido em 80 e 443 para `/.well-known/acme-challenge/`). Funciona atrás da Cloudflare proxied porque a CF repassa HTTP. Escolhido no lugar do Cloudflare Origin Certificate porque o usuário achou o processo da CF trabalhoso.
- `/etc/ssl/sites/<dominio>.crt` e `private/<dominio>.key` são symlinks para `/etc/letsencrypt/live/...` (ou arquivos reais se `--cert/--key`). Vhost sempre aponta para esses caminhos.
- Antes de chamar o certbot, `acme_reachable` testa cada nome via HTTP público; nomes que não chegam são ignorados (evita rate limit de falhas do LE). Sem DNS → mantém certificado autoassinado e avisa.
- Renovação: `certbot.timer` + deploy hook que recarrega o nginx.

**WordPress**
- Baixado do `.zip` oficial via API `api.wordpress.org/core/version-check/1.7/?locale=pt_BR` — **não usar `wp core download`**: ele extrai `.tar.gz` e trunca caminhos > 100 caracteres, quebrando o core (detectado por `verify-checksums`).
- Após instalar sempre roda `wp core verify-checksums`. `FS_METHOD=direct` (updates/plugins pelo painel funcionam).

**Banco**
- MariaDB 11.8 (Debian) no lugar de MySQL: aceita dumps do MySQL 8 (`utf8mb4_0900_ai_ci`). `site db-import` remove `DEFINER=` (CloudPanel usa usuários que não existem aqui).
- Root do MariaDB via unix_socket; usuário do site criado em `localhost` e `127.0.0.1` (Laravel usa TCP).

**Nginx**
- `setup.sh` escreve o `nginx.conf` inteiro (o do Debian já define gzip/ssl/server_tokens e causava diretivas duplicadas). Original salvo em `nginx.conf.dist`.
- Default server devolve 444 / `ssl_reject_handshake` para hosts desconhecidos.
- IP real da Cloudflare: `/usr/local/sbin/update-cloudflare-ips` (cron semanal).
- Personalização por site sem perder em `regen`: `/etc/nginx/sites-custom/<dominio>/*.conf`.

**PHP**
- Repositório packages.sury.org para várias versões lado a lado (`site php-install X`, `site php <dominio> X`). Padrão 8.4.
- Configuração comum de PHP fica em `cmd_php_install` (o `setup.sh` chama `site php-install`, sem duplicar código).

## Fora de escopo / pendências conhecidas
- Envio de e-mail: servidor não envia direto; usar SMTP autenticado (WP Mail SMTP / `MAIL_*` do Laravel).
- Backup é só local (`/var/backups/sites`, 7 dias). Backup externo (restic/borg) ainda não implementado.
- Sem monitoramento (Uptime Kuma etc.) e sem fila/worker gerenciado para Laravel (`crontab -u <user>` manual).
- Plano original de referência: documento interno (fora do Git; ver `CLAUDE.local.md`).
