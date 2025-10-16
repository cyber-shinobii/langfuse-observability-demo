# teardown.sh
# Undo the actions performed by setup.sh on RHEL 9 / AL2023-like hosts
# Safe(ish) & idempotent: skips steps that aren't present

#!/bin/bash
set -uo pipefail

# -------- helpers ----------
log() { printf "\n\033[1;36m[INFO]\033[0m %s\n" "$*"; }
warn(){ printf "\n\033[1;33m[WARN]\033[0m %s\n" "$*"; }
err() { printf "\n\033[1;31m[ERR ]\033[0m %s\n" "$*"; }
run() { # run and never fail the whole script
  "$@"; rc=$?
  [ $rc -ne 0 ] && warn "Command failed (rc=$rc): $*"
  return 0
}
exists(){ command -v "$1" >/dev/null 2>&1; }

SUDO=${SUDO:-"sudo"}
if [ "$EUID" -ne 0 ]; then
  if exists sudo; then SUDO="sudo"; else
    err "Please run as root or install sudo."
    exit 1
  fi
else
  SUDO=""
fi

# Try to use kubectl if available
KUBECTL=""
if exists kubectl; then
  KUBECTL="kubectl"
fi

# -------- 1) K8s user-space resources (before kubeadm reset) ----------
if [ -n "$KUBECTL" ]; then
  log "Tearing down Kubernetes resources created by setup.sh (if present)..."
  # Helm release: langfuse in ns lf
  if exists helm; then
    run $KUBECTL get ns lf >/dev/null 2>&1 && run helm uninstall langfuse -n lf
  fi

  # Langfuse/Splunk/OTel namespace & all objects
  run $KUBECTL delete ns lf --ignore-not-found=true --wait=true

  # Rancher local-path-provisioner (created by applied manifest)
  # Namespace is usually 'local-path-storage' and SC 'local-path'
  run $KUBECTL delete ns local-path-storage --ignore-not-found=true --wait=true
  run $KUBECTL delete storageclass local-path 2>/dev/null || true

  # Calico (best-effort): remove common namespaces & CRDs if present
  run $KUBECTL delete ns calico-system --ignore-not-found=true --wait=true
  # Remove some well-known Calico CRDs (best effort)
  for crd in bgppeers.crd.projectcalico.org \
             bggpeerings.crd.projectcalico.org \
             felixconfigurations.crd.projectcalico.org \
             hostendpoints.crd.projectcalico.org \
             ippools.crd.projectcalico.org \
             kubecontrollersconfigurations.crd.projectcalico.org \
             networkpolicies.crd.projectcalico.org \
             clusterinformations.crd.projectcalico.org; do
    run $KUBECTL delete crd "$crd" 2>/dev/null || true
  done

  # Delete leftover nodeports/services we created (if ns lf is already gone these are gone)
  # No-op if not present due to namespace deletion.
fi

# -------- 2) Kubeadm reset (cleans control-plane state) ----------
if exists kubeadm; then
  log "Resetting kubeadm (this wipes cluster state on this node)..."
  run $SUDO kubeadm reset -f
fi

# -------- 3) Stop/disable kubelet & containerd ----------
log "Stopping and disabling kubelet & containerd (if running)..."
run $SUDO systemctl disable --now kubelet 2>/dev/null || true
run $SUDO systemctl disable --now containerd 2>/dev/null || true

# -------- 4) Remove Kubernetes packages & repo ----------
log "Removing Kubernetes packages and repo (kubelet/kubeadm/kubectl)..."
run $SUDO dnf remove -y kubelet kubeadm kubectl 2>/dev/null || true
run $SUDO rm -f /etc/yum.repos.d/kubernetes.repo

# -------- 5) Remove Kubernetes & CNI data dirs ----------
log "Removing Kubernetes and CNI data directories..."
run $SUDO rm -rf /etc/kubernetes /var/lib/etcd /var/lib/kubelet /var/lib/cni /run/flannel /var/run/flannel
run $SUDO rm -rf /opt/cni/bin

# -------- 6) Remove containerd, runc, CNI plugins ----------
log "Removing containerd, runc, and their configs..."
run $SUDO rm -f /usr/local/bin/containerd /usr/local/bin/containerd-shim* /usr/local/bin/ctr
run $SUDO rm -f /usr/local/sbin/runc
run $SUDO rm -rf /etc/containerd
run $SUDO rm -f /etc/systemd/system/containerd.service
run $SUDO systemctl daemon-reload

# -------- 7) Sysctl & kernel modules revert ----------
log "Reverting sysctl & kernel module configs..."
# Remove files created by setup
run $SUDO rm -f /etc/sysctl.d/k8s.conf
run $SUDO rm -f /etc/modules-load.d/k8s.conf
# Attempt to unload modules after services are down
run $SUDO modprobe -r br_netfilter 2>/dev/null || true
run $SUDO modprobe -r overlay 2>/dev/null || true
# Reload sysctl defaults
run $SUDO sysctl --system

# -------- 8) Re-enable swap (undo swapoff and uncomment /etc/fstab lines we commented) ----------
log "Re-enabling swap (if previously disabled)..."
# Only uncomment lines that were commented AND contain ' swap '
if [ -f /etc/fstab ]; then
  run $SUDO cp -an /etc/fstab /etc/fstab.bak-teardown.$(date +%s)
  run $SUDO sed -i 's/^[#]\([[:space:]]*[^#].*[\t ][ ]\+swap[\t ][ ]\+.*\)$/\1/' /etc/fstab
fi
run $SUDO swapon -a 2>/dev/null || true

# -------- 9) Remove kubeconfig(s) created for current user ----------
log "Removing kubeconfig(s) created by setup.sh..."
# Current user
run rm -f "$HOME/.kube/config" 2>/dev/null || true
# If run with sudo, also clear invoking user's kubeconfig
if [ -n "${SUDO_USER:-}" ] && [ "$SUDO_USER" != "root" ]; then
  SUDO_HOME=$(getent passwd "$SUDO_USER" | cut -d: -f6)
  [ -n "$SUDO_HOME" ] && run rm -f "$SUDO_HOME/.kube/config"
fi

# -------- 10) Remove profile env file created by setup ----------
log "Removing /etc/profile.d/observability.sh ..."
run $SUDO rm -f /etc/profile.d/observability.sh

# -------- 11) Remove Helm binary ----------
if exists helm; then
  log "Removing helm binary..."
  run $SUDO rm -f /usr/local/bin/helm
fi

# -------- 12) Clean up YAML files dropped by setup.sh (in CWD) ----------
log "Removing local YAMLs generated by setup.sh (if still here)..."
for f in secrets.yaml values.yaml splunk-pvc.yaml splunk-deploy.yaml splunk-svc.yaml splunk-nodeport.yaml \
         otel-config.yaml otel-collector.yaml otel-service.yaml get_helm.sh requirements.txt; do
  run rm -f "./$f"
done

# -------- 13) Optionally remove Python deps installed by setup ----------
# We try to uninstall the exact list; ignore failures if not installed.
if exists pip3; then
  log "Uninstalling Python packages installed by setup.sh (best-effort)..."
  pkgs=(
    flask openai langfuse
    opentelemetry.instrumentation
    opentelemetry.instrumentation.flask
    opentelemetry.instrumentation.requests
    opentelemetry.exporter.otlp.proto.grpc
    opentelemetry-sdk
    opentelemetry-semantic-conventions
    opentelemetry-exporter-otlp-proto-http
    opentelemetry-exporter-otlp-proto-grpc
  )
  run pip3 uninstall -y "${pkgs[@]}" 2>/dev/null || true
fi

# -------- 14) DNF clean-up (optional) ----------
log "Cleaning dnf caches..."
run $SUDO dnf clean all -y

# -------- 15) Final status ----------
log "Teardown complete (best-effort)."
echo "You may want to reboot to fully clear kernel module state and mounts."