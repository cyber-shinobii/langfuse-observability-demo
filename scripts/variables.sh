#!/usr/bin/env bash

# Langfuse + Splunk + OTel env bootstrap

# --- Langfuse ---
export LANGFUSE_SECRET_KEY=changeme
export LANGFUSE_PUBLIC_KEY=changeme
export LANGFUSE_HOST="http://changeme:32080"

# --- OpenAI ---
export OPENAI_API_KEY="changeme"
export OPENAI_PRICE_IN_PER_KTOK=0.150   # $0.15 per 1K input tokens
export OPENAI_PRICE_OUT_PER_KTOK=0.600 # $0.60 per 1K output tokens

# --- Kubernetes node IP (internal) ---
export NODE_IP=$(hostname -I | awk '{print $1}')

# --- Splunk HEC ---
export SPLUNK_HEC_URL="https://${NODE_IP}:32088/services/collector"
export SPLUNK_HEC_TOKEN="changeme"
export SPLUNK_HEC_VERIFY="false"
export SPLUNK_SOURCETYPE="langfuse:trace"
export SPLUNK_SOURCE="flask-app"

# --- OTel exporter ---
export OTEL_EXPORTER_OTLP_ENDPOINT="http://${NODE_IP}:32417"
export OTEL_EXPORTER_OTLP_PROTOCOL="grpc"

# --- Summary message ---
echo "[INFO] Environment variables for Langfuse + OTel + Splunk have been set."
echo "[INFO] NODE_IP resolved to: $NODE_IP"