import os
import time
import uuid
import atexit
import platform
import logging
from flask import Flask, request, jsonify

# ---------- Langfuse ----------
from langfuse import get_client
from langfuse.openai import OpenAI as ObservedOpenAI
from openai import APIError, RateLimitError, AuthenticationError

# ---------- OpenTelemetry ----------
from opentelemetry import trace, metrics
from opentelemetry.sdk.resources import Resource
from opentelemetry.sdk.trace import TracerProvider
from opentelemetry.sdk.trace.export import BatchSpanProcessor
from opentelemetry.instrumentation.flask import FlaskInstrumentor
from opentelemetry.instrumentation.requests import RequestsInstrumentor

# OTLP trace exporters
from opentelemetry.exporter.otlp.proto.http.trace_exporter import (
    OTLPSpanExporter as OTLPHTTPSpanExporter,
)
from opentelemetry.exporter.otlp.proto.grpc.trace_exporter import (
    OTLPSpanExporter as OTLPGRPCSpanExporter,
)

# OTLP metrics exporters
from opentelemetry.sdk.metrics import MeterProvider
from opentelemetry.sdk.metrics.export import PeriodicExportingMetricReader
from opentelemetry.exporter.otlp.proto.grpc.metric_exporter import (
    OTLPMetricExporter as OTLPGRPCMetricExporter,
)
from opentelemetry.exporter.otlp.proto.http.metric_exporter import (
    OTLPMetricExporter as OTLPHTTPMetricExporter,
)

# OTLP logs exporters
from opentelemetry.sdk._logs import LoggerProvider, LoggingHandler
from opentelemetry.sdk._logs.export import BatchLogRecordProcessor
from opentelemetry._logs import set_logger_provider
from opentelemetry.exporter.otlp.proto.grpc._log_exporter import (
    OTLPLogExporter as OTLPGRPCLogExporter,
)
from opentelemetry.exporter.otlp.proto.http._log_exporter import (
    OTLPLogExporter as OTLPHTTPLogExporter,
)

# App & SDK initialisation
app = Flask(__name__)

# --- Langfuse client ---
lf = get_client()
atexit.register(lambda: lf.flush() if lf else None)

# --- OpenAI client via Langfuse drop-in ---
client = ObservedOpenAI(api_key=os.environ.get("OPENAI_API_KEY"))
DEFAULT_MODEL = os.environ.get("OPENAI_MODEL", "gpt-4o-mini")

# --- OpenTelemetry base config ---
_SERVICE_NAME = os.getenv("OTEL_SERVICE_NAME", "flask-api")
_ENV = os.getenv("APP_ENV", "dev")

# Default to gRPC because your collector NodePort is 32417; change to "http/protobuf" only if you use :32418
_OTEL_PROTOCOL = os.getenv("OTEL_EXPORTER_OTLP_PROTOCOL", "grpc").lower()
os.environ.setdefault("OTEL_TRACES_EXPORTER", "otlp")
os.environ.setdefault("OTEL_METRICS_EXPORTER", "otlp")
os.environ.setdefault("OTEL_LOGS_EXPORTER", "otlp")

# If someone set HTTP exporter but pointed at the gRPC port, nudge it to the HTTP port (best-effort)
_otlp_endpoint = os.getenv("OTEL_EXPORTER_OTLP_ENDPOINT")
if _otlp_endpoint and _OTEL_PROTOCOL.startswith("http"):
    if ":32417" in _otlp_endpoint:
        os.environ["OTEL_EXPORTER_OTLP_ENDPOINT"] = _otlp_endpoint.replace(":32417", ":32418")

resource = Resource.create(
    {
        "service.name": _SERVICE_NAME,
        "service.namespace": "langfuse-demo",
        "service.instance.id": platform.node(),
        "deployment.environment": _ENV,
    }
)

# -------- Traces --------
current_provider = trace.get_tracer_provider()
if not isinstance(current_provider, TracerProvider):
    trace_provider = TracerProvider(resource=resource)
    trace.set_tracer_provider(trace_provider)
else:
    trace_provider = current_provider

if _OTEL_PROTOCOL.startswith("grpc"):
    span_exporter = OTLPGRPCSpanExporter()  # honors OTEL_EXPORTER_OTLP_ENDPOINT
else:
    span_exporter = OTLPHTTPSpanExporter()

trace_provider.add_span_processor(BatchSpanProcessor(span_exporter))
tracer = trace.get_tracer(__name__)

# -------- Metrics --------
if _OTEL_PROTOCOL.startswith("grpc"):
    metric_exporter = OTLPGRPCMetricExporter()
else:
    metric_exporter = OTLPHTTPMetricExporter()
metric_reader = PeriodicExportingMetricReader(metric_exporter)
meter_provider = MeterProvider(resource=resource, metric_readers=[metric_reader])
metrics.set_meter_provider(meter_provider)
meter = metrics.get_meter(__name__)

request_counter = meter.create_counter(
    "http.server.request.count", unit="1", description="Total requests received"
)
latency_hist = meter.create_histogram(
    "http.server.request.duration", unit="ms", description="Request duration in ms"
)
token_counter = meter.create_counter(
    "llm.tokens", unit="1", description="LLM tokens by type"
)

# -------- Logs --------
if _OTEL_PROTOCOL.startswith("grpc"):
    log_exporter = OTLPGRPCLogExporter()
else:
    log_exporter = OTLPHTTPLogExporter()
log_provider = LoggerProvider(resource=resource)
log_provider.add_log_record_processor(BatchLogRecordProcessor(log_exporter))
set_logger_provider(log_provider)

# Route stdlib logging → OTel (INFO+)
otel_log_handler = LoggingHandler(level=logging.INFO, logger_provider=log_provider)
logging.basicConfig(handlers=[otel_log_handler], level=logging.INFO)
logger = logging.getLogger("flask-api")
logger.propagate = True  # ensure records flow through the OTel handler

# Auto-instrument Flask & Requests (safe-guarded)
try:
    FlaskInstrumentor().instrument_app(app)
except Exception:
    pass
try:
    RequestsInstrumentor().instrument()
except Exception:
    pass

# Helpers
def _scrub_headers(h: dict) -> dict:
    if not h:
        return {}
    redact = {"authorization", "cookie", "x-api-key", "proxy-authorization"}
    return {k: (v if k.lower() not in redact else "[REDACTED]") for k, v in h.items()}

def _get_float_env(name: str, default: float = 0.0) -> float:
    try:
        return float(os.getenv(name, default))
    except Exception:
        return float(default)

PRICE_IN_PER_KTOK  = _get_float_env("OPENAI_PRICE_IN_PER_KTOK", 0.0)
PRICE_OUT_PER_KTOK = _get_float_env("OPENAI_PRICE_OUT_PER_KTOK", 0.0)
COST_SPLUNK_SCALE  = _get_float_env("COST_SPLUNK_SCALE", 1.0)

print(
    f"[pricing] IN_PER_1K={PRICE_IN_PER_KTOK} OUT_PER_1K={PRICE_OUT_PER_KTOK} SCALE_FOR_SPLUNK={COST_SPLUNK_SCALE}",
    flush=True,
)

def compute_llm_cost_usd(prompt_tokens: int, completion_tokens: int):
    input_cost = round((prompt_tokens / 1000.0) * PRICE_IN_PER_KTOK, 6)
    output_cost = round((completion_tokens / 1000.0) * PRICE_OUT_PER_KTOK, 6)
    total_cost = round(input_cost + output_cost, 6)
    return input_cost, output_cost, total_cost

# Route
@app.route("/askquestion", methods=["POST"])
def ask_question():
    started = time.perf_counter()
    request_id = str(uuid.uuid4())
    session_id = str(uuid.uuid4())
    status_code = 500

    # Metrics & log: request received
    request_counter.add(1, {"http.route": "/askquestion", "deployment.environment": _ENV})
    logger.info("request_received", extra={"request.id": request_id, "session.id": session_id})

    user_type = "anonymous"
    question = None
    answer = None

    # ----- Langfuse: root span -----
    with lf.start_as_current_span(name="ask_question_request"):

        # ----- OTel: root span -----
        with tracer.start_as_current_span(
            "ask_question_request",
            attributes={
                "lf.request_id": request_id,
                "lf.session_id": session_id,
                "http.route": "/askquestion",
            },
        ) as root_span:
            try:
                data = request.get_json(force=True) or {}
                user_type = (data.get("userType") or "anonymous")
                question = data.get("question")

                logger.info(
                    "request_parsed",
                    extra={
                        "request.id": request_id,
                        "user.type": user_type,
                        "has.question": bool(question),
                    },
                )

                lf.update_current_span(
                    name="ask_question_request",
                    input={
                        "request_id": request_id,
                        "route": "/askquestion",
                        "client_ip": request.headers.get("X-Forwarded-For", request.remote_addr),
                        "headers": _scrub_headers(dict(request.headers)),
                        "userType": user_type,
                        "question": question,
                    },
                    metadata={"env": _ENV, "service": _SERVICE_NAME, "component": "ask_question"},
                )
                lf.update_current_trace(
                    user_id=user_type,
                    session_id=session_id,
                    input={"question": question},
                )

                root_span.set_attribute("lf.user_id", user_type)
                root_span.set_attribute("request.headers", str(_scrub_headers(dict(request.headers))))
                root_span.set_attribute("llm.input.userType", user_type)
                if question:
                    root_span.set_attribute("llm.input.question", question)

                if not question:
                    status_code = 400
                    latency_ms = int((time.perf_counter() - started) * 1000)
                    latency_hist.record(latency_ms, {"http.route": "/askquestion", "http.status_code": status_code})
                    logger.warning(
                        "request_bad_request",
                        extra={"request.id": request_id, "http.status_code": status_code, "latency_ms": latency_ms},
                    )
                    lf.update_current_span(metadata={"status": "bad_request", "http_status": status_code, "latency_ms": latency_ms})
                    lf.update_current_trace(output={"error": "missing_question"})
                    root_span.set_attribute("http.status_code", status_code)
                    root_span.set_attribute("error", True)
                    root_span.set_attribute("error.type", "bad_request")
                    root_span.set_attribute("latency_ms", latency_ms)
                    return jsonify({"error": "Missing 'question' in body", "sessionId": session_id, "userId": user_type}), status_code

                # ----- LLM span -----
                with tracer.start_as_current_span(
                    "openai.chat.completions.create",
                    attributes={
                        "llm.vendor": "openai",
                        "llm.model": DEFAULT_MODEL,
                        "llm.input.role.system": f"You are answering as user type: {user_type}.",
                        "lf.user_id": user_type,
                        "lf.session_id": session_id,
                    },
                ) as llm_span:

                    # Langfuse observation (generation)
                    with lf.start_as_current_observation(
                        as_type="generation",
                        name="openai-style-generation",
                        model=DEFAULT_MODEL,
                        input=[
                            {"role": "system", "content": f"You are answering as user type: {user_type}."},
                            {"role": "user", "content": question},
                        ],
                    ) as generation:

                        completion = client.chat.completions.create(
                            model=DEFAULT_MODEL,
                            messages=[
                                {"role": "system", "content": f"You are answering as user type: {user_type}."},
                                {"role": "user", "content": question},
                            ],
                            metadata={"langfuse_user_id": user_type, "langfuse_session_id": session_id},
                        )
                        answer = completion.choices[0].message.content

                        usage = getattr(completion, "usage", None) or {}
                        prompt_tokens = int(getattr(usage, "prompt_tokens", 0) or usage.get("prompt_tokens", 0) or 0)
                        completion_tokens = int(getattr(usage, "completion_tokens", 0) or usage.get("completion_tokens", 0) or 0)
                        total_tokens = int(getattr(usage, "total_tokens", 0) or usage.get("total_tokens", 0) or (prompt_tokens + completion_tokens))

                        # Metrics for tokens
                        if prompt_tokens:
                            token_counter.add(prompt_tokens, {"llm.token_type": "prompt", "llm.model": DEFAULT_MODEL})
                        if completion_tokens:
                            token_counter.add(completion_tokens, {"llm.token_type": "completion", "llm.model": DEFAULT_MODEL})

                        logger.info(
                            "llm_usage",
                            extra={
                                "request.id": request_id,
                                "llm.model": DEFAULT_MODEL,
                                "usage.prompt_tokens": prompt_tokens,
                                "usage.completion_tokens": completion_tokens,
                                "usage.total_tokens": total_tokens,
                            },
                        )

                        in_cost, out_cost, total_cost = compute_llm_cost_usd(prompt_tokens, completion_tokens)

                        in_cost_splunk  = round(in_cost  * COST_SPLUNK_SCALE, 6)
                        out_cost_splunk = round(out_cost * COST_SPLUNK_SCALE, 6)
                        total_cost_sp   = round(total_cost * COST_SPLUNK_SCALE, 6)

                        llm_span.set_attribute("llm.usage.prompt_tokens", prompt_tokens)
                        llm_span.set_attribute("llm.usage.completion_tokens", completion_tokens)
                        llm_span.set_attribute("llm.usage.total_tokens", total_tokens)
                        llm_span.set_attribute("llm.cost.input_usd",  in_cost_splunk)
                        llm_span.set_attribute("llm.cost.output_usd", out_cost_splunk)
                        llm_span.set_attribute("llm.cost.usd",        total_cost_sp)
                        if answer:
                            llm_span.set_attribute("llm.output.length", len(answer))
                            llm_span.set_attribute("llm.output.excerpt", answer[:500])

                        generation.update(
                            output=answer,
                            usage_details={
                                "prompt_tokens": prompt_tokens,
                                "completion_tokens": completion_tokens,
                                "total_tokens": total_tokens,
                            },
                            cost_details={"input": in_cost, "output": out_cost, "total": total_cost},
                        )
                        lf.update_current_span(metadata={"llm.cost.source": "app_env_prices"})
                        lf.update_current_trace(metadata={"llm.cost.source": "app_env_prices"})

                        lf.update_current_span(
                            metadata={
                                "llm.model": DEFAULT_MODEL,
                                "llm.usage.prompt_tokens": prompt_tokens,
                                "llm.usage.completion_tokens": completion_tokens,
                                "llm.usage.total_tokens": total_tokens,
                                "llm.cost.input_usd": in_cost,
                                "llm.cost.output_usd": out_cost,
                                "llm.cost.usd": total_cost,
                            }
                        )
                        lf.update_current_trace(metadata={"llm.model": DEFAULT_MODEL, "llm.cost.usd": total_cost})

                        root_span.set_attribute("llm.usage.prompt_tokens", prompt_tokens)
                        root_span.set_attribute("llm.usage.completion_tokens", completion_tokens)
                        root_span.set_attribute("llm.usage.total_tokens", total_tokens)
                        root_span.set_attribute("llm.cost.input_usd",  in_cost_splunk)
                        root_span.set_attribute("llm.cost.output_usd", out_cost_splunk)
                        root_span.set_attribute("llm.cost.usd",        total_cost_sp)

                status_code = 200
                latency_ms = int((time.perf_counter() - started) * 1000)
                lf.update_current_span(output={"answer": answer}, metadata={"status": "ok", "http_status": status_code, "latency_ms": latency_ms})
                lf.update_current_trace(output={"answer": answer})

                root_span.set_attribute("http.status_code", status_code)
                root_span.set_attribute("latency_ms", latency_ms)
                if answer:
                    root_span.set_attribute("llm.output.excerpt", answer[:500])

                latency_hist.record(latency_ms, {"http.route": "/askquestion", "http.status_code": status_code})
                logger.info("request_success", extra={"request.id": request_id, "http.status_code": status_code, "latency_ms": latency_ms})

                return jsonify({"answer": answer, "sessionId": session_id, "userId": user_type}), status_code

            # ---------- Error handling: emit stack traces to Splunk and structured errors to Langfuse ----------
            except RateLimitError as e:
                status_code = 429
                logger.exception("openai_rate_limited", extra={"request.id": request_id})
                lf.update_current_span(
                    output={"error": "rate_limit", "detail": str(e)},
                    metadata={"status": "rate_limited", "http_status": status_code},
                )
                lf.update_current_trace(metadata={"error": True, "error.type": "RateLimitError"})

            except AuthenticationError as e:
                status_code = 401
                logger.exception("openai_auth_error", extra={"request.id": request_id})
                lf.update_current_span(
                    output={"error": "auth_error", "detail": "Invalid or missing API key."},
                    metadata={"status": "auth_error", "http_status": status_code},
                )
                lf.update_current_trace(metadata={"error": True, "error.type": "AuthenticationError"})

            except APIError as e:
                status_code = 502
                logger.exception("openai_api_error", extra={"request.id": request_id})
                lf.update_current_span(
                    output={"error": "openai_api_error", "detail": str(e)},
                    metadata={"status": "openai_api_error", "http_status": status_code},
                )
                lf.update_current_trace(metadata={"error": True, "error.type": "APIError"})

            except Exception as e:
                status_code = 500
                logger.exception("unhandled_exception", extra={"request.id": request_id})
                lf.update_current_span(
                    output={"error": "server_error", "detail": str(e)},
                    metadata={"status": "server_error", "http_status": status_code},
                )
                lf.update_current_trace(metadata={"error": True, "error.type": "Exception"})

            finally:
                if status_code != 200:
                    latency_ms = int((time.perf_counter() - started) * 1000)
                    latency_hist.record(latency_ms, {"http.route": "/askquestion", "http.status_code": status_code})
                    # structured error log (no stack) alongside the exception logs above
                    logger.error(
                        "request_error",
                        extra={"request.id": request_id, "http.status_code": status_code, "latency_ms": latency_ms},
                    )
                    span = trace.get_current_span()
                    if span:
                        span.set_attribute("error", True)
                        span.set_attribute("error.status_code", status_code)

    # If we got here via an exception, return generic server error
    return jsonify({"error": "request_failed"}), status_code


if __name__ == "__main__":
    app.run(host="0.0.0.0", port=8080)