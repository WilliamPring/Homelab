#!/bin/sh
# postgres-setup.sh — configure the Alpine Postgres LXC for Vaultwarden.
# Run as ROOT inside the Postgres LXC:   sh postgres-setup.sh
# Idempotent — safe to re-run (re-running resets the password).
set -eu

DB_NAME="vaultwarden"
DB_USER="vaultwarden"
LAN_CIDR="192.168.68.0/24"
DB_PASS="$(tr -dc 'A-Za-z0-9' < /dev/urandom | head -c 32)"

echo ">> role '${DB_USER}'..."
if [ -z "$(su postgres -c "psql -tAc \"SELECT 1 FROM pg_roles WHERE rolname='${DB_USER}'\"")" ]; then
  su postgres -c "psql -c \"CREATE ROLE ${DB_USER} LOGIN PASSWORD '${DB_PASS}';\""
else
  su postgres -c "psql -c \"ALTER ROLE ${DB_USER} PASSWORD '${DB_PASS}';\""
fi

echo ">> database '${DB_NAME}'..."
if [ -z "$(su postgres -c "psql -tAc \"SELECT 1 FROM pg_database WHERE datname='${DB_NAME}'\"")" ]; then
  su postgres -c "psql -c \"CREATE DATABASE ${DB_NAME} OWNER ${DB_USER};\""
fi
su postgres -c "psql -d ${DB_NAME} -c \"GRANT ALL ON SCHEMA public TO ${DB_USER};\""

# listen on all interfaces — ALTER SYSTEM writes postgresql.auto.conf reliably
# (no file-path guessing, no sed). Needs a full RESTART to take effect.
echo ">> ALTER SYSTEM listen_addresses = '*'..."
su postgres -c "psql -c \"ALTER SYSTEM SET listen_addresses = '*';\""

# allow the LAN in pg_hba (append once)
HBA="$(su postgres -c "psql -tAc 'SHOW hba_file'" | tr -d '[:space:]')"
HBA_LINE="host    ${DB_NAME}    ${DB_USER}    ${LAN_CIDR}    scram-sha-256"
echo ">> pg_hba (${HBA}): allow ${LAN_CIDR}..."
grep -qF "${LAN_CIDR}" "${HBA}" || echo "${HBA_LINE}" >> "${HBA}"

# FULL restart (listen_addresses is restart-only, not reload)
echo ">> full restart..."
rc-service postgresql stop || true
sleep 2
rc-service postgresql start
sleep 2

# verify (don't let set -e abort on the checks)
echo ">> verify:"
set +e
rc-service postgresql status
su postgres -c "psql -tAc 'SHOW listen_addresses'"
( netstat -tln 2>/dev/null || ss -tln 2>/dev/null ) | grep 5432 || echo "  (nothing listening on 5432!)"
nc -zv 127.0.0.1 5432
nc -zv 192.168.68.7 5432
set -e

cat <<EOF

============================================================
 Postgres ready for Vaultwarden
   host 192.168.68.7 · port 5432 · db ${DB_NAME} · user ${DB_USER}
   PASSWORD: ${DB_PASS}
 >>> SAVE THIS PASSWORD (goes in the Vaultwarden k8s Secret)
============================================================
EOF
