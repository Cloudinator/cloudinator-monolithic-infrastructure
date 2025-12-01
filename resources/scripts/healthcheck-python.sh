#!/bin/sh
# Healthcheck script for Python applications (Django/FastAPI)

PORT=${PORT:-8000}
HEALTH_ENDPOINT=${HEALTH_ENDPOINT:-/health}

# Try to connect to the health endpoint
response=$(wget --no-verbose --tries=1 --spider --timeout=2 "http://localhost:${PORT}${HEALTH_ENDPOINT}" 2>&1)

if [ $? -eq 0 ]; then
  echo "HEALTHCHECK: Python application is healthy"
  exit 0
else
  echo "HEALTHCHECK: Python application is not responding"
  exit 1
fi
