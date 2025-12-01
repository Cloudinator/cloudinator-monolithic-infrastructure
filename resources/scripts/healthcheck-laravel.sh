#!/bin/sh
# Healthcheck script for Laravel applications

PORT=${PORT:-8000}

# Simple TCP connection check
nc -z localhost ${PORT}

if [ $? -eq 0 ]; then
  echo "HEALTHCHECK: Laravel application is healthy"
  exit 0
else
  echo "HEALTHCHECK: Laravel application is not responding"
  exit 1
fi
