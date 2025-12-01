#!/bin/sh
# Healthcheck script for Spring Boot applications

PORT=${PORT:-8080}
HEALTH_ENDPOINT=${HEALTH_ENDPOINT:-/actuator/health}

# Try to connect to the health endpoint
response=$(wget --no-verbose --tries=1 --spider --timeout=2 "http://localhost:${PORT}${HEALTH_ENDPOINT}" 2>&1)

if [ $? -eq 0 ]; then
  echo "HEALTHCHECK: Spring Boot application is healthy"
  exit 0
else
  echo "HEALTHCHECK: Spring Boot application is not responding"
  exit 1
fi
