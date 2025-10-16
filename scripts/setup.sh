#!/bin/bash
set -euo pipefail

# Update system & install basics
sudo dnf update -y
sudo dnf install -y curl wget jq git tar

# Disable swap
sudo swapoff -a
sudo sed -i '/ swap / s/^\(.*\)$/#\1/g' /etc/fstab

# Enable required kernel modules
sudo modprobe overlay
sudo dnf install -y "kernel-modules-extra-$(uname -r)" || true
sudo modprobe br_netfilter

cat <<EOF | sudo tee /etc/modules-load.d/k8s.conf
overlay
br_netfilter
EOF

# Set sysctl params for Kubernetes networking
cat <<EOF | sudo tee /etc/sysctl.d/k8s.conf
net.bridge.bridge-nf-call-iptables  = 1
net.bridge.bridge-nf-call-ip6tables = 1
net.ipv4.ip_forward                 = 1
EOF
sudo sysctl --system

# Install containerd
export CONTAINERD_VER="1.7.23"
wget -q https://github.com/containerd/containerd/releases/download/v${CONTAINERD_VER}/containerd-${CONTAINERD_VER}-linux-amd64.tar.gz
sudo tar -C /usr/local -xzf containerd-${CONTAINERD_VER}-linux-amd64.tar.gz
rm -f containerd-${CONTAINERD_VER}-linux-amd64.tar.gz

wget -q https://raw.githubusercontent.com/containerd/containerd/main/containerd.service
sudo mv containerd.service /etc/systemd/system/
sudo restorecon -v /etc/systemd/system/containerd.service || true
sudo systemctl daemon-reload
sudo systemctl enable --now containerd

sudo mkdir -p /etc/containerd
sudo /usr/local/bin/containerd config default | sudo tee /etc/containerd/config.toml >/dev/null
sudo sed -i 's/^.*SystemdCgroup = .*/            SystemdCgroup = true/' /etc/containerd/config.toml
sudo systemctl restart containerd
sudo /usr/local/bin/ctr version || true
sudo systemctl status containerd --no-pager || true

# Install runc + CNI plugins
export RUNC_VER="1.1.15"
wget -q https://github.com/opencontainers/runc/releases/download/v${RUNC_VER}/runc.amd64
sudo install -m 755 runc.amd64 /usr/local/sbin/runc
rm -f runc.amd64

export CNI_VER="1.6.0"
wget -q https://github.com/containernetworking/plugins/releases/download/v${CNI_VER}/cni-plugins-linux-amd64-v${CNI_VER}.tgz
sudo mkdir -p /opt/cni/bin
sudo tar -C /opt/cni/bin -xzf cni-plugins-linux-amd64-v${CNI_VER}.tgz
rm -f cni-plugins-linux-amd64-v${CNI_VER}.tgz

# Add Kubernetes repo & install
sudo mkdir -p /etc/yum.repos.d/
cat <<EOF | sudo tee /etc/yum.repos.d/kubernetes.repo
[kubernetes]
name=Kubernetes
baseurl=https://pkgs.k8s.io/core:/stable:/v1.31/rpm/
enabled=1
gpgcheck=1
gpgkey=https://pkgs.k8s.io/core:/stable:/v1.31/rpm/repodata/repomd.xml.key
EOF

sudo dnf install -y kubelet kubeadm kubectl --disableexcludes=kubernetes
sudo systemctl enable --now kubelet

# Initialize cluster
export LOCAL_IP
LOCAL_IP=$(hostname -I | awk '{print $1}')
sudo kubeadm init --apiserver-advertise-address="$LOCAL_IP" \
  --pod-network-cidr=10.244.0.0/16 \
  --cri-socket unix:///var/run/containerd/containerd.sock

# Setup kubeconfig for current user
mkdir -p "$HOME/.kube"
sudo cp -i /etc/kubernetes/admin.conf "$HOME/.kube/config"
sudo chown "$(id -u)":"$(id -g)" "$HOME/.kube/config"

# Networking plugin
kubectl apply -f https://raw.githubusercontent.com/projectcalico/calico/v3.28.0/manifests/calico.yaml

# Allow scheduling on control-plane
kubectl taint nodes --all node-role.kubernetes.io/control-plane- || true

# Local-path storage
kubectl apply -f https://raw.githubusercontent.com/rancher/local-path-provisioner/master/deploy/local-path-storage.yaml
kubectl patch storageclass local-path -p '{"metadata": {"annotations":{"storageclass.kubernetes.io/is-default-class":"true"}}}' || true

# Install Helm
curl -fsSL -o get_helm.sh https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3
chmod +x get_helm.sh
./get_helm.sh
rm -f get_helm.sh

echo "=============================================================="
echo "Kubernetes single-node cluster is ready on RHEL 9!"
echo
echo "Check nodes:    kubectl get nodes"
echo "Check pods:     kubectl get pods -A"
echo "Cluster config: $HOME/.kube/config"
echo "=============================================================="

# Clean up a bit
sudo /usr/local/bin/ctr -n k8s.io images prune || true
sudo journalctl --vacuum-time=3d || true
sudo dnf clean all -y
df -hT

# Langfuse chart + secrets
helm repo add langfuse https://langfuse.github.io/langfuse-k8s
helm repo update
kubectl create namespace lf || true

cat <<'EOF' > secrets.yaml
apiVersion: v1
kind: Namespace
metadata:
  name: lf
---
apiVersion: v1
kind: Secret
metadata:
  name: langfuse-general
  namespace: lf
type: Opaque
stringData:
  salt: "a4d7c9c2f2a44e9c9b8e5c5c3f2e1d0f"
  encryptionKey: "e0c2c1d9a8f1b3c4d5e6f7a8b9c0d1e2f3a4b5c6d7e8f9a0b1c2d3e4f5a6b7c8"
---
apiVersion: v1
kind: Secret
metadata:
  name: langfuse-nextauth-secret
  namespace: lf
type: Opaque
stringData:
  nextauth-secret: "5e1c0a7f9d2b4c8e1f3a6b7c9d0e2f4a"
---
apiVersion: v1
kind: Secret
metadata:
  name: langfuse-postgresql-auth
  namespace: lf
type: Opaque
stringData:
  password: "changeme2024_"
  postgres-password: "changeme2024_"
---
apiVersion: v1
kind: Secret
metadata:
  name: langfuse-clickhouse-auth
  namespace: lf
type: Opaque
stringData:
  password: "changeme2024_"
---
apiVersion: v1
kind: Secret
metadata:
  name: langfuse-redis-auth
  namespace: lf
type: Opaque
stringData:
  password: "changeme2024_"
---
apiVersion: v1
kind: Secret
metadata:
  name: langfuse-s3-auth
  namespace: lf
type: Opaque
stringData:
  rootUser: "minioadmin"
  rootPassword: "Mn_w5Yk8r2Tq0Vx1"
EOF

cat <<'EOF' > values.yaml
langfuse:
  encryptionKey:
    secretKeyRef:
      name: langfuse-general
      key: encryptionKey
  salt:
    secretKeyRef:
      name: langfuse-general
      key: salt
  nextauth:
    secret:
      secretKeyRef:
        name: langfuse-nextauth-secret
        key: nextauth-secret
  resources:
    requests:
      cpu: "1"
      memory: "1Gi"
    limits:
      cpu: "2"
      memory: "2Gi"

postgresql:
  deploy: true
  auth:
    username: langfuse
    existingSecret: langfuse-postgresql-auth
    secretKeys:
      userPasswordKey: password
      adminPasswordKey: postgres-password
  primary:
    persistence:
      storageClass: "local-path"
      size: 10Gi
  resources:
    requests:
      cpu: "0.5"
      memory: "1Gi"
    limits:
      cpu: "1"
      memory: "2Gi"

clickhouse:
  auth:
    existingSecret: langfuse-clickhouse-auth
    existingSecretKey: password
  persistence:
    storageClass: "local-path"
    size: 20Gi
  replicas: 2
  shards: 1
  forcePassword: true
  zookeeper:
    replicas: 2
    persistence:
      storageClass: "local-path"
      size: 5Gi
    resources:
      requests:
        cpu: "0.5"
        memory: "1Gi"
      limits:
        cpu: "1"
        memory: "2Gi"

redis:
  auth:
    existingSecret: langfuse-redis-auth
    existingSecretPasswordKey: password
  primary:
    persistence:
      storageClass: "local-path"
      size: 5Gi
    resources:
      requests:
        cpu: "0.5"
        memory: "512Mi"
      limits:
        cpu: "1"
        memory: "1.5Gi"

s3:
  deploy: true
  auth:
    existingSecret: langfuse-s3-auth
    rootUserSecretKey: rootUser
    rootPasswordSecretKey: rootPassword
  persistence:
    storageClass: "local-path"
    size: 10Gi
  resources:
    requests:
      cpu: "1"
      memory: "1Gi"
    limits:
      cpu: "2"
      memory: "2Gi"

# Expose web as NodePort via chart values (belt)
service:
  web:
    type: NodePort
    nodePort: 32080
EOF

kubectl apply -f secrets.yaml -n lf
helm upgrade --install --force langfuse langfuse/langfuse -n lf -f values.yaml
kubectl -n lf rollout status deploy/langfuse-web

# Hard-patch the existing ClusterIP → NodePort + set fixed nodePort
kubectl -n lf patch svc langfuse-web -p '{"spec":{"type":"NodePort"}}' || true
kubectl -n lf patch svc langfuse-web --type='json' -p='[{"op":"add","path":"/spec/ports/0/nodePort","value":32080}]' || true

# Splunk All-in-One on K8s
kubectl -n lf delete secret splunk-admin 2>/dev/null || true
kubectl -n lf create secret generic splunk-admin --from-literal=admin-password='changeme2024_'

cat <<'EOF' > splunk-pvc.yaml
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: splunk-pvc
  namespace: lf
spec:
  accessModes: ["ReadWriteOnce"]
  storageClassName: local-path
  resources:
    requests:
      storage: 20Gi
EOF
kubectl apply -f splunk-pvc.yaml

cat <<'EOF' > splunk-deploy.yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: splunk
  namespace: lf
spec:
  replicas: 1
  selector:
    matchLabels:
      app: splunk
  template:
    metadata:
      labels:
        app: splunk
    spec:
      containers:
      - name: splunk
        image: splunk/splunk:9.2.1
        ports:
        - containerPort: 8000   # Web UI
        - containerPort: 8089   # mgmt API
        - containerPort: 8088   # HEC
        env:
        - name: SPLUNK_START_ARGS
          value: "--accept-license"
        - name: SPLUNK_PASSWORD
          valueFrom:
            secretKeyRef:
              name: splunk-admin
              key: admin-password
        - name: SPLUNK_HOME
          value: /opt/splunk
        - name: SPLUNK_ENABLE_HEC
          value: "true"
        - name: SPLUNK_HEC_TOKEN
          value: "AutoLangfuseHECToken1234567890"
        volumeMounts:
        - name: splunk-storage
          mountPath: /opt/splunk/var
        readinessProbe:
          httpGet:
            path: /
            port: 8000
          initialDelaySeconds: 90
          periodSeconds: 10
          timeoutSeconds: 5
      volumes:
      - name: splunk-storage
        persistentVolumeClaim:
          claimName: splunk-pvc
EOF
kubectl apply -f splunk-deploy.yaml

cat <<'EOF' > splunk-svc.yaml
apiVersion: v1
kind: Service
metadata:
  name: splunk
  namespace: lf
spec:
  selector:
    app: splunk
  ports:
  - name: web
    port: 8000
    targetPort: 8000
  - name: mgmt
    port: 8089
    targetPort: 8089
  - name: hec
    port: 8088
    targetPort: 8088
EOF
kubectl apply -f splunk-svc.yaml

cat <<'EOF' > splunk-nodeport.yaml
apiVersion: v1
kind: Service
metadata:
  name: splunk-nodeport
  namespace: lf
spec:
  type: NodePort
  selector:
    app: splunk
  ports:
  - name: web
    port: 8000
    targetPort: 8000
    nodePort: 32000
  - name: hec
    port: 8088
    targetPort: 8088
    nodePort: 32088
EOF
kubectl apply -f splunk-nodeport.yaml
kubectl -n lf rollout status deploy/splunk

# OpenTelemetry Collector → Splunk HEC
cat <<'EOF' > otel-config.yaml
apiVersion: v1
kind: ConfigMap
metadata:
  name: otel-collector-conf
  namespace: lf
data:
  otel-collector-config.yaml: |
    receivers:
      otlp:
        protocols:
          grpc:
          http:
      hostmetrics:
        root_path: /host
        collection_interval: 10s
        scrapers:
          cpu: {}
          memory: {}
          disk: {}
          filesystem: {}
          network: {}
          load: {}
          paging: {}
          processes: {}
          # Optional per-process metrics (filter to avoid cardinality blow-ups)
          # process:
          #   mute_process_name_error: true
          #   include:
          #     match_type: regexp
          #     names: ["python.*flask","gunicorn.*"]

    processors:
      batch: {}
      # NEW: detect host attrs (host.name, os.*) and attach to metrics
      resourcedetection/system:
        detectors: [system]
        timeout: 5s
        override: true
      # NEW: optional tidy-up for Splunk faceting
      attributes/host-normalize:
        actions:
          - key: service.name
            action: upsert
            value: host
          - key: service.namespace
            action: upsert
            value: platform
          - key: deployment.environment
            action: upsert
            value: ${APP_ENV}

    exporters:
      # The exporter TYPE is "splunk_hec". Suffixes after "/" are instance names.
      splunk_hec/traces:
        token: "AutoLangfuseHECToken1234567890"
        endpoint: "https://splunk.lf.svc.cluster.local:8088/services/collector"
        source: "langfuse"
        sourcetype: "otel:trace"
        index: "main"
        timeout: 10s
        tls:
          insecure_skip_verify: true
        sending_queue:
          enabled: true
          num_consumers: 8
          queue_size: 10000
        retry_on_failure:
          enabled: true
          initial_interval: 2s
          max_interval: 30s
          max_elapsed_time: 5m

      splunk_hec/metrics:
        token: "AutoLangfuseHECToken1234567890"
        endpoint: "https://splunk.lf.svc.cluster.local:8088/services/collector"
        source: "langfuse"
        sourcetype: "otel:metric"
        index: "lf_metrics"
        timeout: 10s
        tls:
          insecure_skip_verify: true
        sending_queue:
          enabled: true
          num_consumers: 8
          queue_size: 10000
        retry_on_failure:
          enabled: true
          initial_interval: 2s
          max_interval: 30s
          max_elapsed_time: 5m

      splunk_hec/logs:
        token: "AutoLangfuseHECToken1234567890"
        endpoint: "https://splunk.lf.svc.cluster.local:8088/services/collector"
        source: "langfuse"
        sourcetype: "otel:log"
        index: "main"
        timeout: 10s
        tls:
          insecure_skip_verify: true
        sending_queue:
          enabled: true
          num_consumers: 8
          queue_size: 10000
        retry_on_failure:
          enabled: true
          initial_interval: 2s
          max_interval: 30s
          max_elapsed_time: 5m

    service:
      pipelines:
        traces:
          receivers: [otlp]
          processors: [batch]
          exporters: [splunk_hec/traces]
        metrics:
          receivers: [otlp]
          processors: [batch]
          exporters: [splunk_hec/metrics]
        logs:
          receivers: [otlp]
          processors: [batch]
          exporters: [splunk_hec/logs]
        # NEW: parallel pipeline for host OS metrics (named metrics pipeline)
        metrics/host:
          receivers: [hostmetrics]
          processors: [resourcedetection/system, attributes/host-normalize, batch]
          exporters: [splunk_hec/metrics]

EOF
kubectl apply -f otel-config.yaml

cat <<'EOF' > otel-collector.yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: otel-collector
  namespace: lf
spec:
  replicas: 1
  selector:
    matchLabels:
      app: otel-collector
  template:
    metadata:
      labels:
        app: otel-collector
    spec:
      containers:
      - name: otel-collector
        image: otel/opentelemetry-collector-contrib:0.98.0
        args: ["--config=/etc/otel-collector-config.yaml"]
        ports:
        - containerPort: 4317 # gRPC
        - containerPort: 4318 # HTTP
        env:
        - name: HOST_PROC
          value: /host/proc
        - name: HOST_SYS
          value: /host/sys
        - name: HOST_ETC
          value: /host/etc
        - name: APP_ENV
          value: "dev"
        volumeMounts:
        - name: otel-config-vol
          mountPath: /etc/otel-collector-config.yaml
          subPath: otel-collector-config.yaml
        # NEW: host namespace mounts (read-only)
        - name: host-proc
          mountPath: /host/proc
          readOnly: true
        - name: host-sys
          mountPath: /host/sys
          readOnly: true
        - name: host-etc
          mountPath: /host/etc
          readOnly: true
      volumes:
      - name: otel-config-vol
        configMap:
          name: otel-collector-conf
      # NEW: hostPath volumes
      - name: host-proc
        hostPath:
          path: /proc
          type: Directory
      - name: host-sys
        hostPath:
          path: /sys
          type: Directory
      - name: host-etc
        hostPath:
          path: /etc
          type: Directory
EOF
kubectl apply -f otel-collector.yaml

# Make the collector a NodePort with FIXED ports 
cat <<'EOF' > otel-service.yaml
apiVersion: v1
kind: Service
metadata:
  name: otel-collector
  namespace: lf
spec:
  selector:
    app: otel-collector
  type: NodePort
  ports:
  - name: grpc
    port: 4317
    targetPort: 4317
    nodePort: 32417
  - name: http
    port: 4318
    targetPort: 4318
    nodePort: 32418
EOF
kubectl apply -f otel-service.yaml
kubectl -n lf rollout status deploy/otel-collector

# Also wire Langfuse components → OTEL via in-cluster DNS
kubectl -n lf set env deployment/langfuse-web \
  OTEL_EXPORTER_OTLP_ENDPOINT="http://otel-collector.lf.svc.cluster.local:4317" \
  OTEL_EXPORTER_OTLP_PROTOCOL="grpc" || true
kubectl -n lf set env deployment/langfuse-worker \
  OTEL_EXPORTER_OTLP_ENDPOINT="http://otel-collector.lf.svc.cluster.local:4317" \
  OTEL_EXPORTER_OTLP_PROTOCOL="grpc" || true

# Create Splunk 'lf_metrics' index once Splunk is up
# Read admin password from secret
ADMIN_PW="$(kubectl -n lf get secret splunk-admin -o jsonpath='{.data.admin-password}' | base64 -d)"

# Grab Splunk pod name
SPLUNK_POD="$(kubectl -n lf get pods -l app=splunk -o jsonpath='{.items[0].metadata.name}')"

# Wait for Splunk mgmt API inside the pod
echo "Waiting for Splunk management API inside pod ${SPLUNK_POD} ..."
kubectl -n lf exec "$SPLUNK_POD" -- bash -lc 'until curl -ks --connect-timeout 5 -u "admin:'"$ADMIN_PW"'" https://localhost:8089/services/server/info >/dev/null 2>&1; do sleep 5; done'
echo "Splunk management API is up."

# Create metrics index if missing
# Check if lf_metrics exists 
EXISTS=$(kubectl -n lf exec "$SPLUNK_POD" -- bash -lc 'curl -ks -u "admin:'"$ADMIN_PW"'" \
  "https://localhost:8089/services/data/indexes?output_mode=json" \
  | grep -q "\"name\":\"lf_metrics\"" && echo true || echo false')

if [ "$EXISTS" != "true" ]; then
  echo "Creating Splunk lf_metrics index..."
  kubectl -n lf exec "$SPLUNK_POD" -- bash -lc 'curl -ks -u "admin:'"$ADMIN_PW"'" \
    -X POST https://localhost:8089/services/data/indexes \
    -d name=lf_metrics -d datatype=metric >/dev/null'
else
  echo "Splunk lf_metrics index already exists."
fi

# Auto-export LANGFUSE_HOST + OTEL_* on every login
sudo tee /etc/profile.d/observability.sh >/dev/null <<'EOS'
# Auto-generated: Observability env for host-based apps (Flask, etc.)
export NODE_IP=$(hostname -I | awk '{print $1}')
export LANGFUSE_HOST="http://${NODE_IP}:32080"
export OTEL_EXPORTER_OTLP_ENDPOINT="http://${NODE_IP}:32417"
export OTEL_EXPORTER_OTLP_PROTOCOL="grpc"
export OTEL_SERVICE_NAME="flask-api"
export OTEL_RESOURCE_ATTRIBUTES="service.version=dev,deployment.environment=dev"
EOS
sudo chmod +x /etc/profile.d/observability.sh
# Load into current shell too:
source /etc/profile.d/observability.sh || true

# Show endpoints
NODE_IP=$(hostname -I | awk '{print $1}')
echo "=============================================================="
echo "Langfuse UI:  http://${NODE_IP}:32080"
echo "Splunk UI:    http://${NODE_IP}:32000  (admin / changeme)"
echo "Splunk HEC:   https://${NODE_IP}:32088/services/collector"
echo "HEC TOKEN:    AutoLangfuseHECToken1234567890"
echo "OTEL gRPC:    ${OTEL_EXPORTER_OTLP_ENDPOINT}"
echo "=============================================================="

# Python + pip + requirements
sudo dnf install -y python3 python3-pip

# Create requirements.txt inline
cat <<'EOF' > requirements.txt
flask
openai
langfuse
opentelemetry.instrumentation
opentelemetry.instrumentation.flask
opentelemetry.instrumentation.requests
opentelemetry.exporter.otlp.proto.grpc
opentelemetry-sdk
opentelemetry-semantic-conventions
opentelemetry-exporter-otlp-proto-http
opentelemetry-exporter-otlp-proto-grpc
EOF

# Install Python dependencies system-wide
pip3 install -r requirements.txt