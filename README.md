# K3s Cluster na Hetzner Cloud

Infraestrutura como código para provisionar um cluster Kubernetes (K3s) altamente disponível na Hetzner Cloud com NGINX Ingress e Cert-Manager configurado.

## 📋 Índice

- [Arquitetura](#-arquitetura)
- [Pré-requisitos](#-pré-requisitos)
- [Estrutura do Projeto](#-estrutura-do-projeto)
- [Instalação](#-instalação)
- [Configuração](#-configuração)
- [Manutenção](#-manutenção)
- [Troubleshooting](#-troubleshooting)

## 🏗️ Arquitetura

### Cluster
- **3 Master Nodes** (CX23): 2 vCPUs, 4 GB RAM, 40 GB SSD - Alta disponibilidade com etcd distribuído
- **2 Worker Pools**: 
  - `tools`: 2 nodes (CX33) - 4 vCPUs, 8 GB RAM, 80 GB SSD - Ingress e ferramentas
  - `resources`: 1 node (CX33) - 4 vCPUs, 8 GB RAM, 80 GB SSD - Aplicações

**Total**: 6 nodes | 14 vCPUs | 36 GB RAM | 280 GB SSD

### Componentes Instalados
- **K3s**: v1.35.0+k3s1
- **NGINX Ingress Controller**: Load balancer para tráfego HTTP/HTTPS
- **Cert-Manager**: Gerenciamento automático de certificados SSL (Let's Encrypt)
- **Cloudflare DNS01**: Validação de certificados via DNS

### Rede
- **Rede Privada**: 10.0.0.0/16
- **CNI**: Flannel
- **Localizações**: nbg1, fsn1, hel1 (eu-central)

## ⚙️ Pré-requisitos

### Ferramentas Necessárias
```bash
# macOS (Homebrew)
brew install hetzner-k3s kubectl helm

# Outras plataformas: consulte a documentação oficial
```

### Contas e Credenciais
- **Hetzner Cloud**: Token de API ([criar aqui](https://console.hetzner.cloud/))
- **Cloudflare**: API Key com permissões DNS ([gerar aqui](https://dash.cloudflare.com/profile/api-tokens))

## 📁 Estrutura do Projeto

```
.
├── README.md                    # Este arquivo
├── comandos.txt                 # Comandos úteis e referência
├── post-install.sh             # Script de pós-instalação
├── k3s/
│   └── cluster-config.yaml     # Configuração do cluster
└── cert-manager/
    └── clusterIssuer.yaml      # Configuração Let's Encrypt
```

## 🚀 Instalação

### 1. Gerar Chave SSH

```bash
ssh-keygen -t ed25519 -C "k3s-hetzner" -f ~/.ssh/k3s-hetzner
```

### 2. Configurar Token da Hetzner

```bash
export HCLOUD_TOKEN="seu_token_aqui"
```

### 3. Atualizar Configurações

Edite [k3s/cluster-config.yaml](k3s/cluster-config.yaml):
- Atualize `allowed_networks.ssh` e `allowed_networks.api` com seu IP público

### 4. Criar o Cluster

```bash
hetzner-k3s create --config k3s/cluster-config.yaml
```

⏱️ **Tempo estimado**: 5-10 minutos

### 5. Verificar o Cluster

```bash
export KUBECONFIG="./k3s/kubeconfig"
kubectl get nodes
kubectl get pods -A
```

### 6. Executar Pós-Instalação

```bash
chmod +x post-install.sh
./post-install.sh
```

Este script irá:
- ✅ Instalar NGINX Ingress Controller (6 réplicas)
- ✅ Instalar Cert-Manager
- ✅ Configurar Cloudflare DNS01 challenger
- ✅ Criar ClusterIssuer para Let's Encrypt

## ⚙️ Configuração

### NGINX Ingress

O NGINX Ingress está configurado para:
- Usar Load Balancer da Hetzner Cloud
- 6 réplicas para alta disponibilidade
- Executar apenas em nodes com label `ingress=allow`

### Cert-Manager

Configurado para emitir certificados SSL automaticamente usando:
- **Let's Encrypt Production**
- **Cloudflare DNS01** para validação
- Suporte para wildcards (*.exemplo.com)

### Exemplo de Ingress com SSL

```yaml
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: exemplo
  annotations:
    cert-manager.io/cluster-issuer: letsencrypt-production
spec:
  ingressClassName: nginx
  tls:
  - hosts:
    - exemplo.com
    secretName: exemplo-tls
  rules:
  - host: exemplo.com
    http:
      paths:
      - path: /
        pathType: Prefix
        backend:
          service:
            name: exemplo-service
            port:
              number: 80
```

## 🔧 Manutenção

### Comandos Úteis

```bash
# Ver informações do cluster
kubectl cluster-info

# Ver todos os serviços
kubectl get svc -A

# Ver certificados
kubectl get certificate -A

# Ver ClusterIssuer
kubectl get clusterissuer

# Logs do cert-manager
kubectl logs -n cert-manager deployment/cert-manager -f

# Logs do NGINX Ingress
kubectl logs -n ingress-nginx deployment/ingress-nginx-controller -f
```

### Verificar Secret da Cloudflare

```bash
kubectl get secret cloudflare-secret -n cert-manager -o jsonpath='{.data.api-key}' | base64 -d
```

### Atualizar IP Permitido

Se seu IP mudar, edite [k3s/cluster-config.yaml](k3s/cluster-config.yaml#L15-L18) e aplique:

```bash
hetzner-k3s upgrade --config k3s/cluster-config.yaml
```

### Upgrade do Cluster

```bash
# Edite k3s_version em cluster-config.yaml
hetzner-k3s upgrade --config k3s/cluster-config.yaml
```

### Deletar o Cluster

⚠️ **CUIDADO**: Isso remove TODOS os recursos!

```bash
hetzner-k3s delete --config k3s/cluster-config.yaml
```

## 🔍 Troubleshooting

### Problema: Timeout na conexão SSH

**Causa**: Firewall bloqueando IPs

**Solução**: Adicione `10.0.0.0/16` às redes permitidas no [cluster-config.yaml](k3s/cluster-config.yaml)

### Problema: Certificado não é emitido

**Verificar**:
```bash
# Status do certificado
kubectl describe certificate <nome> -n <namespace>

# Logs do cert-manager
kubectl logs -n cert-manager deployment/cert-manager

# Verificar ClusterIssuer
kubectl describe clusterissuer letsencrypt-production
```

**Causas comuns**:
- API Key da Cloudflare inválida
- Domínio não apontando para o Load Balancer
- Rate limit do Let's Encrypt

### Problema: Pods não iniciam

```bash
# Ver eventos
kubectl get events -A --sort-by='.lastTimestamp'

# Descrever pod
kubectl describe pod <nome> -n <namespace>

# Ver logs
kubectl logs <nome> -n <namespace>
```

### Problema: Node não aceita pods

```bash
# Ver taints do node
kubectl describe node <node-name> | grep Taints

# Remover taint se necessário
kubectl taint nodes <node-name> <taint-key>-
```

## 📚 Referências

- [Hetzner K3s](https://github.com/vitobotta/hetzner-k3s)
- [K3s Documentation](https://docs.k3s.io/)
- [NGINX Ingress Controller](https://kubernetes.github.io/ingress-nginx/)
- [Cert-Manager](https://cert-manager.io/docs/)
- [Hetzner Cloud Docs](https://docs.hetzner.com/cloud/)

## 📝 Notas

- **Custo mensal**: 
  - 3x CX23 (Masters): €10.47
  - 3x CX33 (Workers): €16.47
  - 1x LB11 (Load Balancer): €5.39
  - **Total**: ~€32.33/mês
- **Proteção**: `protect_against_deletion: true` ativado
- **Backup**: Configure backups regulares de volumes e dados críticos
- **Monitoramento**: Considere adicionar Prometheus/Grafana para observabilidade

---

**Criado**: Janeiro 2026  
**Mantido por**: Tonny Sousa
