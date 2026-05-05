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

var_project_name="cms"

msg_info "Installing Dependencies"
$STD apt-get update
$STD apt-get install -y \
  curl \
  wget \
  ca-certificates

msg_info "Installing .NET SDK 10.0 using Microsoft install script"
wget https://dot.net/v1/dotnet-install.sh -O dotnet-install.sh
chmod +x dotnet-install.sh
$STD ./dotnet-install.sh --channel 10.0 --install-dir /usr/share/dotnet
rm dotnet-install.sh
ln -sf /usr/share/dotnet/dotnet /usr/bin/dotnet
export DOTNET_ROOT=/usr/share/dotnet
export PATH=$PATH:$DOTNET_ROOT

msg_info "Installing Nginx"
$STD apt-get install -y nginx
msg_ok "Installed Dependencies"

read -r -p "${TAB3}Use remote database connection and use PostgreSQL? <y/N> " prompt

if [[ ${prompt,,} =~ ^(y|yes)$ ]]; then
  PG_VERSION="17" setup_postgresql
  PG_DB_NAME="${var_project_name}_db" PG_DB_USER="${var_project_name}_user" PG_DB_PASS=$(openssl rand -base64 18 | tr -dc 'a-zA-Z0-9' | head -c13)
  setup_postgresql_db
  
  msg_info "Configuring PostgreSQL for remote connections"
  sed -i "s/#listen_addresses = 'localhost'/listen_addresses = '*'/" /etc/postgresql/17/main/postgresql.conf
  echo "host    all             all             0.0.0.0/0               scram-sha-256" >> /etc/postgresql/17/main/pg_hba.conf
  systemctl restart postgresql
  msg_ok "PostgreSQL configured for remote access"
fi

msg_info "Installing Umbraco templates and project (Patience)"
cd /var/www/html
$STD dotnet new install Umbraco.Templates
$STD dotnet new umbraco --force -n "$var_project_name"

cd /var/www/html/$var_project_name

UMBRACO_PASS=$(openssl rand -base64 18 | tr -dc 'a-zA-Z0-9' | head -c13)

if [[ ${prompt,,} =~ ^(y|yes)$ ]]; then
  $STD dotnet add package Npgsql.EntityFrameworkCore.PostgreSQL
  $STD dotnet add package Our.Umbraco.PostgreSql
  apt-get install -y jq &>/dev/null
  jq --arg dbname "$PG_DB_NAME" \
    --arg dbuser "$PG_DB_USER" \
    --arg dbpass "$PG_DB_PASS" '. + {
    "ConnectionStrings": {
      "umbracoDbDSN": ("Host=localhost;Port=5432;SSL Mode=Allow;Database=" + $dbname + ";Username=" + $dbuser + ";Password=" + $dbpass),
      "umbracoDbDSN_ProviderName": "Npgsql2"
    }
  }' /var/www/html/$var_project_name/appsettings.json > /tmp/appsettings.tmp && mv /tmp/appsettings.tmp /var/www/html/$var_project_name/appsettings.json
else
  apt-get install -y jq &>/dev/null
  jq '. + {
    "ConnectionStrings": {
      "umbracoDbDSN": "Data Source=|DataDirectory|/Umbraco.sqlite.db;Cache=Shared;Foreign Keys=True;Pooling=True",
      "umbracoDbDSN_ProviderName": "Microsoft.Data.Sqlite"
    }
  }' /var/www/html/$var_project_name/appsettings.json > /tmp/appsettings.tmp && mv /tmp/appsettings.tmp /var/www/html/$var_project_name/appsettings.json
fi
msg_ok "Project Created"

{
  if [[ ${prompt,,} =~ ^(y|yes)$ ]]; then
    echo "PostgreSQL Credentials"
    echo "Database: $PG_DB_NAME"
    echo "Username: $PG_DB_USER"
    echo "Password: $PG_DB_PASS"
    echo ""
  fi
  echo "Umbraco Credentials"
  echo "Username: admin"
  echo "Email: admin@umbraco.local"
  echo "Password: $UMBRACO_PASS"
} >>~/umbraco.creds

msg_info "Setting up Nginx Server"
rm -f /var/www/html/index.nginx-debian.html

cat <<EOF >/etc/nginx/sites-available/default
map \$http_connection \$connection_upgrade {
  "~*Upgrade" \$http_connection;
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
      proxy_set_header   Upgrade \$http_upgrade;
      proxy_set_header   Connection \$connection_upgrade;
      proxy_set_header   Host \$host;
      proxy_cache_bypass \$http_upgrade;
      proxy_set_header   X-Forwarded-For \$proxy_add_x_forwarded_for;
      proxy_set_header   X-Forwarded-Proto \$scheme;
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
cat <<EOF >/etc/systemd/system/umbraco-kestrel.service
[Unit]
Description=Umbraco CMS running on Linux

[Service]
WorkingDirectory=/var/www/html/$var_project_name-publish
ExecStart=/usr/bin/dotnet /var/www/html/$var_project_name-publish/$var_project_name.dll --urls "https://0.0.0.0:7000"
Restart=always
RestartSec=10
KillSignal=SIGINT
SyslogIdentifier=umbraco
User=root
Environment=ASPNETCORE_ENVIRONMENT=Production
Environment=DOTNET_NOLOGO=true
Environment=DOTNET_PRINT_TELEMETRY_MESSAGE=false
Environment=Umbraco__CMS__Unattended__InstallUnattended=true
Environment=Umbraco__CMS__Unattended__UnattendedUserName=admin
Environment=Umbraco__CMS__Unattended__UnattendedUserEmail=admin@umbraco.local
Environment=Umbraco__CMS__Unattended__UnattendedUserPassword=$UMBRACO_PASS

[Install]
WantedBy=multi-user.target
EOF
systemctl enable -q --now umbraco-kestrel
msg_ok "Umbraco Kestrel Service Created"

msg_info "Creating publish script"
cat <<EOF >/var/www/html/$var_project_name/publish.sh
#!/usr/bin/env bash
cd /var/www/html/$var_project_name
dotnet publish -c Release -o /var/www/html/$var_project_name-publish
systemctl restart umbraco-kestrel.service
EOF
chmod +x /var/www/html/$var_project_name/publish.sh

msg_info "Building and publishing project (Patience)"
$STD /var/www/html/$var_project_name/publish.sh
msg_ok "Umbraco published successfully"

motd_ssh
customize
cleanup_lxc
