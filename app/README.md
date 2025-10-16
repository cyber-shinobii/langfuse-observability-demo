# LLM Observability Example App (Flask + Langfuse + OpenTelemetry + Splunk)

This sample Python app demonstrates how to **instrument a Flask-based LLM API endpoint** using **Langfuse**, **OpenTelemetry**, and **Splunk**. It captures **traces, metrics, and logs** end-to-end — including token usage, latency, and cost per request — while sending observability data to both **Langfuse** and **Splunk** via an OpenTelemetry Collector.

---

## Overview

The `app.py` file provides a simple API endpoint `/askquestion` that:
- Accepts a JSON payload containing a user type and question.
- Uses **Langfuse’s OpenAI drop-in client** to interact with an LLM (e.g., GPT-4 or GPT-4o-mini).
- Automatically records **traces**, **logs**, and **metrics** through OpenTelemetry.
- Sends all telemetry data (traces, metrics, logs) to a **Splunk HEC endpoint** through an **OpenTelemetry Collector**.
- Logs errors and token/cost data to both **Langfuse** and **Splunk**.

---

## Features

| Category | Description |
|-----------|-------------|
| **Tracing** | End-to-end span tracking for Flask requests and OpenAI completions. |
| **Metrics** | Request count, request latency, and LLM token usage (`llm.tokens`). |
| **Logging** | Structured logs via OpenTelemetry LogExporter (both info and exceptions). |
| **Error Handling** | Catches API, rate limit, auth, and generic errors, sending structured data to both Langfuse and Splunk. |
| **LLM Cost Tracking** | Dynamically computes input/output cost using env-based pricing variables. |
| **Environment-Aware Configuration** | Automatically adapts to `grpc` or `http` exporters based on the OTLP protocol used. |

---

## Quick Start

### 1. Install Dependencies

```bash
pip install flask openai langfuse opentelemetry-sdk opentelemetry-api   opentelemetry-instrumentation-flask opentelemetry-instrumentation-requests   opentelemetry-exporter-otlp-proto-grpc opentelemetry-exporter-otlp-proto-http
```

### 2. Set Environment Variables

Create a file named `.env` (or export manually):

```bash
# --- Langfuse ---
export LANGFUSE_SECRET_KEY="sk-lf-xxxxxxxx"
export LANGFUSE_PUBLIC_KEY="pk-lf-xxxxxxxx"
export LANGFUSE_HOST="http://<langfuse-host>:32080"

# --- OpenAI ---
export OPENAI_API_KEY="sk-proj-xxxxxxxx"
export OPENAI_MODEL="gpt-4o-mini"
export OPENAI_PRICE_IN_PER_KTOK=0.150
export OPENAI_PRICE_OUT_PER_KTOK=0.600
export COST_SPLUNK_SCALE=1.0

# --- OpenTelemetry / Splunk ---
export OTEL_SERVICE_NAME="flask-api"
export APP_ENV="dev"
export OTEL_EXPORTER_OTLP_PROTOCOL="grpc"
export OTEL_EXPORTER_OTLP_ENDPOINT="http://<node-ip>:32417"

# --- Optional: adjust if you use HTTP exporter ---
# export OTEL_EXPORTER_OTLP_PROTOCOL="http/protobuf"
# export OTEL_EXPORTER_OTLP_ENDPOINT="http://<node-ip>:32418"
```

If using the **langfuse-observability-demo** Kubernetes lab, these values will already match your NodePort setup.

---

### 3. Run the App

```bash
python app.py
```

It starts a local Flask server on port `8080`:

```
 * Serving Flask app 'app'
 * Running on http://0.0.0.0:8080 (Press CTRL+C to quit)
```

---

### 4. Send a Test Request

```bash
curl -X POST http://localhost:8080/askquestion   -H "Content-Type: application/json"   -d '{"userType":"tester","question":"What is 2 + 9?"}'
```

**Expected response:**
```json
{
  "answer": "2 + 9 = 11",
  "sessionId": "<uuid>",
  "userId": "tester"
}
```

---

## How It Works

### ⚙️ 1. Instrumentation Flow
1. **FlaskInstrumentor** and **RequestsInstrumentor** automatically trace HTTP requests.
2. The `ObservedOpenAI` client from Langfuse wraps OpenAI API calls to record LLM traces and metadata.
3. OpenTelemetry exporters forward all traces, logs, and metrics to your OTel Collector.
4. The Collector sends the data to Splunk’s HEC input (for traces, logs, and metrics).
5. Langfuse also receives the same traces directly via its Python SDK.

```
[ Flask /app.py ] → [ OTLP Exporters ] → [ OTel Collector ] → [ Splunk HEC ]
                          ↓
                     [ Langfuse API ]
```

---

### 📊 2. Metrics Emitted

| Metric | Type | Description |
|---------|------|-------------|
| `http.server.request.count` | Counter | Number of requests received |
| `http.server.request.duration` | Histogram | Request latency (ms) |
| `llm.tokens` | Counter | Tokens processed by type (prompt / completion) |

---

### 🧠 3. Tracing Attributes

Every request generates spans with attributes like:

| Attribute | Example Value | Description |
|------------|----------------|-------------|
| `llm.vendor` | `openai` | LLM provider |
| `llm.model` | `gpt-4o-mini` | Model name |
| `llm.usage.prompt_tokens` | 45 | Tokens sent |
| `llm.usage.completion_tokens` | 12 | Tokens returned |
| `llm.cost.usd` | 0.0072 | Computed cost |
| `deployment.environment` | `dev` | Environment tag |

---

### 🧾 4. Logging

Logs are emitted as OpenTelemetry `LogRecords`, automatically exported to the OTel Collector, and ingested by Splunk.

**Example logs in Splunk:**
| Level | Message | Fields |
|--------|----------|--------|
| `INFO` | `request_received` | `request.id`, `session.id` |
| `INFO` | `llm_usage` | `prompt_tokens`, `completion_tokens`, `total_tokens` |
| `ERROR` | `request_error` | `error.type`, `http.status_code`, `latency_ms` |

---

### 🚨 5. Error Handling

All exceptions are logged via Python’s `logger.exception()` (captured by OpenTelemetry) and recorded in Langfuse as error spans.

| Error Type | Status | Handling |
|-------------|--------|-----------|
| `RateLimitError` | 429 | Logged, trace marked as rate-limited |
| `AuthenticationError` | 401 | Logged, trace marked as auth error |
| `APIError` | 502 | Logged, trace marked as upstream failure |
| Generic Exception | 500 | Logged, trace marked as unhandled error |

---

## Integration Points

| Component | Purpose | Notes |
|------------|----------|-------|
| **Langfuse SDK** | Tracing + analytics for LLMs | Sends traces, spans, and token usage |
| **OpenTelemetry SDK** | Unified telemetry | Collects traces, logs, and metrics |
| **Splunk HEC** | Observability backend | Receives OTLP data via the OTel Collector |
| **OTel Collector** | Export proxy | Aggregates and forwards telemetry data |

---

## Environment Variables Summary

| Variable | Default | Description |
|-----------|----------|-------------|
| `OTEL_EXPORTER_OTLP_PROTOCOL` | `grpc` | OTLP exporter protocol (`grpc` or `http/protobuf`) |
| `OTEL_EXPORTER_OTLP_ENDPOINT` | `http://localhost:4317` | Collector endpoint |
| `OTEL_SERVICE_NAME` | `flask-api` | Service name label |
| `APP_ENV` | `dev` | Environment label |
| `OPENAI_MODEL` | `gpt-4o-mini` | Default model |
| `OPENAI_PRICE_IN_PER_KTOK` | `0.15` | Input cost per 1K tokens |
| `OPENAI_PRICE_OUT_PER_KTOK` | `0.60` | Output cost per 1K tokens |
| `COST_SPLUNK_SCALE` | `1.0` | Scaling factor for reporting cost in Splunk |

---

## Dashboarding in Splunk

Use the **LLM App Metrics Dashboard** (`dashboard-app-metrics.xml`) to visualize:
- Total requests and success/error breakdowns  
- LLM token consumption by type  
- Cost per session and latency histograms  

---

## Next Steps

- Replace `app.py` with your own API logic — the observability setup will automatically capture telemetry.
- Integrate with additional Langfuse features like **LangChain callback handlers**.
- Extend metrics with custom counters (e.g., requests per userType).

---