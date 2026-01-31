#!/bin/bash
set -e

echo "🚀 Setup Interativo: VPN + Rancher + DNS"
echo "=========================================="
echo ""

# Verificar HCLOUD_TOKEN
if [[ -z "$HCLOUD_TOKEN" ]]; then
  echo "❌ HCLOUD_TOKEN não definido. Execute: export HCLOUD_TOKEN='...'"
  exit 1
fi

# 1. Configuração da Rede
echo "📡 Configuração da Rede Privada"
echo "================================"
read -p "Nome da rede privada [k3s-production]: " NETWORK_NAME
NETWORK_NAME=${NETWORK_NAME:-k3s-production}

read -p "Subnet da rede [10.0.0.0/24]: " NETWORK_SUBNET
NETWORK_SUBNET=${NETWORK_SUBNET:-10.0.0.0/24}

# Verificar se rede existe, senão criar
if hcloud network describe "$NETWORK_NAME" &>/dev/null; then
  echo "✅ Rede '$NETWORK_NAME' já existe"
else
  echo "🔧 Criando rede '$NETWORK_NAME'..."
  hcloud network create --name "$NETWORK_NAME" --ip-range "$NETWORK_SUBNET"
  hcloud network add-subnet "$NETWORK_NAME" --network-zone eu-central --type cloud --ip-range "$NETWORK_SUBNET"
  echo "✅ Rede criada!"
fi
echo ""

# 2. Configuração do Servidor
echo "🖥️  Configuração do Servidor"
echo "============================"
read -p "Nome do servidor [vpn-rancher]: " SERVER_NAME
SERVER_NAME=${SERVER_NAME:-vpn-rancher}

read -p "Tipo de servidor [cx22]: " SERVER_TYPE
SERVER_TYPE=${SERVER_TYPE:-cx22}

read -p "Localização [nbg1]: " LOCATION
LOCATION=${LOCATION:-nbg1}

echo ""

# 3. Configuração do Domínio e DNS
echo "🌐 Configuração de DNS"
echo "======================"
read -p "Deseja configurar DNS no Cloudflare? (s/N): " CONFIGURE_DNS

if [[ "$CONFIGURE_DNS" =~ ^[sS]$ ]]; then
  read -p "Domínio do Rancher (ex: rancher.seudominio.com): " RANCHER_DOMAIN
  read -p "Cloudflare Zone ID: " CLOUDFLARE_ZONE_ID
  
  if [[ -z "$CLOUDFLARE_API_TOKEN" ]]; then
    read -sp "Cloudflare API Token: " CLOUDFLARE_API_TOKEN
    echo ""
  fi
else
  RANCHER_DOMAIN=""
fi
echo ""

# 4. Confirmação
echo "📝 Resumo da Configuração"
echo "========================="
echo "  Rede: $NETWORK_NAME ($NETWORK_SUBNET)"
echo "  Servidor: $SERVER_NAME"
echo "  Tipo: $SERVER_TYPE"
echo "  Localização: $LOCATION"
if [[ -n "$RANCHER_DOMAIN" ]]; then
  echo "  Domínio: $RANCHER_DOMAIN"
fi
echo ""
read -p "Confirma a criação? (s/N): " CONFIRM
if [[ ! "$CONFIRM" =~ ^[sS]$ ]]; then
  echo "❌ Cancelado pelo usuário"
  exit 0
fi
echo ""

echo ""

# 5. Criar Firewall específico para VPN/Rancher
echo "🔥 Criando Firewall..."
FIREWALL_NAME="${SERVER_NAME}"

# Pegar seu IP público atual
YOUR_IP=$(curl -s ifconfig.me)

FIREWALL_RULES='[
  {
    "description": "Allow SSH from anywhere",
    "direction": "in",
    "port": "22",
    "protocol": "tcp",
    "source_ips": ["0.0.0.0/0", "::/0"]
  },
  {
    "description": "Allow HTTP",
    "direction": "in",
    "port": "80",
    "protocol": "tcp",
    "source_ips": ["0.0.0.0/0", "::/0"]
  },
  {
    "description": "Allow HTTPS",
    "direction": "in",
    "port": "443",
    "protocol": "tcp",
    "source_ips": ["0.0.0.0/0", "::/0"]
  },
  {
    "description": "Allow WireGuard VPN",
    "direction": "in",
    "port": "51820",
    "protocol": "udp",
    "source_ips": ["0.0.0.0/0", "::/0"]
  },
  {
    "description": "Allow ICMP (ping)",
    "direction": "in",
    "protocol": "icmp",
    "source_ips": ["0.0.0.0/0", "::/0"]
  }
]'

# Criar firewall
hcloud firewall create \
  --name "$FIREWALL_NAME" \
  --rules-file <(echo "$FIREWALL_RULES") >/dev/null

echo "✅ Firewall '$FIREWALL_NAME' criado!"
echo ""

# 6. Criar script de inicialização (cloud-init)
cat > /tmp/cloud-init.yaml <<'EOF'
#cloud-config
packages:
  - curl
  - wget
  - git
  - wireguard
  - wireguard-tools
  - qrencode

runcmd:
  # Configurar WireGuard
  - mkdir -p /etc/wireguard
  - wg genkey | tee /etc/wireguard/server_private.key | wg pubkey > /etc/wireguard/server_public.key
  - chmod 600 /etc/wireguard/server_private.key
  - |
    # Detectar interface de rede pública
    PUBLIC_IFACE=$(ip route | grep default | awk '{print $5}' | head -1)
    cat > /etc/wireguard/wg0.conf <<WGCONF
    [Interface]
    Address = 10.8.0.1/24
    ListenPort = 51820
    PrivateKey = $(cat /etc/wireguard/server_private.key)
    PostUp = iptables -A FORWARD -i wg0 -j ACCEPT; iptables -t nat -A POSTROUTING -o $PUBLIC_IFACE -j MASQUERADE
    PostDown = iptables -D FORWARD -i wg0 -j ACCEPT; iptables -t nat -D POSTROUTING -o $PUBLIC_IFACE -j MASQUERADE
    WGCONF
  - echo "net.ipv4.ip_forward=1" >> /etc/sysctl.conf
  - sysctl -p
  - systemctl enable wg-quick@wg0
  - systemctl start wg-quick@wg0
  
  # Instalar Docker
  - curl -fsSL https://get.docker.com | sh
  - systemctl enable docker
  - systemctl start docker
  
  # Instalar Rancher
  - |
    docker run -d --restart=unless-stopped \
      -p 80:80 -p 443:443 \
      --privileged \
      --name rancher \
      rancher/rancher:latest
  
  # Salvar informações em /root/setup-info.txt
  - |
    cat > /root/setup-info.txt <<SETUPINFO
    ==============================================
    Setup VPN + Rancher Completo!
    ==============================================
    
    WireGuard Server Public Key:
    $(cat /etc/wireguard/server_public.key)
    
    WireGuard Server Config: /etc/wireguard/wg0.conf
    
    Rancher URL: https://$(curl -s ifconfig.me)
    Rancher Container: docker logs rancher 2>&1 | grep "Bootstrap Password:"
    
    Para adicionar cliente VPN, execute:
    /root/add-wireguard-client.sh <client-name>
    ==============================================
    SETUPINFO
  
  # Script para adicionar clientes WireGuard
  - |
    cat > /root/add-wireguard-client.sh <<'ADDCLIENT'
    #!/bin/bash
    CLIENT_NAME=$1
    if [[ -z "$CLIENT_NAME" ]]; then
      echo "Uso: $0 <nome-do-cliente>"
      exit 1
    fi
    
    CLIENT_DIR="/etc/wireguard/clients/$CLIENT_NAME"
    mkdir -p $CLIENT_DIR
    
    # Gerar chaves do cliente
    wg genkey | tee $CLIENT_DIR/private.key | wg pubkey > $CLIENT_DIR/public.key
    
    # Próximo IP disponível
    LAST_IP=$(wg show wg0 allowed-ips | grep -oP '10\.8\.0\.\d+' | sort -t. -k4 -n | tail -1 | cut -d. -f4)
    NEXT_IP=$((LAST_IP + 1))
    CLIENT_IP="10.8.0.$NEXT_IP"
    
    SERVER_PUBLIC_KEY=$(cat /etc/wireguard/server_public.key)
    SERVER_PUBLIC_IP=$(curl -s ifconfig.me)
    
    # Adicionar peer ao servidor
    wg set wg0 peer $(cat $CLIENT_DIR/public.key) allowed-ips $CLIENT_IP/32
    
    # Salvar config permanente
    cat >> /etc/wireguard/wg0.conf <<PEER
    
    [Peer]
    # $CLIENT_NAME
    PublicKey = $(cat $CLIENT_DIR/public.key)
    AllowedIPs = $CLIENT_IP/32
    PEER
    
    # Gerar config do cliente
    cat > $CLIENT_DIR/client.conf <<CLIENTCONF
    [Interface]
    PrivateKey = $(cat $CLIENT_DIR/private.key)
    Address = $CLIENT_IP/32
    DNS = 1.1.1.1
    
    [Peer]
    PublicKey = $SERVER_PUBLIC_KEY
    Endpoint = $SERVER_PUBLIC_IP:51820
    AllowedIPs = 10.0.0.0/24, 10.8.0.0/24
    PersistentKeepalive = 25
    CLIENTCONF
    
    # Gerar QR Code
    qrencode -t ansiutf8 < $CLIENT_DIR/client.conf
    
    echo ""
    echo "✅ Cliente '$CLIENT_NAME' criado!"
    echo "📁 Configuração: $CLIENT_DIR/client.conf"
    echo ""
    cat $CLIENT_DIR/client.conf
    ADDCLIENT
  - chmod +x /root/add-wireguard-client.sh
  
  - echo "✅ Setup concluído!" >> /root/setup-info.txt

final_message: "Setup VPN + Rancher finalizado! Veja /root/setup-info.txt"
EOF

echo "🔧 Criando servidor na Hetzner..."

# Verificar se a chave SSH k3s-hetzner existe na Hetzner
SSH_KEY_NAME="k3s-hetzner"
if ! hcloud ssh-key describe "$SSH_KEY_NAME" &>/dev/null; then
  echo "📤 Chave SSH '$SSH_KEY_NAME' não encontrada. Fazendo upload..."
  hcloud ssh-key create --name "$SSH_KEY_NAME" --public-key-from-file ~/.ssh/k3s-hetzner.pub
  echo "✅ Chave SSH enviada!"
fi

# 7. Criar servidor
hcloud server create \
  --name "$SERVER_NAME" \
  --type "$SERVER_TYPE" \
  --location "$LOCATION" \
  --image "ubuntu-24.04" \
  --network "$NETWORK_NAME" \
  --firewall "$FIREWALL_NAME" \
  --user-data-from-file /tmp/cloud-init.yaml \
  --ssh-key "$SSH_KEY_NAME"

echo "✅ Servidor criado! Aguardando informações..."
sleep 3

# Pegar informações do servidor
SERVER_ID=$(hcloud server describe "$SERVER_NAME" -o json | jq -r '.id')
SERVER_IP=$(hcloud server describe "$SERVER_NAME" -o json | jq -r '.public_net.ipv4.ip')

echo "✅ Informações obtidas!"
echo "  - ID: $SERVER_ID"
echo "  - IP: $SERVER_IP"
echo ""

# 8. Aguardar servidor estar pronto
echo "⏳ Aguardando servidor ficar pronto (pode levar 2-3 minutos)..."
sleep 60

# 9. Configurar DNS no Cloudflare (se solicitado)
if [[ -n "$RANCHER_DOMAIN" && -n "$CLOUDFLARE_ZONE_ID" && -n "$CLOUDFLARE_API_TOKEN" ]]; then
  echo "🌐 Configurando DNS no Cloudflare..."
  
  # Extrair apenas o subdomínio
  SUBDOMAIN="${RANCHER_DOMAIN%%.*}"
  
  CLOUDFLARE_RECORD=$(curl -s -X POST "https://api.cloudflare.com/client/v4/zones/$CLOUDFLARE_ZONE_ID/dns_records" \
    -H "Authorization: Bearer $CLOUDFLARE_API_TOKEN" \
    -H "Content-Type: application/json" \
    --data '{
      "type": "A",
      "name": "'"$RANCHER_DOMAIN"'",
      "content": "'"$SERVER_IP"'",
      "ttl": 120,
      "proxied": false
    }')
  
  if echo "$CLOUDFLARE_RECORD" | jq -e '.success' > /dev/null 2>&1; then
    echo "✅ DNS configurado: $RANCHER_DOMAIN -> $SERVER_IP"
  else
    echo "⚠️  Erro ao configurar DNS. Configure manualmente:"
    echo "   $RANCHER_DOMAIN -> $SERVER_IP"
  fi
  echo ""
fi
echo ""
echo "🎉 Setup concluído!"
echo ""
echo "📋 Informações Importantes:"
echo "=========================="
echo "  Servidor: $SERVER_NAME"
echo "  IP: $SERVER_IP"
echo "  Rede: $NETWORK_NAME ($NETWORK_SUBNET)"
echo "  Firewall: $FIREWALL_NAME"
if [[ -n "$RANCHER_DOMAIN" ]]; then
  echo "  Rancher URL: https://$RANCHER_DOMAIN"
fi
echo ""
echo "📋 Próximos passos:"
echo ""
echo "1. Aguarde 2-3 minutos para instalação finalizar"
echo ""
echo "2. Acesse o servidor:"
echo "   ssh root@$SERVER_IP"
echo ""
echo "3. Veja informações do setup:"
echo "   cat /root/setup-info.txt"
echo ""
echo "4. Pegue senha do Rancher:"
echo "   docker logs rancher 2>&1 | grep 'Bootstrap Password:'"
echo ""
echo "5. Acesse Rancher:"
if [[ -n "$RANCHER_DOMAIN" ]]; then
  echo "   https://$RANCHER_DOMAIN (ou https://$SERVER_IP)"
else
  echo "   https://$SERVER_IP"
fi
echo ""
echo "6. Adicione cliente VPN:"
echo "   ssh root@$SERVER_IP '/root/add-wireguard-client.sh seu-nome'"
echo ""

# Salvar informações em arquivo local
cat > /tmp/vpn-rancher-info.txt <<INFOFILE
========================================
Setup VPN + Rancher - $(date)
========================================

Servidor: $SERVER_NAME
IP: $SERVER_IP
Rede: $NETWORK_NAME ($NETWORK_SUBNET)
Firewall: $FIREWALL_NAME
$(if [[ -n "$RANCHER_DOMAIN" ]]; then echo "Rancher URL: https://$RANCHER_DOMAIN"; fi)

SSH: ssh root@$SERVER_IP

Comandos úteis:
- Ver setup info: cat /root/setup-info.txt
- Senha Rancher: docker logs rancher 2>&1 | grep 'Bootstrap Password:'
- Adicionar VPN: /root/add-wireguard-client.sh <nome>
========================================
INFOFILE

echo "💾 Informações salvas em: /tmp/vpn-rancher-info.txt"
