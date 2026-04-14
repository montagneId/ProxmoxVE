#!/usr/bin/env bash

# Copyright (c) 2021-2026 community-scripts ORG
# Author: Joost van den Berg
# License: MIT | https://github.com/montagneid/ProxmoxVE/raw/main/LICENSE
# Source: https://github.com/umbraco/Umbraco-CMS

source /dev/stdin <<<"$FUNCTIONS_FILE_PATH"
color
verb_ip6
catch_errors
setting_up_container
network_check
update_os

msg_info "Installing Dependencies"
$STD apt-get update
$STD apt-get install -y \
  ssh \
  software-properties-common

$STD add-apt-repository -y ppa:dotnet/backports
$STD apt-get update
$STD apt-get install -y \
  dotnet-sdk-10.0 \
  vsftpd \
  nginx
msg_ok "Installed Dependencies"

var_project_name="umbraco"

msg_info "Installing Umbraco templates and project (Patience)"
cd /var/www/html
$STD dotnet new install Umbraco.Templates@17.3.3 --force
$STD dotnet new umbraco --force -n "$var_project_name"
msg_ok "Project Created"

msg_info "Building Umbraco Project (Patience)"
cd /var/www/html/$var_project_name
$STD dotnet build -c Release
msg_ok "Umbraco build successful"

msg_info "Configuring Umbraco Unattended Install"
UMBRACO_PASS=$(openssl rand -base64 18 | tr -dc 'a-zA-Z0-9' | head -c13)
cat > /var/www/html/$var_project_name/appsettings.json <<JSONEOF
{
  "\$schema": "appsettings-schema.json",
  "Serilog": {
    "MinimumLevel": {
      "Default": "Information"
    }
  },
  "Umbraco": {
    "CMS": {
      "Unattended": {
        "InstallUnattended": true,
        "UnattendedUserName": "admin",
        "UnattendedUserEmail": "admin@umbraco.local",
        "UnattendedUserPassword": "$UMBRACO_PASS"
      }
    }
  }
}
JSONEOF
chmod 600 /var/www/html/$var_project_name/appsettings.json
msg_ok "Umbraco configured"

msg_info "Setting up FTP Server"
useradd ftpuser
FTP_PASS=$(openssl rand -base64 18 | tr -dc 'a-zA-Z0-9' | head -c13)
usermod --password $(echo ${FTP_PASS} | openssl passwd -1 -stdin) ftpuser
mkdir -p /var/www/html
usermod -d /var/www/html ftp
usermod -d /var/www/html ftpuser
chown ftpuser /var/www/html

sed -i "s|#write_enable=YES|write_enable=YES|g" /etc/vsftpd.conf
sed -i "s|#chroot_local_user=YES|chroot_local_user=NO|g" /etc/vsftpd.conf

systemctl restart -q vsftpd.service

{
  echo "FTP-Credentials"
  echo "Username: ftpuser"
  echo "Password: $FTP_PASS"
  echo ""
  echo "Umbraco Admin Credentials"
  echo "Username: admin"
  echo "Email: admin@umbraco.local"
  echo "Password: $UMBRACO_PASS"
} >>~/umbraco.creds

msg_ok "FTP server setup completed"

msg_info "Setting up Nginx Server"
rm -f /var/www/html/index.nginx-debian.html

sed "s/\$var_project_name/$var_project_name/g" >myfile <<'EOF' >/etc/nginx/sites-available/default
map $http_connection $connection_upgrade {
  "~*Upgrade" $http_connection;
  default keep-alive;
}
server {
  listen 443 ssl default_server;
  listen [::]:443 ssl default_server;
  ssl_certificate /etc/nginx/certificate/nginx-certificate.crt;
  ssl_certificate_key /etc/nginx/certificate/nginx.key;
  server_name   html.com *.html.com;
  location / {
      proxy_pass         https://127.0.0.1:7000/;
      proxy_http_version 1.1;
      proxy_set_header   Upgrade $http_upgrade;
      proxy_set_header   Connection $connection_upgrade;
      proxy_set_header   Host $host;
      proxy_cache_bypass $http_upgrade;
      proxy_set_header   X-Forwarded-For $proxy_add_x_forwarded_for;
      proxy_set_header   X-Forwarded-Proto $scheme;
      proxy_buffering on;
      proxy_buffer_size 16k;
      proxy_buffers 8 32k;
      proxy_busy_buffers_size 64k;
  }
}
EOF

mkdir /etc/nginx/certificate
cd /etc/nginx/certificate
openssl req -new -newkey rsa:4096 -x509 -sha256 -days 365 -nodes -out nginx-certificate.crt -keyout nginx.key -subj "/C=NL/ST=State/L=City/O=Organization/CN=localhost" &>/dev/null

systemctl reload nginx
msg_ok "Nginx Server Created"

msg_info "Creating Kestrel Umbraco Service"
cat <<EOF >/etc/systemd/system/kestrel-umbraco.service
[Unit]
Description=Umbraco CMS running on Linux

[Service]
WorkingDirectory=/var/www/html/$var_project_name
ExecStart=/usr/bin/dotnet /var/www/html/"$var_project_name"/bin/Release/net10.0/"$var_project_name".dll --urls "https://0.0.0.0:7000"
Restart=always
# Restart service after 10 seconds if the dotnet service crashes:
RestartSec=10
KillSignal=SIGINT
SyslogIdentifier=umbraco
User=root
Environment=ASPNETCORE_ENVIRONMENT=Production
Environment=DOTNET_NOLOGO=true
Environment=DOTNET_PRINT_TELEMETRY_MESSAGE=false

[Install]
WantedBy=multi-user.target
EOF
systemctl enable -q --now kestrel-umbraco
msg_ok "Kestrel Umbraco Service Created"

motd_ssh
customize
cleanup_lxc
