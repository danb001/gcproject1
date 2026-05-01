#!/bin/bash
# =============================================================================
# install-prestashop.sh
# Full LEMP + PrestaShop setup for Debian 12 on GCP e2-micro (1 GB RAM)
#
# Run as root:  sudo bash install-prestashop.sh
# Log file:     /var/log/prestashop-install.log
# =============================================================================

set -euo pipefail
exec > >(tee -a /var/log/prestashop-install.log) 2>&1

# ── Configuration — edit these before running ─────────────────────────────────

DB_NAME="prestashop"
DB_USER="psuser"
DB_PASS="$(openssl rand -base64 24)"   # auto-generated secure password
PS_VERSION="8.1.7"                     # latest stable as of 2025
PS_DIR="/var/www/prestashop"
PS_ADMIN_FOLDER="admin_secure"         # rename default /admin for security
DOMAIN=""                              # leave blank to use the server IP

# ── Colour helpers ────────────────────────────────────────────────────────────

GREEN='\033[0;32m'; YELLOW='\033[1;33m'; RED='\033[0;31m'; NC='\033[0m'
info()    { echo -e "${GREEN}[INFO]${NC}  $*"; }
warn()    { echo -e "${YELLOW}[WARN]${NC}  $*"; }
section() { echo -e "\n${GREEN}════════════════════════════════════${NC}"; \
            echo -e "${GREEN} $*${NC}"; \
            echo -e "${GREEN}════════════════════════════════════${NC}"; }

# ── Must run as root ──────────────────────────────────────────────────────────

if [[ $EUID -ne 0 ]]; then
  echo -e "${RED}[ERROR]${NC} Please run as root: sudo bash install-prestashop.sh"
  exit 1
fi

section "Step 1 — System update & swap"

# Create a 1 GB swap file — critical on a 1 GB RAM machine
if ! swapon --show | grep -q /swapfile; then
  info "Creating 1 GB swap file..."
  fallocate -l 1G /swapfile
  chmod 600 /swapfile
  mkswap /swapfile
  swapon /swapfile
  echo '/swapfile none swap sw 0 0' >> /etc/fstab
  # Tune swappiness for a low-RAM server
  echo 'vm.swappiness=10' >> /etc/sysctl.conf
  sysctl -p
  info "Swap created and enabled."
else
  info "Swap already exists — skipping."
fi

apt-get update -y
apt-get upgrade -y
apt-get install -y curl wget unzip git gnupg2 ca-certificates lsb-release apt-transport-https

section "Step 2 — Install Nginx"

apt-get install -y nginx
systemctl enable nginx
systemctl start nginx
info "Nginx installed: $(nginx -v 2>&1)"

section "Step 3 — Install MySQL"

apt-get install -y mariadb-server mariadb-client
systemctl enable mariadb
systemctl start mariadb

# Secure the installation non-interactively
mysql -u root <<EOF
-- Remove anonymous users
DELETE FROM mysql.user WHERE User='';
-- Remove remote root login
DELETE FROM mysql.user WHERE User='root' AND Host NOT IN ('localhost', '127.0.0.1', '::1');
-- Remove test database
DROP DATABASE IF EXISTS test;
DELETE FROM mysql.db WHERE Db='test' OR Db='test\\_%';
-- Create PrestaShop database and user
CREATE DATABASE IF NOT EXISTS ${DB_NAME} CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;
CREATE USER IF NOT EXISTS '${DB_USER}'@'localhost' IDENTIFIED BY '${DB_PASS}';
GRANT ALL PRIVILEGES ON ${DB_NAME}.* TO '${DB_USER}'@'localhost';
FLUSH PRIVILEGES;
EOF

info "MariaDB secured and PrestaShop database created."

section "Step 4 — Install PHP 8.1"

# Add Sury PHP repository (official Debian PHP packages)
curl -sSLo /usr/share/keyrings/deb.sury.org-php.gpg https://packages.sury.org/php/apt.gpg
echo "deb [signed-by=/usr/share/keyrings/deb.sury.org-php.gpg] https://packages.sury.org/php/ $(lsb_release -sc) main" \
  > /etc/apt/sources.list.d/php.list
apt-get update -y

apt-get install -y \
  php8.1-fpm \
  php8.1-mysql \
  php8.1-curl \
  php8.1-gd \
  php8.1-intl \
  php8.1-mbstring \
  php8.1-xml \
  php8.1-zip \
  php8.1-bcmath \
  php8.1-soap \
  php8.1-opcache \
  php8.1-fileinfo

info "PHP installed: $(php8.1 -v | head -1)"

# ── Tune PHP for 1 GB RAM ─────────────────────────────────────────────────────

PHP_INI="/etc/php/8.1/fpm/php.ini"
sed -i 's/^memory_limit.*/memory_limit = 256M/'         "$PHP_INI"
sed -i 's/^upload_max_filesize.*/upload_max_filesize = 64M/' "$PHP_INI"
sed -i 's/^post_max_size.*/post_max_size = 64M/'         "$PHP_INI"
sed -i 's/^max_execution_time.*/max_execution_time = 300/' "$PHP_INI"
sed -i 's/^max_input_vars.*/max_input_vars = 5000/'       "$PHP_INI"

# OPcache settings (speeds up PHP significantly)
cat >> "$PHP_INI" <<'EOF'

; OPcache tuned for e2-micro
opcache.enable=1
opcache.memory_consumption=64
opcache.interned_strings_buffer=8
opcache.max_accelerated_files=4000
opcache.revalidate_freq=60
EOF

# Tune PHP-FPM worker pool for low RAM
PHP_FPM_POOL="/etc/php/8.1/fpm/pool.d/www.conf"
sed -i 's/^pm = .*/pm = dynamic/'              "$PHP_FPM_POOL"
sed -i 's/^pm.max_children.*/pm.max_children = 5/'   "$PHP_FPM_POOL"
sed -i 's/^pm.start_servers.*/pm.start_servers = 2/' "$PHP_FPM_POOL"
sed -i 's/^pm.min_spare_servers.*/pm.min_spare_servers = 1/' "$PHP_FPM_POOL"
sed -i 's/^pm.max_spare_servers.*/pm.max_spare_servers = 3/' "$PHP_FPM_POOL"

systemctl enable php8.1-fpm
systemctl restart php8.1-fpm
info "PHP-FPM tuned and running."

section "Step 5 — Download PrestaShop ${PS_VERSION}"

mkdir -p "$PS_DIR"
cd /tmp

PS_ZIP="prestashop_${PS_VERSION}.zip"
PS_URL="https://github.com/PrestaShop/PrestaShop/releases/download/${PS_VERSION}/prestashop_${PS_VERSION}.zip"

info "Downloading PrestaShop ${PS_VERSION}..."
wget -q --show-progress -O "$PS_ZIP" "$PS_URL"

info "Extracting..."
unzip -q "$PS_ZIP" -d prestashop_extracted

# The zip contains another zip inside
if [[ -f prestashop_extracted/prestashop.zip ]]; then
  unzip -q prestashop_extracted/prestashop.zip -d "$PS_DIR"
else
  cp -r prestashop_extracted/. "$PS_DIR/"
fi

chown -R www-data:www-data "$PS_DIR"
find "$PS_DIR" -type d -exec chmod 755 {} \;
find "$PS_DIR" -type f -exec chmod 644 {} \;

# Rename admin folder for security
if [[ -d "${PS_DIR}/admin" ]]; then
  mv "${PS_DIR}/admin" "${PS_DIR}/${PS_ADMIN_FOLDER}"
  info "Admin folder renamed to /${PS_ADMIN_FOLDER}"
fi

rm -rf /tmp/prestashop_extracted /tmp/"$PS_ZIP"
info "PrestaShop files in place."

section "Step 6 — Configure Nginx"

# Detect server address
if [[ -n "$DOMAIN" ]]; then
  SERVER_NAME="$DOMAIN"
else
  SERVER_NAME=$(curl -s http://metadata.google.internal/computeMetadata/v1/instance/network-interfaces/0/access-configs/0/external-ip \
    -H "Metadata-Flavor: Google" 2>/dev/null || echo "_")
fi

cat > /etc/nginx/sites-available/prestashop <<EOF
server {
    listen 80;
    server_name ${SERVER_NAME};

    root ${PS_DIR};
    index index.php index.html;

    # Security headers
    add_header X-Frame-Options "SAMEORIGIN" always;
    add_header X-Content-Type-Options "nosniff" always;
    add_header X-XSS-Protection "1; mode=block" always;

    # Gzip compression (important on limited bandwidth)
    gzip on;
    gzip_types text/plain text/css application/json application/javascript text/xml application/xml;
    gzip_min_length 256;

    # Max upload size
    client_max_body_size 64M;

    location / {
        try_files \$uri \$uri/ /index.php?\$args;
    }

    location ~ [^/]\.php(/|\$) {
        fastcgi_pass unix:/run/php/php8.1-fpm.sock;
        fastcgi_index index.php;
        fastcgi_param SCRIPT_FILENAME \$document_root\$fastcgi_script_name;
        include fastcgi_params;
        fastcgi_read_timeout 300;
        fastcgi_buffers 16 16k;
        fastcgi_buffer_size 32k;
    }

    # PrestaShop friendly URLs
    rewrite ^/api/?(.\*)$ /webservice/dispatcher.php?url=\$1 last;

    # Block access to sensitive files
    location ~ /\. { deny all; }
    location ~ /(app|bin|cache|classes|config|controllers|docs|localization|override|src|tests|tools|translations|upload|var)/ {
        deny all;
    }

    # Cache static assets
    location ~* \.(jpg|jpeg|png|gif|ico|css|js|woff2?)$ {
        expires 30d;
        add_header Cache-Control "public, no-transform";
    }

    # Admin panel
    location ~* ^/${PS_ADMIN_FOLDER}/ {
        if (!-e \$request_filename) {
            rewrite ^/${PS_ADMIN_FOLDER}/(.*)$ /${PS_ADMIN_FOLDER}/index.php last;
        }
    }
}
EOF

ln -sf /etc/nginx/sites-available/prestashop /etc/nginx/sites-enabled/prestashop
rm -f /etc/nginx/sites-enabled/default

nginx -t && systemctl reload nginx
info "Nginx configured for PrestaShop."

section "Step 7 — Save credentials"

CREDS_FILE="/root/prestashop-credentials.txt"
cat > "$CREDS_FILE" <<EOF
========================================
  PrestaShop Installation Credentials
  $(date)
========================================

DATABASE
  Name:     ${DB_NAME}
  User:     ${DB_USER}
  Password: ${DB_PASS}
  Host:     localhost

SERVER
  Web root: ${PS_DIR}
  Admin URL path: /${PS_ADMIN_FOLDER}
  Server address: ${SERVER_NAME}

NEXT STEP
  Open your browser and go to:
  http://${SERVER_NAME}
  Complete the web installer to set your
  store name, admin email, and admin password.

AFTER INSTALL — run this to lock down the site:
  sudo rm -rf ${PS_DIR}/install
  sudo chmod 444 ${PS_DIR}/app/config/parameters.php
========================================
EOF

chmod 600 "$CREDS_FILE"

section "✅ Installation complete!"

echo ""
info "Your database password is saved at: ${CREDS_FILE}"
info "Read it with:  sudo cat ${CREDS_FILE}"
echo ""
warn "NEXT STEPS:"
echo "  1. Open http://${SERVER_NAME} in your browser"
echo "  2. Run through the PrestaShop web installer"
echo "     Use these DB credentials when prompted:"
echo "     DB name:     ${DB_NAME}"
echo "     DB user:     ${DB_USER}"
echo "     DB password: (run: sudo cat ${CREDS_FILE})"
echo ""
echo "  3. After the installer finishes, run:"
echo "     sudo rm -rf ${PS_DIR}/install"
echo "     sudo chmod 444 ${PS_DIR}/app/config/parameters.php"
echo ""
echo "  4. Your admin panel will be at:"
echo "     http://${SERVER_NAME}/${PS_ADMIN_FOLDER}"
echo ""
