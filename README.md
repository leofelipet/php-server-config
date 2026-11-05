# php-server-config

Servidor de sites PHP (WordPress / Laravel) **sem painel**, para Debian 13.

| Componente | Detalhe |
|---|---|
| Nginx | um vhost por site, HTTP→HTTPS, IP real da Cloudflare, hosts desconhecidos recusados |
| PHP-FPM | 8.4 (padrão) via packages.sury.org; um pool por site, rodando com usuário Linux próprio |
| MariaDB 11.8 | compatível com MySQL; aceita dumps do MySQL 8 (`utf8mb4_0900_ai_ci`) |
| Ferramentas | Composer, WP-CLI, Git |
| Segurança | UFW (22/80/443), fail2ban, atualizações automáticas, root só por chave |
| SFTP | usuários presos à pasta do site (chroot), senha e/ou chave |
| Backup | local, diário às 03:30, mantém 7 (`/var/backups/sites`) |

## Instalação (servidor zerado)

```bash
# da sua máquina
scp -r php-server-config root@IP:/root/
ssh root@IP 'bash /root/php-server-config/setup.sh'
```

Pré-requisito: sua chave SSH já em `/root/.ssh/authorized_keys` (o login por senha do root é desativado).
Pode rodar de novo quantas vezes quiser. Variáveis opcionais: `PHP_VERSIONS="8.4 8.3"`, `DEFAULT_PHP`, `TIMEZONE`, `SWAP_SIZE`, `LE_EMAIL`, `UPLOAD_MAX` (MB, padrão 1024).

## Uso do dia a dia

```bash
site create exemplo.com.br --wordpress --alias www.exemplo.com.br   # WordPress pronto (pt_BR)
site create app.exemplo.com.br --laravel                            # estrutura vazia p/ Laravel
site create app.exemplo.com.br --laravel --git git@github.com:org/app.git
site list
site info exemplo.com.br            # credenciais do banco / WP
site sftp-add exemplo.com.br joao   # acesso FileZilla (gera senha; --key "ssh-ed25519 ..." p/ chave)
site ssl exemplo.com.br --cert origin.pem --key origin.key
site wp exemplo.com.br plugin list
site run app.exemplo.com.br -- php artisan migrate --force
site help
```

## Estrutura de um site

```
/srv/www/<dominio>/        (root, raiz do chroot SFTP)
├── htdocs/                arquivos do site (Laravel: web root = htdocs/public)
├── logs/                  access.log, error.log, php-error.log
└── tmp/                   uploads temporários / sessões
```

- Credenciais: `/etc/site/sites/<dominio>.env` (só root)
- Personalizar nginx de um site: `/etc/nginx/sites-custom/<dominio>/*.conf` (sobrevive a regerações)
- Pool PHP: `/etc/php/<versão>/fpm/pool.d/<dominio>.conf`

## SSL com Cloudflare (Origin Certificate)

1. Cloudflare → SSL/TLS → **Origin Server** → *Create Certificate* (RSA, hostnames `exemplo.com.br, *.exemplo.com.br`, 15 anos).
2. Salve o certificado e a chave no servidor e rode `site ssl <dominio> --cert ... --key ...`.
3. SSL/TLS em **Full (strict)**: o modo global vale para a zona inteira. Para afetar só um host, use
   *Rules → Configuration Rules* (hostname igual a … → SSL: Full (strict)).
4. O registro DNS precisa estar **proxied** (nuvem laranja): o Origin Certificate só é aceito pela Cloudflare.

## Migrar um site do CloudPanel

```bash
# 1) na VM antiga
mysqldump --single-transaction --routines --triggers BANCO | gzip > site.sql.gz
tar -C /home/USUARIO/htdocs/DOMINIO -czf site-files.tar.gz .

# 2) na VM nova
site create dominio.com.br --php          # ou --laravel (não use --wordpress, que instala um WP novo)
tar -C /srv/www/dominio.com.br/htdocs -xzf site-files.tar.gz
site fix-perms dominio.com.br
site db-import dominio.com.br site.sql.gz
site info dominio.com.br                  # atualize wp-config.php / .env com o novo banco/usuário/senha
```

Para Laravel com web root em `public/`, crie com `--laravel`. Cron do Laravel: `crontab -u <usuario_do_site> -e`.

## Upload de arquivos grandes (ex: All-in-One WP Migration)

O servidor aceita uploads de até **1 GB** (`upload_max_filesize`, `post_max_size` e `client_max_body_size`; altere com `UPLOAD_MAX` e rode o setup de novo).

**Atenção: a Cloudflare (planos Free/Pro) recusa requisições acima de 100 MB** (erro 413), independentemente do servidor.
Para enviar um arquivo maior pelo navegador, passe por fora da Cloudflare temporariamente:

- **arquivo hosts** (recomendado): no seu computador, adicione `IP_DO_SERVIDOR  exemplo.com.br` ao
  `/etc/hosts` (Windows: `C:\Windows\System32\drivers\etc\hosts`), faça o upload e remova a linha.
  Como o certificado é Let's Encrypt, o HTTPS continua válido.
- ou deixe o registro DNS como *DNS only* (nuvem cinza) durante a importação.
- ou envie o arquivo por SFTP (ex: para `wp-content/ai1wm-backups/`) e restaure pelo painel do plugin.

## Envio de e-mail

O servidor não envia e-mail diretamente (a maioria dos provedores bloqueia ou marca como spam).
Use SMTP autenticado: plugin *WP Mail SMTP* no WordPress, `MAIL_*` no `.env` do Laravel.
