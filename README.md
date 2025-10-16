# LLM Observability on a Single EC2 + K8s (Langfuse + OpenTelemetry + Splunk)

A batteries-included template to spin up a **single-node Kubernetes** lab on EC2 and deploy:
- **Langfuse** (LLM tracing/analytics UI, DBs, queue, object store)
- **OpenTelemetry Collector** (OTLP ingest + host metrics)
- **Splunk** (All-in-one w/ HEC input)
- A **sample Python Flask LLM app** instrumented for traces, logs, custom app metrics, host OS metrics, and cost/tokens usage.

This repo includes the **Terraform** to create EC2, the **Kubernetes YAML** to deploy all components, and **Splunk dashboard XML** to visualize LLM & OS telemetry.

> ⚠️ **Security note:** Secrets in this repo are **examples**. For any environment beyond local/lab, rotate credentials, use AWS Secrets Manager/KMS, and restrict security groups.
>
> ⚠️ **Cost note:** This lab runs multiple stateful services (Splunk, ClickHouse, Postgres, Redis, MinIO). Use a small instance only for demos; shut it down when not in use.

---

## Contents

```
langfuse-observability-demo/
├─ app/
│  ├─ app.py                 # Flask route /askquestion + robust OTel/Langfuse/Splunk logs
│  ├─ requirements.txt       # Python deps
│  └─ README-app.md          # Quick start for the sample app (below)
|
├─ scripts/
│  ├─ setup.sh               # one-shot: k8s, helm, langfuse, splunk, otel collector
│  ├─ variables.sh           # env bootstrap (Langfuse, OTel, Splunk, OpenAI, prices)
│  └─ questions.json         # curl payload example for the sample app
│
├─ splunk/
│  ├─ dashboard-traces.xml       # LLM traces/cost/tokens/latency dashboard
│  ├─ dashboard-os-metrics.xml   # Host OS metrics (from OTel hostmetrics receiver)
│  └─ dashboard-app-metrics.xml  # App-level metrics (http.* + custom llm.*)
|
├─ terraform/
│  ├─ main.tf                # EC2 creation (with 50GB root volume)
│  ├─ provider.tf
│  ├─ variables.tf
│  └─ security-groups/       # your SG module (must output SG IDs)
│
└─ TROUBLESHOOTING.md        # Common operational fixes (PVC reset, port-forward, etc.)
```

All paths in this README reference the **files you provided**:
- `terraform/main.tf`, `terraform/provider.tf`, `terraform/variables.tf`
- `scripts/setup.sh`, `scripts/variables.sh`, `scripts/questions.json`
- `app/app.py`, `app/requirements.txt`
- `splunk/dashboard-*.xml`
- `TROUBLESHOOTING.md`

You can keep this layout or adjust, but the flow below assumes it.

---

## What you get

### Services & Ports (NodePort on the single node)
| Component | Purpose | NodePort | Notes |
|---|---|---:|---|
| **Langfuse Web** | LLM traces/analysis UI | `32080` | `http://<EC2-PUBLIC-IP>:32080` |
| **Splunk Web UI** | Dashboards/queries | `32000` | `https://<EC2-PUBLIC-IP>:32000` (admin / `changeme`) |
| **Splunk HEC** | Logs/traces/metrics ingest | `32088` | Token `changeme` (self-signed TLS) |
| **OTel Collector (gRPC)** | OTLP ingest (traces/metrics/logs) | `32417` | Used by apps (`grpc`) |
| **OTel Collector (HTTP)** | OTLP HTTP ingest | `32418` | Optional if you prefer `http/protobuf` |

### Data stores (deployed by Langfuse chart)
- **PostgreSQL** – Langfuse application database
- **ClickHouse** – Trace/observability store
- **Redis** – Caching
- **MinIO (S3)** – Object storage for artifacts

### Observability coverage
- **Traces**: end-to-end span chains for requests and LLM calls (OpenAI via Langfuse SDK drop-in).
- **Logs**: structured logs + stack traces sent via OTel logs → Splunk HEC.
- **App metrics**: `http.server.request.count`, latency histogram, `llm.tokens` counters.
- **OS metrics**: CPU, Memory, Disk, Filesystem, Network, Processes via hostmetrics receiver.
- **LLM economics**: token usage and cost calculated in-app → attached to spans/traces/logs.

---

## Requirements

- AWS account, VPC/subnet ready
- **Terraform** ≥ 1.3
- **ssh** keypair in AWS (`var.key_name_default`, default `dev`)
- An **AMI** compatible with RHEL 9 / Fedora/ Rocky (defaults to a RHEL9-like AMI from your files)
- Security group allowing at least inbound: `22`, `32000`, `32080`, `32088`, `32417`, `32418` from your IP.

> You supply the `security-groups` module that outputs an SG id as `dev_sg_security_group_id`.

---

## Step 1 — Create the EC2 host with Terraform

From `terraform/`:

```bash
terraform init
terraform apply \
  -var='ami_id=ami-0fd3ac4abb734302a' \
  -var='instance_type=m6i.4xlarge' \
  -var='availability_zone=us-east-1a' \
  -var='subnet_id=subnet-xxxxxxxx' \
  -var='key_name_default=dev' \
  -var='num_instances=1'
```

**Outputs:** public IP(s) of the instance(s). SSH in:

```bash
ssh -i /path/to/dev.pem ec2-user@<EC2-PUBLIC-IP>
```

> 💡 **Sizing guidance**: The current telemetry shows low host utilization. For demos, an `m7i-flex.xlarge` (4 vCPU/16GiB) with **50–100GB** EBS will run Langfuse + Splunk + OTel on a single node more cheaply than `m6i.4xlarge`. For heavier data retention or high QPS, scale up.

---

## Step 2 — Bootstrap Kubernetes + Deploy everything

Copy `scripts/setup.sh` to the EC2 and run (can take about 7 minutes to complete):

```bash
chmod +x scripts/setup.sh
sudo ./scripts/setup.sh
```

What it does (high level):
1. Installs **containerd**, **kubelet/kubeadm/kubectl**, **Helm**, CNI plugins.
2. Initializes a **single-node** K8s cluster, installs **Calico**, **local-path** storage.
3. Installs **Langfuse** via Helm (with secrets and fixed NodePort `32080`).
4. Deploys **Splunk** AIO w/ **HEC** enabled and **NodePort** `32000` (UI) / `32088` (HEC).
5. Deploys **OpenTelemetry Collector** with:
   - OTLP receivers (gRPC/HTTP)
   - Hostmetrics receiver (OS metrics)
   - Exporters to **Splunk HEC** for traces/metrics/logs
   - NodePort `32417` (gRPC) and `32418` (HTTP)
6. Sets **/etc/profile.d/observability.sh** to auto-export useful env vars.

When finished, it run the following commands to ensure the pods/services are healthy:
```
kubectl get po -A
kubectl get svc -A
```

---

## Step 3 — Environment Variables

Source the provided **variables.sh** (edit values first!):

Before sourcing the **variables.sh** file, access the Langfuse UI at http://<NODE_IP>:32080 to set up your account, organization, and project. If the signup page doesn’t load correctly, simply refresh the page or use the back button to return to the login screen.

Afterwards, generate and copy your LANGFUSE_SECRET_KEY, LANGFUSE_PUBLIC_KEY, and LANGFUSE_HOST values for use in your environment **variables.sh**. Also, for this demo you will need OpenAI API keys variables. You can create OpenAI API keys using [this link here](https://platform.openai.com/settings/organization/api-keys). Afterwards, update the OPENAI_API_KEY in the **variables.sh** file.


```bash
source scripts/variables.sh
```

This sets:
- **Langfuse**: `LANGFUSE_SECRET_KEY`, `LANGFUSE_PUBLIC_KEY`, `LANGFUSE_HOST`
- **OpenAI**: `OPENAI_API_KEY`, pricing (`OPENAI_PRICE_IN_PER_KTOK`, `OPENAI_PRICE_OUT_PER_KTOK`)
- **Splunk HEC**: `SPLUNK_HEC_URL`, `SPLUNK_HEC_TOKEN`, `SPLUNK_HEC_VERIFY`, `SPLUNK_SOURCETYPE`, `SPLUNK_SOURCE`
- **OTel**: `OTEL_EXPORTER_OTLP_ENDPOINT` (→ `http://<NODE_IP>:32417`), `OTEL_EXPORTER_OTLP_PROTOCOL=grpc`
- `NODE_IP` convenience var (EC2 node’s private IP)

> If you want these in every shell automatically on login, keep `/etc/profile.d/observability.sh` from `setup.sh` or append to `~/.bashrc`.

---

## Step 4 — Sample Python App (Flask + OpenAI + Langfuse + OTel)

### Files
- `app/app.py`
- `app/requirements.txt`

Install and run:

```bash
cd app
pip3 install -r requirements.txt
python3 app.py
```

The app exposes:
- `POST /askquestion` — Body: `{"userType":"tester","question":"..."}`

Instrumentation baked in:
- **Langfuse** Python SDK (`langfuse.openai.ObservedOpenAI`) wraps OpenAI calls and creates observations.
- **OpenTelemetry** manual setup for traces/metrics/logs → exporter = **OTLP** → **OTel Collector** → **Splunk HEC**.
- **Custom metrics**: 
  - `http.server.request.count`
  - `http.server.request.duration`
  - `llm.tokens` (prompt/completion)
- **Cost calc**: uses `OPENAI_PRICE_IN_PER_KTOK` / `OPENAI_PRICE_OUT_PER_KTOK`, attaches `llm.cost.*` to spans/logs.
- **Error handling**: structured error logs to Splunk (w/ `logger.exception`) + structured error outputs to Langfuse spans/trace.

Quick test:

```bash
curl -X POST http://<NODE_IP>:8080/askquestion \
  -H "Content-Type: application/json" \
  -d '{"userType": "tester", "question": "What is 2 + 9?"}'
```

> ✅ See traces in **Langfuse UI**.  
> ✅ See traces/logs/metrics in **Splunk** (indexes: `main` and metrics in `lf_metrics`).

---

## Step 5 — Splunk Dashboards
Login to Splunk http://<NODE_IP>:32000
user: admin
pass: changeme

Import these Classic Dashboard XML files into Splunk:
- `splunk/dashboard-traces.xml` — LLM cost/tokens/latency/errors/recent requests
- `splunk/dashboard-os-metrics.xml` — Host CPU/Load/Memory/FS/Network/Processes (from hostmetrics)
- `splunk/dashboard-app-metrics.xml` — Requests, latency, error rate, tokens per request (OTel app metrics)

**Upload steps:**
1. Splunk UI → **Apps** → **Search & Reporting** → **Dashboards** → **Create New Dashboard** → **Classic Dashboard** → **Source** tab.
2. Paste the XML from the file → **Save**.

### Data notes
- Traces/logs sourcetype: `otel:trace`, index: `main`
- Metrics index: `lf_metrics` (created by `setup.sh`; see that script for automated creation logic).
- Host metrics come from the OTel Collector’s `hostmetrics` receiver.

---

## Kubernetes Manifests & Services (What `setup.sh` applies)

### Langfuse
- Creates **namespace** `lf`
- Applies **Secrets** (`secrets.yaml`) carrying:
  - General salt + encryption key
  - NextAuth secret
  - DB/ClickHouse/Redis/MinIO credentials
- Installs Helm chart with **values.yaml** (sets NodePort for web → `32080`)
- Hard-patches service to NodePort with fixed port

### Splunk AIO
- **Deployment + Services** (`splunk-deploy.yaml`, `splunk-svc.yaml`)
- **NodePort** service `splunk-nodeport.yaml` (web: `32000`, HEC: `32088`)

### OpenTelemetry Collector
- ConfigMap `otel-collector-conf` → `otel-config.yaml`
- Deployment `otel-collector.yaml` with hostPath mounts for `/proc`, `/sys`, `/etc`
- Service `otel-service.yaml` exposes gRPC `32417` and HTTP `32418` NodePorts
- Pipelines:
  - **traces**: `otlp` → `splunk_hec/traces`
  - **metrics**: `otlp` → `splunk_hec/metrics`
  - **logs**: `otlp` → `splunk_hec/logs`
  - **metrics/host**: `hostmetrics` → resource attrs → `splunk_hec/metrics`

---

## How data flows

```
[ Flask app ] --OTLP(traces/logs/metrics)--> [ OTel Collector ] --HEC--> [ Splunk ]
          \____________________________________________ Langfuse SDK ______/
                                         |
                                         +---> [ Langfuse UI + DBs ]
```

- This app **logs errors** with `logger.exception` (OTel LogHandler ⇒ OTLP ⇒ Collector ⇒ Splunk).
- This app **emits spans/metrics** (OTLP ⇒ Collector ⇒ Splunk).
- The OpenAI calls are wrapped by **Langfuse** `ObservedOpenAI`, which mirrors to Langfuse (and it also attaches attributes to OTel spans).

---

## Variables & Tuning

Edit `scripts/variables.sh` for your environment:

```bash
# Langfuse
export LANGFUSE_SECRET_KEY=sk-lf-...
export LANGFUSE_PUBLIC_KEY=pk-lf-...
export LANGFUSE_HOST="http://<NODE_IP>:32080"

# OpenAI
export OPENAI_API_KEY="sk-..."
export OPENAI_PRICE_IN_PER_KTOK=0.150
export OPENAI_PRICE_OUT_PER_KTOK=0.600

# Splunk HEC
export SPLUNK_HEC_URL="https://<NODE_IP>:32088/services/collector"
export SPLUNK_HEC_TOKEN="changeme"
export SPLUNK_HEC_VERIFY="false"
export SPLUNK_SOURCETYPE="otel:trace"
export SPLUNK_SOURCE="flask-app"

# OTel exporter (to collector NodePort)
export OTEL_EXPORTER_OTLP_ENDPOINT="http://<NODE_IP>:32417"
export OTEL_EXPORTER_OTLP_PROTOCOL="grpc"
```

**Inside the app** the following optional envs are read:
- `OTEL_SERVICE_NAME` (default `flask-api`)
- `APP_ENV` (default `dev`)
- `OPENAI_MODEL` (default `gpt-4o-mini`)
- `COST_SPLUNK_SCALE` (default `1.0` if you want to scale costs sent to Splunk)

---

## Troubleshooting

See [`TROUBLESHOOTING.md`](TROUBLESHOOTING.md) for handy commands:
- Wiping PVCs, resetting Postgres schema
- Restarting deployments
- Port-forwarding Langfuse web
- Tail web logs
- Listing services/ports

Common gotchas:
- **HEC TLS** is self-signed. The Collector exporters are set with `insecure_skip_verify: true`. Don’t expose HEC publicly in production.
- If Langfuse web does not come up, check `kubectl logs -n lf deploy/langfuse-web --tail=100` and PVC health.
- If Splunk dashboards show no data: confirm HEC token, index names, and that the OTel Collector pods are healthy.

---

## Extending for other apps/languages

This repo shows a **Python** app with manual OTel + Langfuse. For other stacks:
- **Python (LangChain)**: add `langfuse.langchain.CallbackHandler()` to your chain and keep the same OTel exporter envs.
- **Node/TS**: initialize OTel SDK and use `@langfuse/client` similarly; still ship OTLP to the same Collector NodePort.
- **Multiple endpoints**: the provided Python template instruments **all Flask routes** via `FlaskInstrumentor()` and uses manual spans around LLM calls. Add your own counters/histograms per endpoint if desired.

---

## Clean-up

```bash
# From terraform/
terraform destroy

# Or inside K8s:
kubectl delete ns lf
```

---

## Sample App Notes (`app/app.py`)

- Route: `POST /askquestion`
- Handles errors and returns appropriate HTTP status (400, 401, 429, 502, 500)
- Attaches `llm.usage.*` and `llm.cost.*` attributes to spans and mirrors to Langfuse
- Sends **structured logs** (`request_received`, `request_success`, `request_error`, `openai_api_error`, etc.)

---
