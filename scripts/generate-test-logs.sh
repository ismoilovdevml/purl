#!/bin/bash
# Generate test logs for Purl
# Usage: ./scripts/generate-test-logs.sh [count] [interval_ms]

PURL_URL="${PURL_URL:-http://localhost:3000}"
COUNT="${1:-100}"
INTERVAL="${2:-100}"  # milliseconds

SERVICES=("api-gateway" "user-service" "order-service" "payment-service" "inventory-service" "notification-service")
LEVELS=("DEBUG" "INFO" "INFO" "INFO" "INFO" "WARNING" "ERROR")
HOSTS=("server-01" "server-02" "server-03")

MESSAGES=(
  "Request received from client"
  "Processing user authentication"
  "Database query executed successfully"
  "Cache hit for key: user_session"
  "Cache miss, fetching from database"
  "API response sent in 45ms"
  "Connection pool: 5/10 connections in use"
  "Background job started: cleanup_sessions"
  "Health check passed"
  "Metrics exported successfully"
  "Rate limit check passed"
  "JWT token validated"
  "User logged in successfully"
  "Order created with ID: ORD-12345"
  "Payment processed successfully"
  "Email notification queued"
  "Inventory updated for product SKU-789"
  "WebSocket connection established"
  "Scheduled task completed"
  "Configuration reloaded"
)

ERROR_MESSAGES=(
  "Connection timeout to database"
  "Failed to process payment: insufficient funds"
  "Rate limit exceeded for IP"
  "Invalid JWT token"
  "Service unavailable: downstream timeout"
  "Failed to send notification"
  "Database connection pool exhausted"
  "Memory usage critical: 95%"
)

WARNING_MESSAGES=(
  "Slow query detected: 2500ms"
  "High memory usage: 80%"
  "Connection retry attempt 2/3"
  "Cache eviction in progress"
  "Deprecated API version used"
)

# Generate a random trace_id (32 hex chars)
gen_trace_id() {
  cat /dev/urandom | LC_ALL=C tr -dc 'a-f0-9' | head -c 32
}

# Generate a random span_id (16 hex chars)
gen_span_id() {
  cat /dev/urandom | LC_ALL=C tr -dc 'a-f0-9' | head -c 16
}

echo "Sending $COUNT test logs to $PURL_URL..."

for i in $(seq 1 $COUNT); do
  SERVICE=${SERVICES[$RANDOM % ${#SERVICES[@]}]}
  HOST=${HOSTS[$RANDOM % ${#HOSTS[@]}]}
  LEVEL=${LEVELS[$RANDOM % ${#LEVELS[@]}]}

  # Select message based on level
  if [ "$LEVEL" == "ERROR" ]; then
    MESSAGE=${ERROR_MESSAGES[$RANDOM % ${#ERROR_MESSAGES[@]}]}
  elif [ "$LEVEL" == "WARNING" ]; then
    MESSAGE=${WARNING_MESSAGES[$RANDOM % ${#WARNING_MESSAGES[@]}]}
  else
    MESSAGE=${MESSAGES[$RANDOM % ${#MESSAGES[@]}]}
  fi

  TRACE_ID=$(gen_trace_id)
  SPAN_ID=$(gen_span_id)
  TIMESTAMP=$(date -u +"%Y-%m-%dT%H:%M:%S.000Z")

  # Create JSON payload
  JSON=$(cat <<EOF
{
  "timestamp": "$TIMESTAMP",
  "level": "$LEVEL",
  "service": "$SERVICE",
  "host": "$HOST",
  "message": "$MESSAGE [request_id=$i]",
  "trace_id": "$TRACE_ID",
  "span_id": "$SPAN_ID",
  "meta": {
    "namespace": "production",
    "pod": "$SERVICE-pod-$((RANDOM % 3 + 1))",
    "node": "node-$((RANDOM % 2 + 1))",
    "container": "$SERVICE",
    "cluster": "main"
  }
}
EOF
)

  # Send to Purl
  curl -s -X POST "$PURL_URL/api/logs" \
    -H "Content-Type: application/json" \
    -H "X-API-Key: local-dev-key" \
    -d "$JSON" > /dev/null

  # Progress
  if [ $((i % 10)) -eq 0 ]; then
    echo "Sent $i/$COUNT logs..."
  fi

  # Sleep interval (convert ms to seconds)
  sleep $(echo "scale=3; $INTERVAL/1000" | bc)
done

echo "Done! Sent $COUNT logs to Purl."
echo "View at: $PURL_URL"
