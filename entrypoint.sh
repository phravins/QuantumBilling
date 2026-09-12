#!/bin/sh
set -e

# Run database migrations using Phoenix Release tasks
bin/quantum_billing eval "QuantumBilling.Release.migrate"

# Launch Phoenix Web Server
exec bin/quantum_billing start
