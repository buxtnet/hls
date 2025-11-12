#!/usr/bin/env bash
set -euo pipefail

if [ "$(id -u)" -ne 0 ]; then
  exit 1
fi

read -p "Enter Main Domain (MAINDOMAIN): " MAINDOMAIN
read -p "Enter Second Domain (SECDOMAIN): " SECDOMAIN
read -p "Enter Google Drive URL: " GDRIVE_URL

if [ -z "$MAINDOMAIN" ] || [ -z "$SECDOMAIN" ] || [ -z "$GDRIVE_URL" ]; then
  exit 1
fi

dnf -y -q update >/dev/null 2>&1
REQUIRED_PACKAGES=(curl wget git lsof which jq unzip tar python3-pip)
for pkg in "${REQUIRED_PACKAGES[@]}"; do
  if ! rpm -q "$pkg" >/dev/null 2>&1; then
    dnf -y -q install "$pkg" >/dev/null 2>&1
  fi
done

if ! command -v node >/dev/null 2>&1 || ! node -v | grep -q "v22"; then
  curl -fsSL https://rpm.nodesource.com/setup_22.x | bash - >/dev/null 2>&1
  dnf -y -q install nodejs >/dev/null 2>&1
fi

if ! command -v pm2 >/dev/null 2>&1; then
  npm install -g pm2 >/dev/null 2>&1
fi


if ! rpm -q nginx >/dev/null 2>&1; then
  dnf -y -q install nginx >/dev/null 2>&1
fi
systemctl enable --now nginx >/dev/null 2>&1

if ! command -v ffmpeg >/dev/null 2>&1; then
  dnf install ffmpeg ffmpeg-devel -y >/dev/null 2>&1
fi

if ! command -v certbot >/dev/null 2>&1; then
  dnf -y install snapd >/dev/null 2>&1
  systemctl enable --now snapd.socket >/dev/null 2>&1
  ln -s /var/lib/snapd/snap /snap || true
  snap install core --classic || true
  snap refresh core || true
  snap install --classic certbot || true
  ln -sf /snap/bin/certbot /usr/bin/certbot
fi

if ! rpm -q firewalld >/dev/null 2>&1; then
  dnf -y install firewalld
fi
systemctl enable --now firewalld
firewall-cmd --permanent --query-port=3000/tcp >/dev/null 2>&1 || firewall-cmd --permanent --add-port=3000/tcp
firewall-cmd --permanent --query-service=http >/dev/null 2>&1 || firewall-cmd --permanent --add-service=http
firewall-cmd --permanent --query-service=https >/dev/null 2>&1 || firewall-cmd --permanent --add-service=https
firewall-cmd --reload

if command -v setsebool >/dev/null 2>&1; then
  setsebool -P httpd_can_network_connect 1
fi

TARGET_DIR="/home/hls"
ECOSYSTEM="ecosystem.config.cjs"
NGINX_CONF_DIR="/etc/nginx/conf.d"
WEBROOT="/var/www/letsencrypt"

mkdir -p "$TARGET_DIR"
mkdir -p "$NGINX_CONF_DIR"
mkdir -p "$WEBROOT/.well-known/acme-challenge"

if ! rpm -q policycoreutils-python-utils >/dev/null 2>&1; then
  dnf -y -q install policycoreutils-python-utils >/dev/null 2>&1
fi
if command -v semanage >/dev/null 2>&1; then
  semanage fcontext -a -t httpd_sys_content_t "${WEBROOT}(/.*)?"
  restorecon -R "${WEBROOT}"
fi

if [ -n "$GDRIVE_URL" ]; then
  if ! command -v python3 >/dev/null 2>&1; then dnf -y install python3; fi
  if ! command -v pip3 >/dev/null 2>&1; then dnf -y install python3-pip; fi
  if ! command -v gdown >/dev/null 2>&1; then pip3 install --no-cache-dir gdown; fi

  cd "$TARGET_DIR"
  FILE_ID=$(echo "$GDRIVE_URL" | sed 's/.*\/d\/\([^\/]*\)\/.*/\1/')
  gdown "https://drive.google.com/uc?export=download&id=${FILE_ID}"
  LATEST_FILE="$(find "$TARGET_DIR" -maxdepth 1 -type f ! -name '*.partial' -printf '%T@ %p\n' | sort -nr | awk 'NR==1{print $2}')"
  if [ -n "${LATEST_FILE:-}" ] && [ -f "$LATEST_FILE" ]; then
    FNAME="$(basename "$LATEST_FILE")"
    case "$FNAME" in
      *.zip) unzip -o "$LATEST_FILE" -d "$TARGET_DIR" ;;
      *.tar.gz|*.tgz) tar -xzf "$LATEST_FILE" -C "$TARGET_DIR" ;;
      *.tar.xz|*.txz) tar -xJf "$LATEST_FILE" -C "$TARGET_DIR" ;;
      *.tar) tar -xf "$LATEST_FILE" -C "$TARGET_DIR" ;;
      *.gz) gunzip -f "$LATEST_FILE" ;;
    esac

    FOUND_ECOSYS="$(find "$TARGET_DIR" -mindepth 1 -maxdepth 3 -type f -name "$ECOSYSTEM" -print -quit || true)"
    if [ -n "$FOUND_ECOSYS" ]; then
      ECOSYS_DIR="$(dirname "$FOUND_ECOSYS")"
      if [ "$ECOSYS_DIR" != "$TARGET_DIR" ]; then
        shopt -s dotglob
        mv -f "$ECOSYS_DIR"/* "$TARGET_DIR"/
        shopt -u dotglob
      fi
    fi

    OWNER="$(stat -c %U "$TARGET_DIR" 2>/dev/null || echo root)"
    chown -R "${OWNER}":"${OWNER}" "$TARGET_DIR"
  fi
fi

if [ -d "$TARGET_DIR" ] && [ -f "${TARGET_DIR}/${ECOSYSTEM}" ]; then
  cd "$TARGET_DIR"
  pm2 start "$ECOSYSTEM"
  pm2 save
fi

MAIN_CONF_PATH="${NGINX_CONF_DIR}/${MAINDOMAIN}.conf"

cat > "$MAIN_CONF_PATH" <<EOF
# Server HTTP (port 80) với redirect to HTTPS
server {
    listen 80;
    listen [::]:80;
    server_name ${MAINDOMAIN};
    client_max_body_size 5G;
    client_body_timeout 1200s;
    keepalive_timeout 120s;
    proxy_connect_timeout 120s;
    proxy_send_timeout 1200s;
    proxy_read_timeout 1200s;

    location /.well-known/acme-challenge/ {
        root ${WEBROOT};
        try_files \$uri =404;
    }

    location / {
        return 301 https://\$host\$request_uri;
    }
}

# Server HTTPS (port 443) với proxy mặc định, nhưng redirect conditional cho /v/... và /(số)
server {
    listen 443 ssl http2;
    listen [::]:443 ssl http2;
    server_name ${MAINDOMAIN};

    ssl_certificate /etc/letsencrypt/live/${MAINDOMAIN}/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/${MAINDOMAIN}/privkey.pem;
    ssl_protocols TLSv1.2 TLSv1.3;

    client_max_body_size 5G;
    client_body_timeout 1200s;
    keepalive_timeout 120s;
    proxy_connect_timeout 120s;
    proxy_send_timeout 1200s;
    proxy_read_timeout 1200s;

    # Redirect cho /v/...
    location ~ ^/v/ {
        return 301 https://${SECDOMAIN}\$request_uri;
    }

    # Redirect cho /(id là số), giả sử id là số nguyên không có phần mở rộng
    location ~ ^/[0-9]+/?$ {
        return 301 https://${SECDOMAIN}\$request_uri;
    }

    # Proxy mặc định cho các path khác
    location / {
        proxy_pass http://127.0.0.1:3000;
        proxy_http_version 1.1;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection "upgrade";
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
        proxy_buffering off;
    }
}
EOF

SEC_CONF_PATH="${NGINX_CONF_DIR}/${SECDOMAIN}.conf"

cat > "$SEC_CONF_PATH" <<EOF
# Server HTTP (port 80) với redirect to HTTPS
server {
    listen 80;
    listen [::]:80;
    server_name ${SECDOMAIN};
    client_max_body_size 5G;
    client_body_timeout 1200s;
    keepalive_timeout 120s;
    proxy_connect_timeout 120s;
    proxy_send_timeout 1200s;
    proxy_read_timeout 1200s;

    location /.well-known/acme-challenge/ {
        root ${WEBROOT};
        try_files \$uri =404;
    }

    location / {
        return 301 https://\$host\$request_uri;
    }
}

# Server HTTPS (port 443) với proxy to app cho tất cả path
server {
    listen 443 ssl http2;
    listen [::]:443 ssl http2;
    server_name ${SECDOMAIN};

    ssl_certificate /etc/letsencrypt/live/${MAINDOMAIN}/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/${MAINDOMAIN}/privkey.pem;
    ssl_protocols TLSv1.2 TLSv1.3;

    client_max_body_size 5G;
    client_body_timeout 1200s;
    keepalive_timeout 120s;
    proxy_connect_timeout 120s;
    proxy_send_timeout 1200s;
    proxy_read_timeout 1200s;

    location / {
        proxy_pass http://127.0.0.1:3000;
        proxy_http_version 1.1;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection "upgrade";
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
        proxy_buffering off;
    }
}
EOF

chown -R nginx:nginx "${WEBROOT}"
chmod -R 755 "${WEBROOT}"
nginx -t && systemctl reload nginx

if command -v certbot >/dev/null 2>&1; then
    certbot certonly --webroot -w "${WEBROOT}" -d "${MAINDOMAIN}" -d "${SECDOMAIN}" --noninteractive --agree-tos -m "admin@${MAINDOMAIN}" --expand || {
        exit 1
    }
fi

nginx -t && systemctl reload nginx

if ! curl -s "http://$MAINDOMAIN/.well-known/acme-challenge/test" | grep -q "test"; then
  exit 1
fi
if ! curl -s "http://$SECDOMAIN/.well-known/acme-challenge/test" | grep -q "test"; then
  exit 1
fi

exit 0
