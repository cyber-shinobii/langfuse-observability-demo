# Delete ALL PersistentVolumeClaims in the lf namespace
kubectl delete pvc --all -n lf

# Show the last 100 log lines from the web deployment
kubectl logs -n lf deploy/langfuse-web --tail=100

# Inspect the web deployment’s liveness/readiness probe settings
kubectl describe deploy/langfuse-web -n lf | grep -A5 -i "Liveness"

# Hard-reset the Postgres schema to an empty state
kubectl exec -it -n lf langfuse-postgresql-0 -- \
  psql -U langfuse -d postgres_langfuse -c "DROP SCHEMA public CASCADE; CREATE SCHEMA public;"

# Restart the web and worker deployments
kubectl rollout restart deploy/langfuse-web -n lf
kubectl rollout restart deploy/langfuse-worker -n lf

# List all Services in lf to see how to reach things
kubectl get svc -n lf

# Tail recent logs from the web deployment
kubectl logs -n lf deploy/langfuse-web --tail=50

# Temporarily expose the web UI via port-forward on the kube client host
kubectl port-forward -n lf svc/langfuse-web 8000:3000

# Forward traffic from EC2 host → Langfuse web service inside the cluster
kubectl port-forward -n lf svc/langfuse-web --address 0.0.0.0 8000:3000

# Breakdown:
# -n lf                     → use the lf namespace
# svc/langfuse-web          → forward the langfuse-web Service
# --address 0.0.0.0          → bind on all interfaces (not just localhost),
#                              allows external access through the EC2’s public IP
# 8000:3000                 → map host port 8000 → service port 3000

# After running, you can access Langfuse at:
#   http://<ec2-public-ip>:8000
# must allow inbound TCP/8000 in the EC2 security group