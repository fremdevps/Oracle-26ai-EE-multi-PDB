#!/usr/bin/env bash
# desc: (EE) Create a PDB with APEX and its own ORDS pool: create-pdb <PDB> <POOL>

set -euo pipefail

# Enterprise Edition only. Adds one PDB to the CDB and makes it a complete APEX
# environment, served by ORDS under /ords/<POOL>/:
#
#   1. create pluggable database <PDB> (OMF, open, save state)
#   2. APEX + the project defaults in that PDB (after-first-db-start.sh)
#   3. ORDS schema + ORDS pool <POOL> for that PDB
#   4. register <PDB>:<POOL> in APEX_PDBS in .env
#
# Every step checks first and skips work that is done, so a re-run is safe.
#
# Usage: create-pdb.sh <PDB> <POOL> [--no-restart]
#   <PDB>   PDB name, for example TESTPDB
#   <POOL>  ORDS pool and URL segment, for example test -> /ords/test/
#   --no-restart  do not restart ORDS at the end (install.sh restarts it once)

usage() {
  sed -n '16,19p' "$0" | sed 's/^# \{0,1\}//'
  exit 1
}

PDB="${1:-}"
POOL="${2:-}"
RESTART_ORDS=true
[ "${3:-}" = "--no-restart" ] && RESTART_ORDS=false
if [ -z "$PDB" ] || [ -z "$POOL" ] || [ "$PDB" = "-h" ] || [ "$PDB" = "--help" ]; then
  usage
fi

PDB="${PDB^^}"
POOL="${POOL,,}"

if ! [[ "$PDB" =~ ^[A-Z][A-Z0-9_]{0,29}$ ]]; then
  echo "ERROR: invalid PDB name '$PDB' (letters, digits and _, starting with a letter)" >&2
  exit 1
fi
if ! [[ "$POOL" =~ ^[a-z][a-z0-9_-]{0,29}$ ]]; then
  echo "ERROR: invalid pool name '$POOL' (lower-case letters, digits, _ and -)" >&2
  exit 1
fi
if [ "$POOL" = "default" ]; then
  echo "ERROR: the pool 'default' belongs to the first PDB. Pick another pool name." >&2
  exit 1
fi

# Work on the new PDB in every script this one calls.
export TARGET_PDB="$PDB"
source ./scripts/util/load_env.sh

if [ "${DB_EDITION:-free}" != "ee" ]; then
  echo "ERROR: create-pdb needs DB_EDITION=ee. Oracle AI Database Free has one fixed PDB." >&2
  exit 1
fi

ORDS_CONTAINER="${CONTAINER_NAME}-ords"
ROOT_CONN="sys/${ORACLE_PASSWORD}@localhost:${DBPORT}/${ORACLE_SID}"
PDB_CONN="sys/${ORACLE_PASSWORD}@localhost:${DBPORT}/${PDB}"

# Pool names must be unique across PDBs.
IFS=',' read -r -a entries <<<"${APEX_PDBS:-}"
for entry in "${entries[@]}"; do
  if [ "${entry#*:}" = "$POOL" ] && [ "${entry%%:*}" != "$PDB" ]; then
    echo "ERROR: the pool '$POOL' is used by ${entry%%:*} already" >&2
    exit 1
  fi
done

sql_value() {
  # sql_value CONNECT_STRING QUERY -> first number of the result
  sql -S "$1" as SYSDBA <<SQL 2>/dev/null | grep -oE '[0-9]+' | head -1 || true
set heading off feedback off pagesize 0
$2
exit
SQL
}

# ---------------------------------------------------------------------------
echo "=== 1/4 PDB $PDB ==="
exists=$(sql_value "$ROOT_CONN" "select count(*) from dba_pdbs where pdb_name = '${PDB}';")
if [ "${exists:-0}" -gt 0 ]; then
  echo "PDB $PDB exists already."
else
  sql -S "$ROOT_CONN" as SYSDBA <<SQL
whenever sqlerror exit failure
create pluggable database ${PDB} admin user pdbadmin identified by "${ORACLE_PASSWORD}";
alter pluggable database ${PDB} open;
alter pluggable database ${PDB} save state;
exit
SQL
  echo "Created PDB $PDB."
fi

# ---------------------------------------------------------------------------
echo "=== 2/4 APEX in $PDB ==="
apex_installed=$(sql_value "$PDB_CONN" "select count(*) from dba_users where regexp_like(username, '^APEX_[0-9]+\$');")
if [ "${apex_installed:-0}" -gt 0 ]; then
  echo "APEX is installed in $PDB already."
else
  # Same APEX version as the other PDBs: they share the /i/ images folder.
  APEX_REUSE_DOWNLOAD=true ./scripts/after-first-db-start.sh </dev/null
fi

# ---------------------------------------------------------------------------
echo "=== 3/4 ORDS pool '$POOL' ==="
if $CONTAINER_CLI exec "$ORDS_CONTAINER" test -f "/etc/ords/config/databases/${POOL}/pool.xml"; then
  echo "ORDS pool '$POOL' exists already."
else
  if [ "${SECURE_MODE:-false}" = "true" ]; then
    DB_API=false
  else
    DB_API=true
  fi
  # Line 1: SYS password (installs the ORDS schema into the PDB).
  # Line 2: password for ORDS_PUBLIC_USER in that PDB.
  printf '%s\n%s\n' "$ORACLE_PASSWORD" "$ORACLE_PASSWORD" |
    $CONTAINER_CLI exec -i "$ORDS_CONTAINER" bash -c "
      ords --config /etc/ords/config install \
        --log-folder /tmp \
        --db-pool '${POOL}' \
        --admin-user SYS \
        --db-hostname '${DBHOST}' \
        --db-port '${DBPORT}' \
        --db-servicename '${PDB}' \
        --feature-db-api ${DB_API} \
        --feature-rest-enabled-sql ${DB_API} \
        --feature-sdw ${DB_API} \
        --gateway-mode proxied \
        --gateway-user APEX_PUBLIC_USER \
        --proxy-user \
        --password-stdin"
  echo "Created ORDS pool '$POOL'."
fi

# ---------------------------------------------------------------------------
echo "=== 4/4 Register $PDB:$POOL in .env ==="
already=false
for entry in "${entries[@]}"; do
  [ "${entry%%:*}" = "$PDB" ] && already=true
done
if [ "$already" = true ]; then
  echo "APEX_PDBS has $PDB already."
else
  new_list="${APEX_PDBS:+${APEX_PDBS},}${PDB}:${POOL}"
  tmp_env=$(mktemp)
  if grep -qE '^APEX_PDBS=' .env; then
    sed "s/^APEX_PDBS=.*/APEX_PDBS=\"${new_list}\"/" .env >"$tmp_env"
  else
    cat .env >"$tmp_env"
    echo "APEX_PDBS=\"${new_list}\"" >>"$tmp_env"
  fi
  cat "$tmp_env" >.env
  rm -f "$tmp_env"
  echo "APEX_PDBS=\"${new_list}\""
fi

if [ "$RESTART_ORDS" = true ]; then
  echo "Restarting ORDS"
  $DOCKER_COMPOSE restart ords-26ai
fi

cat <<EOF

PDB $PDB is ready.
  APEX:  http://localhost:8181/ords/${POOL}/
  SYS:   sql -name "${DB_CONN_NAME}"
  Other commands on this PDB:  ./local-26ai.sh --pdb ${PDB} <command>
EOF
