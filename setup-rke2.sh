#!/usr/bin/env bash
set -euo pipefail

# ===================== User Configuration =====================
# Adjust these variables before running the script to match your
# environment. You can also export them as environment variables
# instead of editing the file directly.

# Node purpose: login, server-init (first control-plane), server-join (additional control-plane), agent (worker)
NODE_TYPE="${NODE_TYPE:-server-init}"

# FQDN of the current node (used for TLS SAN generation)
NODE_FQDN="${NODE_FQDN:-node1.example.com}"

# Comma-separated TLS Subject Alternative Names for the server nodes
TLS_SANS="${TLS_SANS:-node1.example.com,node2.example.com,node3.example.com}"

# URL of the first server node (needed for server-join and agent)
PRIMARY_SERVER_URL="${PRIMARY_SERVER_URL:-https://node1.example.com:9345}"

# Pre-shared token from the first server (for server-join and agent)
NODE_TOKEN="${NODE_TOKEN:-REPLACE_ME_WITH_NODE_TOKEN}"

# RKE2 channel and CIDR settings
INSTALL_CHANNEL="${INSTALL_CHANNEL:-stable}"
CLUSTER_CIDR="${CLUSTER_CIDR:-10.42.0.0/16}"
SERVICE_CIDR="${SERVICE_CIDR:-10.43.0.0/16}"

# Set to 1 to disable UFW on Ubuntu hosts
DISABLE_FIREWALL="${DISABLE_FIREWALL:-1}"

# ===================== Helper Functions =====================
require_root() {
  if [[ ${EUID} -ne 0 ]]; then
    echo "[ERROR] This script must be run as root." >&2
    exit 1
  fi
}

configure_networking() {
  echo "[INFO] Configuring networking and kernel prerequisites"

  mkdir -p /etc/NetworkManager/conf.d
  cat <<'CONF' >/etc/NetworkManager/conf.d/rke2-canal.conf
[keyfile]
unmanaged-devices=interface-name:cali*;interface-name:flannel*
CONF

  if [[ "${DISABLE_FIREWALL}" == "1" ]] && command -v systemctl >/dev/null 2>&1; then
    if systemctl is-enabled ufw >/dev/null 2>&1; then
      systemctl stop ufw || true
      systemctl disable ufw || true
    fi
  fi

  sed -i '/ swap / s/^\(.*\)$/#\1/g' /etc/fstab || true
  swapoff -a || true

  modprobe br_netfilter || true

  cat <<'SYSCTL' >/etc/sysctl.d/kubernetes.conf
net.bridge.bridge-nf-call-ip6tables = 1
net.bridge.bridge-nf-call-iptables = 1
net.ipv4.ip_forward = 1
net.ipv6.conf.all.forwarding = 1
SYSCTL
  sysctl --system >/dev/null
}

install_login_tools() {
  echo "[INFO] Installing login node utilities (docker, git, kubectl, kubectx/kubens, k9s, helm)"
  apt-get update -y
  apt-get install -y curl git ca-certificates

  if ! command -v docker >/dev/null 2>&1; then
    curl -fsSL https://releases.rancher.com/install-docker/20.10.sh | sh
    usermod -aG docker "${SUDO_USER:-${USER}}" || true
    systemctl enable --now docker
  fi

  if ! command -v kubectl >/dev/null 2>&1; then
    curl -Lo /usr/local/bin/kubectl "https://dl.k8s.io/release/$(curl -L -s https://dl.k8s.io/release/stable.txt)/bin/linux/amd64/kubectl"
    chmod +x /usr/local/bin/kubectl
  fi

  if [[ ! -d /opt/kubectx ]]; then
    git clone https://github.com/ahmetb/kubectx /opt/kubectx
    ln -sf /opt/kubectx/kubectx /usr/local/bin/kubectx
    ln -sf /opt/kubectx/kubens /usr/local/bin/kubens
  fi

  if ! command -v k9s >/dev/null 2>&1; then
    curl -Lo /tmp/k9s_Linux_x86_64.tar.gz "https://github.com/derailed/k9s/releases/download/v0.27.4/k9s_Linux_amd64.tar.gz"
    tar -C /usr/local/bin -zxf /tmp/k9s_Linux_x86_64.tar.gz k9s
  fi

  if ! command -v helm >/dev/null 2>&1; then
    curl https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash
  fi
}

install_rke2() {
  local install_type="$1"
  echo "[INFO] Installing RKE2 (${install_type})"
  mkdir -p /usr/local/bin
  curl -sfL https://get.rke2.io -o /usr/local/bin/install-rke2.sh
  chmod +x /usr/local/bin/install-rke2.sh
  INSTALL_RKE2_CHANNEL="${INSTALL_CHANNEL}" INSTALL_RKE2_TYPE="${install_type}" /usr/local/bin/install-rke2.sh
}

write_tls_sans() {
  local sans_list sans
  sans_list=(${TLS_SANS//,/ })
  for sans in "${sans_list[@]}"; do
    echo "  - ${sans}"
  done
}

configure_server_init() {
  install_rke2 "server"
  mkdir -p /etc/rancher/rke2
  cat <<'RKE2CFG' >/etc/rancher/rke2/config.yaml
tls-san:
RKE2CFG
  write_tls_sans >>/etc/rancher/rke2/config.yaml
  cat <<RKE2CFG >>/etc/rancher/rke2/config.yaml
node-taint:
  - "CriticalAddonsOnly=true:NoExecute"
disable: rke2-ingress-nginx
write-kubeconfig-mode: 644
cluster-cidr: ${CLUSTER_CIDR}
service-cidr: ${SERVICE_CIDR}
RKE2CFG
  systemctl enable rke2-server.service
  systemctl restart rke2-server.service
  echo "[INFO] Primary server bootstrap complete. Node token:" >&2
  cat /var/lib/rancher/rke2/server/node-token
}

configure_server_join() {
  install_rke2 "server"
  mkdir -p /etc/rancher/rke2
  cat <<'RKE2CFG' >/etc/rancher/rke2/config.yaml
server: ${PRIMARY_SERVER_URL}
token: ${NODE_TOKEN}
write-kubeconfig-mode: "0644"
tls-san:
RKE2CFG
  write_tls_sans >>/etc/rancher/rke2/config.yaml
  cat <<'RKE2CFG' >>/etc/rancher/rke2/config.yaml
node-taint:
  - "CriticalAddonsOnly=true:NoExecute"
disable: rke2-ingress-nginx
RKE2CFG
  systemctl enable rke2-server.service
  systemctl restart rke2-server.service
}

configure_agent() {
  install_rke2 "agent"
  mkdir -p /etc/rancher/rke2
  cat <<'RKE2CFG' >/etc/rancher/rke2/config.yaml
server: ${PRIMARY_SERVER_URL}
token: ${NODE_TOKEN}
RKE2CFG
  systemctl enable rke2-agent.service
  systemctl restart rke2-agent.service
}

main() {
  require_root
  configure_networking

  case "${NODE_TYPE}" in
    login)
      install_login_tools
      ;;
    server-init)
      configure_server_init
      ;;
    server-join)
      configure_server_join
      ;;
    agent)
      configure_agent
      ;;
    *)
      echo "[ERROR] Unknown NODE_TYPE '${NODE_TYPE}'. Use login|server-init|server-join|agent." >&2
      exit 1
      ;;
  esac

  echo "[INFO] Completed actions for ${NODE_TYPE} node (${NODE_FQDN})."
}

main "$@"
