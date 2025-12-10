#!/bin/bash
# Send Docker container logs to Purl
# Usage: ./send-docker-logs.sh <container_name> [purl_url]

CONTAINER=${1:-purl}
PURL_URL=${2:-http://localhost:3000}

echo "Sending logs from container: $CONTAINER to $PURL_URL"

docker logs "$CONTAINER" 2>&1 | while IFS= read -r line; do
    # Skip empty lines
    [ -z "$line" ] && continue

    # Detect level from log line
    LEVEL="INFO"
    case "$line" in
        *error*|*ERROR*|*Error*) LEVEL="ERROR" ;;
        *warn*|*WARN*|*Warn*) LEVEL="WARN" ;;
        *debug*|*DEBUG*|*Debug*) LEVEL="DEBUG" ;;
    esac

    # Escape special characters for JSON
    ESCAPED=$(echo "$line" | sed 's/\\/\\\\/g; s/"/\\"/g; s/	/\\t/g')

    # Send to Purl
    curl -s -X POST "$PURL_URL/api/logs" \
        -H "Content-Type: application/json" \
        -d "{\"level\":\"$LEVEL\",\"service\":\"$CONTAINER\",\"host\":\"docker\",\"message\":\"$ESCAPED\"}" \
        > /dev/null
done

echo "Done!"
