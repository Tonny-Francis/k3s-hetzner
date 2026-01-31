#!/bin/bash
set -e

echo "=== Instalando Nginx e Certbot nativamente ==="

# Parar containers Docker do nginx e certbot
echo "Parando containers Docker..."
cd /root/grafana
docker compose stop nginx certbot 2>/dev/null || true

# Atualizar sistema e instalar pacotes
echo "Instalando nginx e certbot..."
apt update
apt install -y nginx certbot python3-certbot-nginx

# Obter IP do container Grafana
echo "Obtendo IP do container Grafana..."
GRAFANA_IP=$(docker inspect grafana --format '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}' 2>/dev/null || echo "172.18.0.2")
echo "IP do Grafana: $GRAFANA_IP"

# Criar configuração inicial do nginx (HTTP apenas para validação)
echo "Criando configuração inicial do nginx..."
cat > /etc/nginx/sites-available/rancher-grafana << 'EOF'
map $http_upgrade $connection_upgrade {
    default Upgrade;
    '' close;
}

server {
    listen 80;
    server_name rancher.domain.com;
    
    location /.well-known/acme-challenge/ {
        root /var/www/html;
    }
    
    location / {
        proxy_pass http://127.0.0.1:8080;
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;
        
        # WebSocket support
        proxy_http_version 1.1;
        proxy_set_header Upgrade $http_upgrade;
        proxy_set_header Connection $connection_upgrade;
        proxy_buffering off;
        proxy_read_timeout 1800s;
        proxy_connect_timeout 1800s;
        proxy_send_timeout 1800s;
    }
}

server {
    listen 80;
    server_name grafana.domain.com;
    
    location /.well-known/acme-challenge/ {
        root /var/www/html;
    }
    
    location / {
        proxy_pass http://GRAFANA_IP:3000;
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;
        
        # WebSocket support
        proxy_http_version 1.1;
        proxy_set_header Upgrade $http_upgrade;
        proxy_set_header Connection $connection_upgrade;
    }
}
EOF

# Substituir IP do Grafana
sed -i "s|GRAFANA_IP|$GRAFANA_IP|g" /etc/nginx/sites-available/rancher-grafana

# Ativar configuração
ln -sf /etc/nginx/sites-available/rancher-grafana /etc/nginx/sites-enabled/
rm -f /etc/nginx/sites-enabled/default

# Testar configuração
echo "Testando configuração do nginx..."
nginx -t

# Reiniciar nginx
echo "Reiniciando nginx..."
systemctl restart nginx
systemctl enable nginx

# Gerar certificados Let's Encrypt
echo "Gerando certificados SSL..."
certbot --nginx \
    -d rancher.domain.com \
    -d grafana.domain.com \
    --non-interactive \
    --agree-tos \
    --email admin@domain.com \
    --redirect

# Verificar auto-renewal
echo "Configurando auto-renewal..."
systemctl enable certbot.timer
systemctl start certbot.timer

echo ""
echo "=== Instalação completa! ==="
echo ""
echo "Certificados instalados:"
certbot certificates
echo ""
echo "Acesse:"
echo "  - https://rancher.domain.com"
echo "  - https://grafana.domain.com"
echo ""
echo "Auto-renewal configurado via systemd timer"
