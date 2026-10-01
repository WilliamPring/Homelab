#!/bin/sh
# postgres-romm-setup.sh — add the RomM database + role to the existing Alpine Postgres LXC
# (the one Vaultwarden already uses, 192.168.68.7). Companion to postgres-setup.sh.
# Run as ROOT inside the Postgres LXC:   sh postgres-romm-setup.sh
# Idempotent — safe to re-run (re-running RESETS the password → update romm-secret.enc.yaml).
set -eu

DB_NAME="romm"
DB_USER="romm"
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

# pg_hba: one line for this db/user from the LAN (listen_addresses is already '*' from
# postgres-setup.sh; the existing vaultwarden line only covers the vaultwarden db/user).
HBA="$(su postgres -c "psql -tAc 'SHOW hba_file'" | tr -d '[:space:]')"
HBA_LINE="host    ${DB_NAME}    ${DB_USER}    ${LAN_CIDR}    scram-sha-256"
echo ">> pg_hba (${HBA}): allow ${DB_USER}@${LAN_CIDR}..."
grep -qF "${HBA_LINE}" "${HBA}" || echo "${HBA_LINE}" >> "${HBA}"

# pg_hba changes only need a reload
echo ">> reload..."
su postgres -c "psql -c 'SELECT pg_reload_conf();'" >/dev/null

echo ">> verify:"
set +e
su postgres -c "psql -tAc \"SELECT datname FROM pg_database WHERE datname='${DB_NAME}'\""
nc -zv 192.168.68.7 5432
set -e

cat <<EOF

============================================================
 Postgres ready for RomM
   host 192.168.68.7 · port 5432 · db ${DB_NAME} · user ${DB_USER}
   PASSWORD: ${DB_PASS}
 >>> put this in gitops/romm/romm-secret.enc.yaml as DB_PASSWD, then sops --encrypt
============================================================
EOF
