#!/usr/bin/env bash
set -euo pipefail

# Biến GDRIVE_URL được truyền dưới dạng đối số thứ nhất
GDRIVE_URL="${1:-}"

if [ "$(id -u)" -ne 0 ]; then
  echo "Run as root: sudo bash $0 [GDRIVE_URL (optional)] <MAINDOMAIN> <SECDOMAIN>"
  exit 1
fi

# Nhập tên miền
read -p "Enter Main Domain (MAINDOMAIN) [default: video.buxt.net]: " MAINDOMAIN
read -p "Enter Second Domain (SECDOMAIN) [default: player.buxt.net]: " SECDOMAIN

MAINDOMAIN="${MAINDOMAIN:-video.buxt.net}"
SECDOMAIN="${SECDOMAIN:-player.buxt.net}"
if [ -z "$MAINDOMAIN" ] || [ -z "$SECDOMAIN" ]; then
  echo "Usage: sudo bash $0 <MAINDOMAIN> <SECDOMAIN>"
  exit 1
fi
echo "Using Main Domain: $MAINDOMAIN"
echo "Using Second Domain: $SECDOMAIN"

# Cài đặt các package cần thiết
dnf -y update
dnf -y install curl wget git lsof which jq unzip tar python3-pip

# Cài đặt Node.js 22 (Kiểm tra node -v)
if ! command -v node >/dev/null 2>&1 || ! node -v | grep -q "v22"; then
  curl -fsSL https://rpm.nodesource.com/setup_22.x | bash - 
  dnf -y install nodejs
fi

# Cài đặt pm2 (Kiểm tra command)
if ! command -v pm2 >/dev/null 2>&1; then
  npm install -g pm2
fi

# Cài đặt Nginx (Kiểm tra rpm)
if ! rpm -q nginx >/dev/null 2>&1; then
  dnf -y install nginx
fi
systemctl enable --now nginx

# Cài đặt FFmpeg (Dùng liên kết trực tiếp RPM Fusion)
echo "Installing RPM Fusion repositories..."
sudo dnf install --nogpgcheck https://download1.rpmfusion.org/free/el/rpmfusion-free-release-$(rpm -E %rhel).noarch.rpm -y
sudo dnf install --nogpgcheck https://download1.rpmfusion.org/nonfree/el/rpmfusion-nonfree-release-$(rpm -E %rhel).noarch.rpm -y

sudo dnf clean all
sudo dnf update -y
if ! command -v ffmpeg >/dev/null 2>&1; then
  echo "FFmpeg not found, installing..."
  sudo dnf install ffmpeg ffmpeg-devel -y
else
  echo "FFmpeg is already installed."
  ffmpeg -version
fi

# Cài đặt Certbot qua Snap (Kiểm tra command)
if ! command -v certbot >/dev/null 2>&1; then
  dnf -y install snapd
  systemctl enable --now snapd.socket
  ln -s /var/lib/snapd/snap /snap || true
  snap install core --classic || true
  snap refresh core || true
  snap install --classic certbot || true
  ln -sf /snap/bin/certbot /usr/bin/certbot
fi

# Cấu hình tường lửa cơ bản
if ! rpm -q firewalld >/dev/null 2>&1; then
  dnf -y install firewalld
fi
systemctl enable --now firewalld

# Thêm SSH nếu chưa có
firewall-cmd --permanent --query-service=ssh >/dev/null 2>&1 || firewall-cmd --permanent --add-service=ssh

# Thêm port 3000/tcp nếu chưa có
firewall-cmd --permanent --query-port=3000/tcp >/dev/null 2>&1 || firewall-cmd --permanent --add-port=3000/tcp

# Mở cổng 80 và 443 tạm thời cho Certbot (Kiểm tra trước khi thêm)
firewall-cmd --permanent --query-service=http >/dev/null 2>&1 || firewall-cmd --permanent --add-service=http
firewall-cmd --permanent --query-service=https >/dev/null 2>&1 || firewall-cmd --permanent --add-service=https

firewall-cmd --reload

# SELinux: cho phép Nginx kết nối ra mạng (proxy tới Node)
if command -v setsebool >/dev/null 2>&1; then
  setsebool -P httpd_can_network_connect 1
fi

# ---------- Khai báo biến và tạo thư mục ----------
TARGET_DIR="/home/hls"
ECOSYSTEM="ecosystem.config.cjs"
NGINX_CONF_DIR="/etc/nginx/conf.d"
WEBROOT="/var/www/letsencrypt"

mkdir -p "$TARGET_DIR"
mkdir -p "$NGINX_CONF_DIR"
mkdir -p "$WEBROOT/.well-known/acme-challenge"

# Kiểm tra quyền thư mục và tạo tệp thử thách
echo "Checking and setting up webroot for Certbot..."
if [ ! -d "$WEBROOT/.well-known/acme-challenge" ]; then
  mkdir -p "$WEBROOT/.well-known/acme-challenge"
fi
chown -R nginx:nginx "$WEBROOT"
chmod -R 755 "$WEBROOT/.well-known/acme-challenge/"

# Tạo tệp thử thách để kiểm tra
echo "test" > "$WEBROOT/.well-known/acme-challenge/test"

# Kiểm tra tệp thử thách có thể truy cập được không
if ! curl -s "http://$MAINDOMAIN/.well-known/acme-challenge/test" | grep -q "test"; then
  echo "Error: Unable to serve the challenge file."
  exit 1
fi
echo "Challenge file is accessible."

# ---------- Tải và giải nén từ Google Drive ----------
if [ -n "$GDRIVE_URL" ]; then
  if ! command -v python3 >/dev/null 2>&1; then dnf -y install python3; fi
  if ! command -v pip3 >/dev/null 2>&1; then dnf -y install python3-pip; fi
  if ! command -v gdown >/dev/null 2>&1; then pip3 install --no-cache-dir gdown; fi

  cd "$TARGET_DIR"

  # Tải từ Google Drive
  gdown "$GDRIVE_URL" || {
    if [[ "$GDRIVE_URL" =~ /d/([^/]+) ]]; then
      FILEID="${BASH_REMATCH[1]}"
      gdown "https://drive.google.com/uc?export=download&id=${FILEID}"
    fi
  }

  # Giải nén
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

    # Di chuyển file ra ngoài thư mục gốc nếu cần
    FOUND_ECOSYS="$(find "$TARGET_DIR" -mindepth 1 -maxdepth 3 -type f -name "$ECOSYSTEM" -print -quit || true)"
    if [ -n "$FOUND_ECOSYS" ]; then
      ECOSYS_DIR="$(dirname "$FOUND_ECOSYS")"
      if [ "$ECOSYS_DIR" != "$TARGET_DIR" ]; then
        shopt -s dotglob
        mv -f "$ECOSYS_DIR"/* "$TARGET_DIR"/
        shopt -u dotglob
      fi
    fi

    # Phân quyền
    OWNER="$(stat -c %U "$TARGET_DIR" 2>/dev/null || echo root)"
    chown -R "${OWNER}":"${OWNER}" "$TARGET_DIR"
  fi
fi

# ---------- Khởi chạy ứng dụng với PM2 ----------
if [ -d "$TARGET_DIR" ] && [ -f "${TARGET_DIR}/${ECOSYSTEM}" ]; then
  cd "$TARGET_DIR"
  npm install --omit=dev || true
  pm2 start "$ECOSYSTEM"
  pm2 save
fi

# ---------- Cấu hình Nginx cho MAINDOMAIN ----------
HTTP_CONF_PATH="${NGINX_CONF_DIR}/${MAINDOMAIN}.conf"
SSL_CONF_PATH="${NGINX_CONF_DIR}/${MAINDOMAIN}-ssl.conf"

# Cấu hình HTTP (port 80)
cat > "$HTTP_CONF_PATH" <<EOF
server {
    listen 80;
    server_name ${MAINDOMAIN};
    client_max_body_size 2048M;
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
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_cache_bypass \$http_upgrade;
    }
}
EOF

chown -R nginx:nginx "${WEBROOT}"
chmod -R 755 "${WEBROOT}"
nginx -t && systemctl reload nginx

# ---------- Chạy Certbot để lấy chứng chỉ ----------
echo "Running Certbot for ${MAINDOMAIN}..."
if command -v certbot >/dev/null 2>&1; then
    certbot certonly --webroot -w "${WEBROOT}" -d "${MAINDOMAIN}" --noninteractive --agree-tos -m "admin@${MAINDOMAIN}" || {
        echo "WARNING: Certbot failed to issue certificate for ${MAINDOMAIN}. Skipping SSL configuration."
    }
fi

CERT_DIR="/etc/letsencrypt/live/${MAINDOMAIN}"

# Cấu hình HTTPS (port 443) nếu Certbot thành công
if [ -d "$CERT_DIR" ]; then
  echo "SSL certificate found. Configuring Nginx for SSL..."
  cat > "$SSL_CONF_PATH" <<EOF
server {
    listen 443 ssl http2;
    server_name ${MAINDOMAIN};

    ssl_certificate ${CERT_DIR}/fullchain.pem;
    ssl_certificate_key ${CERT_DIR}/privkey.pem;
    ssl_protocols TLSv1.2 TLSv1.3;

    client_max_body_size 2048M;
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
else
    echo "No SSL certificate found for ${MAINDOMAIN}. Skipping SSL configuration."
fi

# --------- Cấu hình Nginx cho SECOND domain ----------
SEC_CONF_PATH="${NGINX_CONF_DIR}/${SECDOMAIN}.conf"

echo "Configuring Nginx for SECOND domain: ${SECDOMAIN}..."
cat > "$SEC_CONF_PATH" <<EOF
server {
    listen 80;
    server_name ${SECDOMAIN};

    # Chặn truy cập trực tiếp bằng IP
    if (\$host !~* ^(${SECDOMAIN}|${MAINDOMAIN})\$) {
        return 444;
    }

    client_max_body_size 2048M;
    proxy_read_timeout 120s;
    proxy_send_timeout 120s;

    # Cấu hình proxy cho các đường dẫn cụ thể
    location ^~ /v/ {
        proxy_pass http://127.0.0.1:3000\$request_uri;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
    }

    location ~ ^/([0-9]+)(/.*)?\$ {
        proxy_pass http://127.0.0.1:3000/old_id/\$1\$2\$is_args\$args;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
    }

    location ^~ /old_id/ {
        proxy_pass http://127.0.0.1:3000\$request_uri;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
    }

    # Fallback
    location / {
        proxy_pass http://127.0.0.1:3000\$request_uri;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
    }
}
EOF

nginx -t && systemctl reload nginx

# ------------- finish -------------
echo "Done."
echo "MAIN domain: ${MAINDOMAIN} (cert dir: ${CERT_DIR:-not-found})"
echo "SECOND domain: ${SECDOMAIN} configured."
echo "Notes:"
echo "- MAIN domain should be DNS-only when issuing cert."
echo "- SECOND domain should be proxied (orange cloud) in Cloudflare."
echo "- If you need direct origin access for debugging, add your IP to public zone before running."
