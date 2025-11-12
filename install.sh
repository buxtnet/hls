#!/usr/bin/env bash
set -euo pipefail

if [ "$(id -u)" -ne 0 ]; then
  echo "Run as root: sudo bash $0 [GDRIVE_URL (optional)] <MAINDOMAIN> <SECDOMAIN>"
  exit 1
fi

# Yêu cầu người dùng nhập MAINDOMAIN và SECDOMAIN
read -p "Enter Main Domain (MAINDOMAIN): " MAINDOMAIN
read -p "Enter Second Domain (SECDOMAIN): " SECDOMAIN

if [ -z "$MAINDOMAIN" ] || [ -z "$SECDOMAIN" ]; then
  echo "Usage: sudo bash $0 <MAINDOMAIN> <SECDOMAIN>"
  exit 1
fi

# ---------- basic ----------
dnf -y update
dnf -y install curl wget git lsof which jq unzip tar python3-pip

# node 22
if ! command -v node >/dev/null 2>&1 || ! node -v | grep -q "v22"; then
  curl -fsSL https://rpm.nodesource.com/setup_22.x | bash -
  dnf -y install nodejs
fi

# pm2
if ! command -v pm2 >/dev/null 2>&1; then
  npm install -g pm2
fi

# nginx
if ! rpm -q nginx >/dev/null 2>&1; then
  dnf -y install nginx
fi
systemctl enable --now nginx

# ---------- Install FFmpeg ----------
# Thêm kho EPEL
dnf -y install epel-release

# Kích hoạt kho PowerTools (CRB) cho FFmpeg
sudo dnf config-manager --set-enabled crb

# Cài đặt FFmpeg
dnf -y install ffmpeg ffmpeg-devel

# Kiểm tra cài đặt
ffmpeg -version

# ---------- certbot via snap if missing ----------
if ! command -v certbot >/dev/null 2>&1; then
  dnf -y install snapd
  systemctl enable --now snapd.socket
  ln -s /var/lib/snapd/snap /snap || true
  snap install core --classic
  snap refresh core
  snap install --classic certbot
  ln -sf /snap/bin/certbot /usr/bin/certbot
fi

# firewall basics
if ! rpm -q firewalld >/dev/null 2>&1; then
  dnf -y install firewalld
fi
systemctl enable --now firewalld
firewall-cmd --permanent --add-service=ssh
firewall-cmd --permanent --add-port=3000/tcp
firewall-cmd --reload

# SELinux boolean so nginx can connect to node
if command -v setsebool >/dev/null 2>&1; then
  setsebool -P httpd_can_network_connect 1
fi

# ---------- variables ----------
TARGET_DIR="/home/hls"
ECOSYSTEM="ecosystem.config.cjs"
NGINX_CONF_DIR="/etc/nginx/conf.d"
WEBROOT="/var/www/letsencrypt"

mkdir -p "$TARGET_DIR"
mkdir -p "$NGINX_CONF_DIR"
mkdir -p "$WEBROOT/.well-known/acme-challenge"

# ---------- DOWNLOAD FROM GOOGLE DRIVE (runs BEFORE pm2 start) ----------
if [ -n "$GDRIVE_URL" ]; then
  # đảm bảo python3 và pip3 có sẵn
  if ! command -v python3 >/dev/null 2>&1; then
    dnf -y install python3
  fi
  if ! command -v pip3 >/dev/null 2>&1; then
    dnf -y install python3-pip
  fi

  # cài gdown nếu chưa có
  if ! command -v gdown >/dev/null 2>&1; then
    pip3 install --no-cache-dir gdown
  fi

  cd "$TARGET_DIR"

  # tải từ Google Drive
  gdown "$GDRIVE_URL" || {
    if [[ "$GDRIVE_URL" =~ /d/([^/]+) ]]; then
      FILEID="${BASH_REMATCH[1]}"
      gdown "https://drive.google.com/uc?export=download&id=${FILEID}"
    fi
  }

  # tìm file mới nhất
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

    # tìm ecosystem.config.cjs nếu nằm trong thư mục con
    FOUND_ECOSYS="$(find "$TARGET_DIR" -mindepth 1 -maxdepth 3 -type f -name "$ECOSYSTEM" -print -quit || true)"
    if [ -n "$FOUND_ECOSYS" ]; then
      ECOSYS_DIR="$(dirname "$FOUND_ECOSYS")"
      if [ "$ECOSYS_DIR" != "$TARGET_DIR" ]; then
        shopt -s dotglob
        mv -f "$ECOSYS_DIR"/* "$TARGET_DIR"/
        shopt -u dotglob
      fi
    fi

    # fix quyền
    OWNER="$(stat -c %U "$TARGET_DIR")"
    chown -R "${OWNER}":"${OWNER}" "$TARGET_DIR"
  fi
fi

# ---------- pm2 start app (after download/extract) ----------
if [ -d "$TARGET_DIR" ] && [ -f "${TARGET_DIR}/${ECOSYSTEM}" ]; then
  cd "$TARGET_DIR"
  pm2 start "$ECOSYSTEM"
  pm2 save
fi

# ---------- Nginx + Certbot configuration ----------
HTTP_CONF_PATH="${NGINX_CONF_DIR}/${MAINDOMAIN}.conf"
SSL_CONF_PATH="${NGINX_CONF_DIR}/${MAINDOMAIN}-ssl.conf"

cat > "$HTTP_CONF_PATH" <<EOF
server {
    listen 80;
    server_name ${MAINDOMAIN};

    client_max_body_size 2048M;
    client_body_timeout 120s;
    proxy_read_timeout 120s;
    proxy_send_timeout 120s;

    location ^~ /.well-known/acme-challenge/ {
        root ${WEBROOT};
        try_files \$uri =404;
    }

    location / {
        proxy_pass http://127.0.0.1:3000;
        proxy_http_version 1.1;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection 'upgrade';
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_cache_bypass \$http_upgrade;
    }
}
EOF

chown -R nginx:nginx "${WEBROOT}"
chmod -R 755 "${WEBROOT}"
nginx -t && systemctl reload nginx

certbot certonly --webroot -w "${WEBROOT}" -d "${MAINDOMAIN}" --noninteractive --agree-tos -m "admin@${MAINDOMAIN}"

CERT_DIR="/etc/letsencrypt/live/${MAINDOMAIN}"
if [ -d "$CERT_DIR" ]; then
  cat > "$SSL_CONF_PATH" <<EOF
server {
    listen 443 ssl http2;
    server_name ${MAINDOMAIN};

    ssl_certificate ${CERT_DIR}/fullchain.pem;
    ssl_certificate_key ${CERT_DIR}/privkey.pem;
    ssl_session_cache shared:SSL:10m;
    ssl_session_timeout 10m;
    ssl_protocols TLSv1.2 TLSv1.3;

    client_max_body_size 2048M;
    client_body_timeout 120s;
    proxy_read_timeout 120s;
    proxy_send_timeout 120s;

    location ^~ /.well-known/acme-challenge/ {
        root ${WEBROOT};
        try_files \$uri =404;
    }

    location / {
        return 301 https://${SECDOMAIN}\$request_uri;
    }
}

server {
    listen 80;
    server_name ${MAINDOMAIN};
    return 301 https://\$host\$request_uri;
}
EOF

  nginx -t && systemctl reload nginx
fi

# --------- SECOND domain (Cloudflare proxied) ----------
SEC_CONF_PATH="${NGINX_CONF_DIR}/${SECDOMAIN}.conf"

cat > "$SEC_CONF_PATH" <<EOF
server {
    listen 80;
    server_name ${SECDOMAIN};

    # block requests that do not use expected host (prevent direct IP access)
    if (\$host !~* ^(${SECDOMAIN}|${MAINDOMAIN})\$) {
        return 444;
    }

    client_max_body_size 2048M;
    client_body_timeout 120s;
    proxy_read_timeout 120s;
    proxy_send_timeout 120s;

    # /v/... -> preserve uri
    location ^~ /v/ {
        proxy_pass http://127.0.0.1:3000\$request_uri;
        proxy_http_version 1.1;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
        proxy_cache_bypass \$http_upgrade;
    }

    # numeric id at root, e.g. /4004 or /4004/slug -> rewrite to /old_id/<id><rest>
    location ~ ^/([0-9]+)(/.*)?\$ {
        proxy_pass http://127.0.0.1:3000/old_id/\$1\$2\$is_args\$args;
        proxy_http_version 1.1;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
        proxy_cache_bypass \$http_upgrade;
    }

    # /old_id/ passthrough
    location ^~ /old_id/ {
        proxy_pass http://127.0.0.1:3000\$request_uri;
        proxy_http_version 1.1;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
        proxy_cache_bypass \$http_upgrade;
    }

    # fallback: preserve path
    location / {
        proxy_pass http://127.0.0.1:3000\$request_uri;
        proxy_http_version 1.1;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
        proxy_cache_bypass \$http_upgrade;
    }
}
EOF

nginx -t && systemctl reload nginx

# --------- Cloudflare IP firewall setup ----------
CF_JSON=$(curl -s https://api.cloudflare.com/client/v4/ips)
CF_V4=$(echo "$CF_JSON" | jq -r '.result.ipv4_cidrs[]' 2>/dev/null)
CF_V6=$(echo "$CF_JSON" | jq -r '.result.ipv6_cidrs[]' 2>/dev/null)

firewall-cmd --permanent --new-zone=cloudflare-ips || true
firewall-cmd --permanent --zone=cloudflare-ips --remove-source=all || true

for src in $CF_V4 $CF_V6; do
  firewall-cmd --permanent --zone=cloudflare-ips --add-source="$src"
done

firewall-cmd --permanent --zone=cloudflare-ips --add-service=http
firewall-cmd --permanent --zone=cloudflare-ips --add-service=https

firewall-cmd --permanent --zone=public --remove-service=http || true
firewall-cmd --permanent --zone=public --remove-service=https || true

firewall-cmd --reload

# ------------- finish -------------
echo "Done."
echo "MAIN domain: ${MAINDOMAIN} (cert dir: ${CERT_DIR:-not-found})"
echo "SECOND domain: ${SECDOMAIN} configured."
echo "Notes:"
echo "- MAIN domain should be DNS-only when issuing cert."
echo "- SECOND domain should be proxied (orange cloud) in Cloudflare."
echo "- If you need direct origin access for debugging, add your IP to public zone before running."
