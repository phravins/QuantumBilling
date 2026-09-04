#!/bin/sh
set -e

# Run database migrations before booting the server
if [ "$AUTO_MIGRATE" = "true" ] || [ -z "$AUTO_MIGRATE" ]; then
  echo "[entrypoint] Running database migrations..."
  /app/bin/quantum_billing eval "QuantumBilling.Release.migrate"
fi

echo "[entrypoint] Starting QuantumBilling server..."
exec /app/bin/quantum_billing start
