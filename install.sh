#!/usr/bin/env bash
set -euo pipefail

if [ "$(id -u)" -ne 0 ]; then
  echo "Run as root: sudo bash $0 <MAINDOMAIN> <SECDOMAIN>"
  exit 1
fi

# Nhập tên miền
read -p "Enter Main Domain (MAINDOMAIN) [default: video.buxt.net]: " MAINDOMAIN
read -p "Enter Second Domain (SECDOMAIN) [default: player.buxt.net]: " SECDOMAIN
read -p "Enter Google Drive URL: " GDRIVE_URL

MAINDOMAIN="${MAINDOMAIN:-video.buxt.net}"
SECDOMAIN="${SECDOMAIN:-player.buxt.net}"

if [ -z "$MAINDOMAIN" ] || [ -z "$SECDOMAIN" ] || [ -z "$GDRIVE_URL" ]; then
  echo "Usage: sudo bash $0 <MAINDOMAIN> <SECDOMAIN> <GDRIVE_URL>"
  exit 1
fi

echo "Using Main Domain: $MAINDOMAIN"
echo "Using Second Domain: $SECDOMAIN"
echo "Using Google Drive URL: $GDRIVE_URL"

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

# Loại bỏ kiểm tra curl gây lỗi vì Nginx chưa được cấu hình để phục vụ file
echo "test" > "$WEBROOT/.well-known/acme-challenge/test"
echo "Webroot setup complete. Skipping temporary curl check."

# ---------- Tải và giải nén từ Google Drive (User requested sequence) ----------
if [ -n "$GDRIVE_URL" ]; then
  echo "--- Starting Google Drive Download and Extraction ---"

  # Kiểm tra và cài đặt gdown
  if ! command -v python3 >/dev/null 2>&1; then dnf -y install python3; fi
  if ! command -v pip3 >/dev/null 2>&1; then dnf -y install python3-pip; fi
  if ! command -v gdown >/dev/null 2>&1; then pip3 install --no-cache-dir gdown; fi

  cd "$TARGET_DIR"

  # Chuyển đổi URL từ Google Drive
  FILE_ID=$(echo "$GDRIVE_URL" | sed 's/.*\/d\/\([^\/]*\)\/.*/\1/')
  if [ -z "$FILE_ID" ]; then
    echo "Error: Could not extract File ID from Google Drive URL: $GDRIVE_URL"
    exit 1
  fi
  echo "Extracted File ID: ${FILE_ID}"
  
  # Tải từ Google Drive: Sử dụng cú pháp ID và cờ --fuzzy để tìm kiếm tốt hơn
  echo "Starting download using gdown..."
  if ! gdown --id "${FILE_ID}" --no-cookies --fuzzy --quiet; then
    echo "Error: gdown failed to download the file from Google Drive."
    exit 1
  fi

  # Tìm file đã tải (file mới nhất trong TARGET_DIR)
  LATEST_FILE="$(find "$TARGET_DIR" -maxdepth 1 -type f ! -name '*.partial' -printf '%T@ %p\n' | sort -nr | awk 'NR==1{print $2}')"

  if [ -z "${LATEST_FILE:-}" ] || [ ! -f "$LATEST_FILE" ]; then
    echo "Error: Download completed but could not find the downloaded archive file in $TARGET_DIR."
    exit 1
  fi
  
  echo "Successfully downloaded file: $(basename "$LATEST_FILE")"

  # Giải nén
  FNAME="$(basename "$LATEST_FILE")"
  echo "Starting extraction of ${FNAME}..."
  case "$FNAME" in
    *.zip) unzip -o "$LATEST_FILE" -d "$TARGET_DIR" ;;
    *.tar.gz|*.tgz) tar -xzf "$LATEST_FILE" -C "$TARGET_DIR" ;;
    *.tar.xz|*.txz) tar -xJf "$LATEST_FILE" -C "$TARGET_DIR" ;;
    *.tar) tar -xf "$LATEST_FILE" -C "$TARGET_DIR" ;;
    *.gz) gunzip -f "$LATEST_FILE" ;;
    *) echo "Warning: Unknown archive type for ${FNAME}. Attempting to treat as zip." && unzip -o "$LATEST_FILE" -d "$TARGET_DIR" || true ;;
  esac
  echo "Extraction complete."

  # Di chuyển file ra ngoài thư mục gốc nếu cần
  FOUND_ECOSYS="$(find "$TARGET_DIR" -mindepth 1 -maxdepth 3 -type f -name "$ECOSYSTEM" -print -quit || true)"
  if [ -n "$FOUND_ECOSYS" ]; then
    ECOSYS_DIR="$(dirname "$FOUND_ECOSYS")"
    if [ "$ECOSYS_DIR" != "$TARGET_DIR" ]; then
      echo "Moving files from nested directory ${ECOSYS_DIR} to ${TARGET_DIR}."
      shopt -s dotglob
      mv -f "$ECOSYS_DIR"/* "$TARGET_DIR"/
      shopt -u dotglob
    fi
  fi

  # Phân quyền
  OWNER="$(stat -c %U "$TARGET_DIR" 2>/dev/null || echo root)"
  chown -R "${OWNER}":"${OWNER}" "$TARGET_DIR"
fi

# ---------- Khởi chạy ứng dụng với PM2 (User requested sequence) ----------
if [ -d "$TARGET_DIR" ] && [ -f "${TARGET_DIR}/${ECOSYSTEM}" ]; then
  echo "Starting Node.js application with PM2..."
  cd "$TARGET_DIR"
  npm install --omit=dev || true
  pm2 start "$ECOSYSTEM"
  pm2 save
else
  echo "Warning: Application files not found in ${TARGET_DIR} or ${ECOSYSTEM} is missing. Skipping PM2 startup."
fi

# ---------- Cấu hình Nginx cho MAINDOMAIN (User requested sequence) ----------
HTTP_CONF_PATH="${NGINX_CONF_DIR}/${MAINDOMAIN}.conf"
SSL_CONF_PATH="${NGINX_CONF_DIR}/${MAINDOMAIN}-ssl.conf"

# Cấu hình HTTP (port 80)
echo "Configuring Nginx HTTP for ${MAINDOMAIN} (Proxy to 3000 and ACME challenge)..."
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
echo "Reloading Nginx to serve Certbot challenge..."
nginx -t && systemctl reload nginx

# --- Cài đặt Certbot ngay trước khi chạy ---
# Cài đặt Certbot qua Snap (Kiểm tra command)
if ! command -v certbot >/dev/null 2>&1; then
  echo "Installing Certbot via Snap..."
  dnf -y install snapd
  systemctl enable --now snapd.socket
  ln -s /var/lib/snapd/snap /snap || true
  snap install core --classic || true
  snap refresh core || true
  snap install --classic certbot || true
  ln -sf /snap/bin/certbot /usr/bin/certbot
fi

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
