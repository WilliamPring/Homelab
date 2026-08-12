#!/bin/sh
# postgres-setup.sh — configure the Alpine Postgres LXC for Vaultwarden.
#
# Run as ROOT inside the Postgres LXC:   sh postgres-setup.sh
# Idempotent — safe to re-run (re-running just resets the password).
#
# It:
#   1. creates the 'vaultwarden' role + database (random 32-char password)
#   2. opens Postgres to the LAN (192.168.68.0/24) so k3s pods can connect
#   3. restarts Postgres and prints the connection details (SAVE THE PASSWORD)
set -eu

DB_NAME="vaultwarden"
DB_USER="vaultwarden"
LAN_CIDR="192.168.68.0/24"

# Strong ALPHANUMERIC password (no special chars → no shell/SQL quoting headaches).
DB_PASS="$(tr -dc 'A-Za-z0-9' < /dev/urandom | head -c 32)"

echo ">> Creating role '${DB_USER}'..."
if [ -z "$(su postgres -c "psql -tAc \"SELECT 1 FROM pg_roles WHERE rolname='${DB_USER}'\"")" ]; then
  su postgres -c "psql -c \"CREATE ROLE ${DB_USER} LOGIN PASSWORD '${DB_PASS}';\""
else
  su postgres -c "psql -c \"ALTER ROLE ${DB_USER} PASSWORD '${DB_PASS}';\""
fi

echo ">> Creating database '${DB_NAME}'..."
if [ -z "$(su postgres -c "psql -tAc \"SELECT 1 FROM pg_database WHERE datname='${DB_NAME}'\"")" ]; then
  su postgres -c "psql -c \"CREATE DATABASE ${DB_NAME} OWNER ${DB_USER};\""
fi
su postgres -c "psql -d ${DB_NAME} -c \"GRANT ALL ON SCHEMA public TO ${DB_USER};\""   # Postgres 15+

# Ask Postgres where its ACTIVE config files are (robust — no guessing paths).
CONF="$(su postgres -c "psql -tAc 'SHOW config_file'" | tr -d '[:space:]')"
HBA="$(su postgres -c "psql -tAc 'SHOW hba_file'" | tr -d '[:space:]')"
echo ">> config_file: ${CONF}"
echo ">> hba_file:    ${HBA}"

echo ">> Setting listen_addresses = '*'..."
if grep -qE "^#*listen_addresses" "${CONF}"; then
  sed -i "s/^#*listen_addresses.*/listen_addresses = '*'/" "${CONF}"
else
  echo "listen_addresses = '*'" >> "${CONF}"
fi

echo ">> Allowing LAN ${LAN_CIDR} in pg_hba.conf..."
HBA_LINE="host    ${DB_NAME}    ${DB_USER}    ${LAN_CIDR}    scram-sha-256"
grep -qF "${LAN_CIDR}" "${HBA}" || echo "${HBA_LINE}" >> "${HBA}"

echo ">> Restarting Postgres..."
rc-service postgresql restart

cat <<EOF

============================================================
 Postgres is ready for Vaultwarden
   host:     192.168.68.7
   port:     5432
   database: ${DB_NAME}
   user:     ${DB_USER}
   PASSWORD: ${DB_PASS}

 >>> SAVE THIS PASSWORD — it goes into the Vaultwarden k8s Secret (Phase 3).
============================================================
EOF
