#!/bin/bash
set -e

SEED_FILE="/opt/oracle/oradata-base.tar.gz"
ORADATA="/opt/oracle/oradata"

mkdir -p "$ORADATA"

if [ -z "$(ls -A "$ORADATA" 2>/dev/null)" ]; then
  echo "MUPOL - Empty ORADATA detected. Restoring base seed..."
  tar -xzf "$SEED_FILE" -C "$ORADATA"
  echo "MUPOL - Base seed restored."
else
  echo "MUPOL - Existing ORADATA detected."
  echo "MUPOL - Database files will NOT be modified."
fi

exec /opt/oracle/runOracle.sh
