#!/usr/bin/env bash
# =============================================================================
#  setup.sh — Provisiona um servidor Debian 13 para hospedar sites PHP
#             (WordPress / Laravel) SEM painel.
#
#  Stack: Nginx + PHP-FPM (pool por site) + MariaDB + Composer + WP-CLI + Git
#         UFW + fail2ban + unattended-upgrades + SFTP chroot por site
#
#  Uso (como root, no servidor):
#     bash setup.sh
#
#  Pode ser executado várias vezes (idempotente).
#  Variáveis opcionais (export antes de rodar):
#     PHP_VERSIONS="8.4"          versões PHP a instalar (ex: "8.4 8.3")
#     DEFAULT_PHP="8.4"           versão padrão para novos sites
#     TIMEZONE="America/Sao_Paulo"
#     SWAP_SIZE="2G"              "0" para não criar swap
#     UPLOAD_MAX="1024"           limite de upload em MB (PHP + nginx)
#     LE_EMAIL="voce@exemplo.com"  e-mail da conta Let's Encrypt (opcional)
# =============================================================================
set -euo pipefail

PHP_VERSIONS="${PHP_VERSIONS:-8.4}"
DEFAULT_PHP="${DEFAULT_PHP:-8.4}"
TIMEZONE="${TIMEZONE:-America/Sao_Paulo}"
SWAP_SIZE="${SWAP_SIZE:-2G}"
UPLOAD_MAX="${UPLOAD_MAX:-1024}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
export DEBIAN_FRONTEND=noninteractive

log()  { printf '\n\033[1;34m==> %s\033[0m\n' "$*"; }
ok()   { printf '\033[1;32m    ✔ %s\033[0m\n' "$*"; }
die()  { printf '\033[1;31mERRO: %s\033[0m\n' "$*" >&2; exit 1; }

[[ $EUID -eq 0 ]] || die "execute como root"
. /etc/os-release
[[ "${VERSION_CODENAME:-}" == "trixie" ]] || echo "AVISO: script feito para Debian 13 (trixie); detectado ${PRETTY_NAME}"
[[ -f "$SCRIPT_DIR/bin/site" ]] || die "arquivo bin/site não encontrado ao lado do setup.sh"
[[ -s /root/.ssh/authorized_keys ]] || die "/root/.ssh/authorized_keys vazio — configure chave SSH antes (o login por senha será desativado)"

# -----------------------------------------------------------------------------
log "Sistema base"
timedatectl set-timezone "$TIMEZONE" 2>/dev/null || ln -sf "/usr/share/zoneinfo/$TIMEZONE" /etc/localtime
apt-get update -q
apt-get -y -q full-upgrade
apt-get install -y -q \
  ca-certificates curl wget gnupg lsb-release apt-transport-https \
  git unzip zip zstd rsync htop ncdu less vim nano jq openssl acl \
  ufw fail2ban python3-systemd unattended-upgrades apt-listchanges \
  cron logrotate
ok "pacotes base"

# swap
if [[ "$SWAP_SIZE" != "0" ]] && ! swapon --show | grep -q .; then
  fallocate -l "$SWAP_SIZE" /swapfile
  chmod 600 /swapfile
  mkswap /swapfile >/dev/null
  swapon /swapfile
  grep -q '^/swapfile' /etc/fstab || echo '/swapfile none swap sw 0 0' >> /etc/fstab
  echo 'vm.swappiness=10' > /etc/sysctl.d/60-swappiness.conf
  sysctl -q -p /etc/sysctl.d/60-swappiness.conf
  ok "swap $SWAP_SIZE criado"
fi

# atualizações automáticas de segurança
cat > /etc/apt/apt.conf.d/20auto-upgrades <<'EOF'
APT::Periodic::Update-Package-Lists "1";
APT::Periodic::Unattended-Upgrade "1";
APT::Periodic::AutocleanInterval "7";
EOF
ok "unattended-upgrades ativo"

# -----------------------------------------------------------------------------
log "Repositório PHP (packages.sury.org) — permite várias versões lado a lado"
if [[ ! -f /etc/apt/sources.list.d/php.sources ]]; then
  curl -fsSLo /tmp/debsuryorg-archive-keyring.deb https://packages.sury.org/debsuryorg-archive-keyring.deb
  dpkg -i /tmp/debsuryorg-archive-keyring.deb >/dev/null
  rm -f /tmp/debsuryorg-archive-keyring.deb
  cat > /etc/apt/sources.list.d/php.sources <<EOF
Types: deb
URIs: https://packages.sury.org/php/
Suites: ${VERSION_CODENAME}
Components: main
Signed-By: /usr/share/keyrings/debsuryorg-archive-keyring.gpg
EOF
  apt-get update -q
fi
ok "repositório PHP"

# -----------------------------------------------------------------------------
log "Nginx"
apt-get install -y -q nginx
install -d -m 755 /etc/nginx/snippets /etc/ssl/sites
install -d -m 700 /etc/ssl/sites/private

# certificado autoassinado para o default server
if [[ ! -f /etc/ssl/sites/default.crt ]]; then
  openssl req -x509 -nodes -newkey rsa:2048 -days 3650 \
    -subj "/CN=default" \
    -keyout /etc/ssl/sites/private/default.key -out /etc/ssl/sites/default.crt 2>/dev/null
fi

[[ -f /etc/nginx/nginx.conf.dist ]] || cp -a /etc/nginx/nginx.conf /etc/nginx/nginx.conf.dist
cat > /etc/nginx/nginx.conf <<'EOF'
# Gerenciado por setup.sh (original em nginx.conf.dist)
user www-data;
worker_processes auto;
worker_cpu_affinity auto;
worker_rlimit_nofile 65535;
pid /run/nginx.pid;
error_log /var/log/nginx/error.log;
include /etc/nginx/modules-enabled/*.conf;

events {
    worker_connections 4096;
    multi_accept on;
}

http {
    sendfile on;
    tcp_nopush on;
    tcp_nodelay on;
    include /etc/nginx/mime.types;
    default_type application/octet-stream;
    access_log /var/log/nginx/access.log;

    include /etc/nginx/conf.d/*.conf;
    include /etc/nginx/sites-enabled/*;
}
EOF

cat > /etc/nginx/conf.d/00-tuning.conf <<'EOF'
# Gerenciado por setup.sh
server_tokens off;
client_max_body_size __UPLOAD_MAX__m;
client_body_timeout 60s;
keepalive_timeout 30s;
types_hash_max_size 4096;
server_names_hash_bucket_size 128;

gzip on;
gzip_vary on;
gzip_proxied any;
gzip_comp_level 5;
gzip_min_length 1024;
gzip_types text/plain text/css text/xml application/json application/javascript
           application/xml application/rss+xml application/atom+xml image/svg+xml
           font/ttf font/otf application/vnd.ms-fontobject;

ssl_protocols TLSv1.2 TLSv1.3;
ssl_prefer_server_ciphers off;
ssl_session_cache shared:SSL:20m;
ssl_session_timeout 1d;
ssl_session_tickets off;

fastcgi_read_timeout 300s;
fastcgi_buffers 16 16k;
fastcgi_buffer_size 32k;

map $http_upgrade $connection_upgrade { default upgrade; '' close; }
EOF
sed -i "s/__UPLOAD_MAX__/${UPLOAD_MAX}/" /etc/nginx/conf.d/00-tuning.conf

# segurança comum a todos os sites
cat > /etc/nginx/snippets/site-security.conf <<'EOF'
# Gerenciado por setup.sh
add_header X-Content-Type-Options "nosniff" always;
add_header X-Frame-Options "SAMEORIGIN" always;
add_header Referrer-Policy "strict-origin-when-cross-origin" always;

location ^~ /.well-known/ { allow all; }
# arquivos/diretórios ocultos (.git, .env, .htaccess ...)
location ~ /\.(?!well-known) { deny all; access_log off; log_not_found off; }
# arquivos sensíveis
location ~* \.(sql|sql\.gz|bak|old|orig|swp|log|ini|sh|dist|lock)$ { deny all; }
location ~* /(composer\.(json|lock)|package(-lock)?\.json|artisan|wp-config\.php\.bak)$ { deny all; }

location = /favicon.ico { log_not_found off; access_log off; }
location = /robots.txt  { log_not_found off; access_log off; try_files $uri /index.php?$args; }

location ~* \.(?:css|js|mjs|map|jpg|jpeg|gif|png|webp|avif|ico|svg|woff2?|ttf|otf|eot|mp4|webm|pdf)$ {
    expires 30d;
    access_log off;
    try_files $uri =404;
}
EOF

cat > /etc/nginx/snippets/wordpress.conf <<'EOF'
# Gerenciado por setup.sh
location / { try_files $uri $uri/ /index.php?$args; }
location = /xmlrpc.php { deny all; access_log off; }
location ~* ^/wp-content/uploads/.*\.php$ { deny all; }
location ~* ^/wp-includes/[^/]+\.php$ { deny all; }
location ~* ^/wp-includes/js/tinymce/langs/.+\.php$ { deny all; }
EOF

cat > /etc/nginx/snippets/laravel.conf <<'EOF'
# Gerenciado por setup.sh
location / { try_files $uri $uri/ /index.php?$query_string; }
EOF

cat > /etc/nginx/snippets/generic.conf <<'EOF'
# Gerenciado por setup.sh
location / { try_files $uri $uri/ /index.php?$args; }
EOF

cat > /etc/nginx/snippets/php-site.conf <<'EOF'
# Gerenciado por setup.sh — incluído dentro de "location ~ \.php$"
try_files $fastcgi_script_name =404;
fastcgi_split_path_info ^(.+\.php)(/.+)$;
include fastcgi_params;
fastcgi_param SCRIPT_FILENAME $realpath_root$fastcgi_script_name;
fastcgi_param DOCUMENT_ROOT   $realpath_root;
fastcgi_param PATH_INFO       $fastcgi_path_info;
fastcgi_param HTTPS           on;
fastcgi_param HTTP_PROXY      "";
fastcgi_index index.php;
EOF

# default server: recusa qualquer host não configurado
rm -f /etc/nginx/sites-enabled/default
cat > /etc/nginx/sites-available/000-default.conf <<'EOF'
# Gerenciado por setup.sh — hosts desconhecidos são recusados
server {
    listen 80 default_server;
    listen [::]:80 default_server;
    server_name _;
    return 444;
}
server {
    listen 443 ssl default_server;
    listen [::]:443 ssl default_server;
    server_name _;
    ssl_certificate     /etc/ssl/sites/default.crt;
    ssl_certificate_key /etc/ssl/sites/private/default.key;
    ssl_reject_handshake on;
}
EOF
ln -sf /etc/nginx/sites-available/000-default.conf /etc/nginx/sites-enabled/000-default.conf
ok "nginx configurado"

# Let's Encrypt (validação HTTP-01 via webroot compartilhado; funciona atrás da Cloudflare)
apt-get install -y -q certbot
install -d -m 755 /var/www/acme/.well-known/acme-challenge
if [[ ! -d /etc/letsencrypt/accounts ]] || [[ -z $(ls -A /etc/letsencrypt/accounts 2>/dev/null) ]]; then
  if [[ -n ${LE_EMAIL:-} ]]; then
    certbot register --non-interactive --agree-tos --no-eff-email -m "$LE_EMAIL" >/dev/null
  else
    certbot register --non-interactive --agree-tos --register-unsafely-without-email >/dev/null
  fi
fi
install -d -m 755 /etc/letsencrypt/renewal-hooks/deploy
cat > /etc/letsencrypt/renewal-hooks/deploy/reload-nginx <<'EOF'
#!/bin/sh
# Gerenciado por setup.sh
nginx -t -q && systemctl reload nginx
EOF
chmod 755 /etc/letsencrypt/renewal-hooks/deploy/reload-nginx
systemctl enable -q --now certbot.timer
ok "certbot (renovação automática: certbot.timer)"

# IPs reais da Cloudflare
cat > /usr/local/sbin/update-cloudflare-ips <<'EOF'
#!/usr/bin/env bash
# Atualiza /etc/nginx/conf.d/cloudflare-realip.conf com os ranges da Cloudflare
set -euo pipefail
out=/etc/nginx/conf.d/cloudflare-realip.conf
tmp=$(mktemp)
v4=$(curl -fsS --max-time 20 https://www.cloudflare.com/ips-v4) || exit 0
v6=$(curl -fsS --max-time 20 https://www.cloudflare.com/ips-v6) || exit 0
{
  echo "# Gerado por update-cloudflare-ips em $(date -Is)"
  for ip in $v4 $v6; do echo "set_real_ip_from $ip;"; done
  echo "real_ip_header CF-Connecting-IP;"
} > "$tmp"
if ! cmp -s "$tmp" "$out"; then
  install -m 644 "$tmp" "$out"
  nginx -t -q && systemctl reload nginx
fi
rm -f "$tmp"
EOF
chmod 755 /usr/local/sbin/update-cloudflare-ips
/usr/local/sbin/update-cloudflare-ips || true
cat > /etc/cron.d/update-cloudflare-ips <<'EOF'
17 4 * * 1 root /usr/local/sbin/update-cloudflare-ips >/dev/null 2>&1
EOF
ok "real IP da Cloudflare"

# -----------------------------------------------------------------------------
log "Ferramenta 'site'"
install -d -m 700 /etc/site /etc/site/sites
install -d -m 755 /srv/www
install -d -m 700 /var/backups/sites
cat > /etc/site/site.conf <<EOF
# Gerenciado por setup.sh
DEFAULT_PHP="$DEFAULT_PHP"
WWW_ROOT="/srv/www"
BACKUP_DIR="/var/backups/sites"
TIMEZONE="$TIMEZONE"
UPLOAD_MAX="$UPLOAD_MAX"
EOF
install -m 755 "$SCRIPT_DIR/bin/site" /usr/local/sbin/site
ok "/usr/local/sbin/site instalado"

# -----------------------------------------------------------------------------
log "PHP: $PHP_VERSIONS"
for v in $PHP_VERSIONS; do /usr/local/sbin/site php-install "$v"; done
update-alternatives --set php "/usr/bin/php$DEFAULT_PHP" >/dev/null 2>&1 || true

# Composer
if ! command -v composer >/dev/null; then
  EXPECTED=$(curl -fsS https://composer.github.io/installer.sig)
  curl -fsSLo /tmp/composer-setup.php https://getcomposer.org/installer
  ACTUAL=$(php -r "echo hash_file('sha384', '/tmp/composer-setup.php');")
  [[ "$EXPECTED" == "$ACTUAL" ]] || die "checksum do instalador do Composer não confere"
  php /tmp/composer-setup.php --quiet --install-dir=/usr/local/bin --filename=composer
  rm -f /tmp/composer-setup.php
fi
ok "Composer $(composer --version 2>/dev/null | awk '{print $3}')"

# WP-CLI
if ! command -v wp >/dev/null; then
  curl -fsSLo /usr/local/bin/wp https://raw.githubusercontent.com/wp-cli/builds/gh-pages/phar/wp-cli.phar
  chmod 755 /usr/local/bin/wp
fi
ok "WP-CLI $(wp --allow-root --version 2>/dev/null | awk '{print $2}')"

# -----------------------------------------------------------------------------
log "MariaDB"
apt-get install -y -q mariadb-server mariadb-client
cat > /etc/mysql/mariadb.conf.d/90-site-tuning.cnf <<'EOF'
# Gerenciado por setup.sh
[mysqld]
bind-address            = 127.0.0.1
max_connections         = 200
innodb_buffer_pool_size = 1G
innodb_log_file_size    = 256M
innodb_flush_log_at_trx_commit = 2
character-set-server    = utf8mb4
collation-server        = utf8mb4_unicode_ci
skip-name-resolve
EOF
systemctl enable -q mariadb
systemctl restart mariadb
# equivalente ao mysql_secure_installation (root continua via unix_socket)
mariadb -e "DELETE FROM mysql.global_priv WHERE User='';
            DELETE FROM mysql.global_priv WHERE User='root' AND Host NOT IN ('localhost','127.0.0.1','::1');
            DROP DATABASE IF EXISTS test;
            DELETE FROM mysql.db WHERE Db='test' OR Db='test\\_%';
            FLUSH PRIVILEGES;"
ok "MariaDB $(mariadb --version | grep -oP '\d+\.\d+\.\d+-MariaDB' | head -1)"

# -----------------------------------------------------------------------------
log "SSH / SFTP"
getent group sftponly >/dev/null || groupadd --system sftponly
install -d -m 755 /etc/ssh/authorized_keys

cat > /etc/ssh/sshd_config.d/10-hardening.conf <<'EOF'
# Gerenciado por setup.sh
PermitRootLogin prohibit-password
PasswordAuthentication no
KbdInteractiveAuthentication no
PubkeyAuthentication yes
MaxAuthTries 4
LoginGraceTime 30
X11Forwarding no
# chaves dos usuários SFTP ficam em /etc/ssh/authorized_keys/<usuario>
AuthorizedKeysFile .ssh/authorized_keys /etc/ssh/authorized_keys/%u
EOF

# Match block em arquivo separado (por último), para não capturar outras diretivas
cat > /etc/ssh/sshd_config.d/99-sftp-sites.conf <<'EOF'
# Gerenciado por setup.sh — usuários SFTP presos ao diretório do site
Match Group sftponly
    ChrootDirectory %h
    ForceCommand internal-sftp -u 0007
    PasswordAuthentication yes
    # clientes como o FileZilla oferecem todas as chaves do agente SSH antes da senha;
    # com várias chaves, o limite global (4) esgota antes de tentar a senha
    MaxAuthTries 10
    AllowTcpForwarding no
    AllowAgentForwarding no
    PermitTunnel no
    X11Forwarding no
EOF
sshd -t || die "configuração do sshd inválida"
systemctl reload ssh
ok "sshd: root só por chave; grupo sftponly com chroot (senha ou chave)"

# -----------------------------------------------------------------------------
log "Firewall (UFW) e fail2ban"
ufw --force default deny incoming >/dev/null
ufw --force default allow outgoing >/dev/null
ufw allow 22/tcp  >/dev/null
ufw allow 80/tcp  >/dev/null
ufw allow 443/tcp >/dev/null
ufw --force enable >/dev/null
ok "UFW: 22, 80, 443"

cat > /etc/fail2ban/jail.d/sites.local <<'EOF'
# Gerenciado por setup.sh
[DEFAULT]
backend   = systemd
banaction = ufw
bantime   = 1h
findtime  = 10m
maxretry  = 5

[sshd]
enabled = true
EOF
systemctl enable -q fail2ban
systemctl restart fail2ban
ok "fail2ban (sshd)"

# -----------------------------------------------------------------------------
log "Logs e backups"
cat > /etc/logrotate.d/sites <<'EOF'
# Gerenciado por setup.sh
/srv/www/*/logs/*.log {
    su root root
    daily
    rotate 14
    missingok
    notifempty
    compress
    delaycompress
    sharedscripts
    postrotate
        [ -s /run/nginx.pid ] && kill -USR1 "$(cat /run/nginx.pid)"
    endscript
}
EOF
cat > /etc/cron.d/site-backup <<'EOF'
# Gerenciado por setup.sh — backup local diário de todos os sites (mantém 7)
30 3 * * * root /usr/local/sbin/site backup --all --keep 7 >/var/log/site-backup.log 2>&1
EOF
ok "logrotate + backup diário local (03:30)"

nginx -t || die "configuração do nginx inválida"
systemctl reload-or-restart nginx

log "Concluído"
cat <<EOF

  Nginx     $(nginx -v 2>&1 | cut -d/ -f2)
  PHP       $PHP_VERSIONS (padrão $DEFAULT_PHP)
  MariaDB   $(mariadb --version | grep -oP '\d+\.\d+\.\d+' | head -1)
  Git       $(git --version | awk '{print $3}')

  Próximos passos:
    site create exemplo.com.br --wordpress
    site help
EOF
