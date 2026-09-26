#!/bin/bash
PRINT_RED='\033[0;31m'
PRINT_RESET='\033[0m'

source ./scripts/util/generate_password.sh

# Edition. install.sh exports these from its flags:
#   DB_EDITION   free (default) | ee
#   APEX_PDBS    EE only. Comma-separated PDB:POOL list. The first entry is the
#                PDB that DBCA creates and the ORDS "default" pool (/ords/).
#                Example: DEVPDB:default,TESTPDB:test
#   INIT_SGA_SIZE / INIT_PGA_SIZE   EE only, in MB
#   DB_IMAGE     EE only, the locally built image tag
DB_EDITION="${DB_EDITION:-free}"

if [ "$DB_EDITION" != "free" ] && [ "$DB_EDITION" != "ee" ]; then
  echo -e "${PRINT_RED}ERROR: DB_EDITION must be 'free' or 'ee', not '$DB_EDITION'${PRINT_RESET}" >&2
  exit 1
fi

if [ "$DB_EDITION" = "ee" ]; then
  APEX_PDBS="${APEX_PDBS:-DEVPDB:default,TESTPDB:test}"
  APEX_PDBS="${APEX_PDBS^^}"
  # Pool names are lower case in ORDS URLs. Keep PDB names upper case.
  APEX_PDBS=$(echo "$APEX_PDBS" | awk -F, '{
    for (i = 1; i <= NF; i++) {
      split($i, p, ":")
      out = out (i > 1 ? "," : "") p[1] ":" tolower(p[2])
    }
    print out
  }')
  FIRST_ENTRY="${APEX_PDBS%%,*}"
  FIRST_PDB="${FIRST_ENTRY%%:*}"
  FIRST_POOL="${FIRST_ENTRY#*:}"
  if [ "$FIRST_POOL" != "default" ]; then
    echo -e "${PRINT_RED}ERROR: the first APEX_PDBS entry must use the pool 'default' (got '$FIRST_ENTRY')${PRINT_RESET}" >&2
    exit 1
  fi
  DB_SERVICE="$FIRST_PDB"
  CONN_NAME="local-26ai-${FIRST_PDB,,}-sys"
else
  DB_SERVICE="FREEPDB1"
  CONN_NAME="local-26ai-sys"
fi

# generate sys password
SYS_PASSWORD=$(generate_password)

# if .env exsits, rename to .env.bak
if [ -f .env ]; then
  mv .env .env.bak
fi

# write .env file with passwords
echo "ORACLE_PASSWORD=\"$SYS_PASSWORD\"" >.env
echo "ORACLE_PWD=\"$SYS_PASSWORD\"" >>.env
#echo "APP_USER=\"$APP_USER\"" >>.env
#echo "APP_USER_PASSWORD=\"$APP_USER_PASSWORD\"" >>.env
echo "DB_CONN_BASE=local-26ai" >>.env
echo "DB_CONN_NAME=$CONN_NAME" >>.env
echo "CONTAINER_NAME=local-26ai" >>.env
echo "DBSERVICENAME=\"$DB_SERVICE\"" >>.env
echo "DBHOST=\"26ai\"" >>.env
echo "DBPORT=\"1521\"" >>.env
# SECURE_MODE is this project's own hardening flag (see install.sh --secure).
# Deliberately NOT named FORCE_SECURE: the Oracle ORDS image reads FORCE_SECURE
# from this shared env_file and would refuse to boot without TLS certs.
echo "SECURE_MODE=\"false\"" >>.env
# ORDS debug-to-screen (maps to the container's DEBUG env in docker-compose.yml).
# Default on for dev; install.sh --secure flips it to false. NOT named ORDS_DEBUG:
# that is a reserved variable inside the ORDS image's `ords` launcher (it holds
# JVM -agentlib:jdwp options) and setting it here breaks the ORDS install.
echo "DEBUG_TO_SCREEN=\"true\"" >>.env
echo "DB_EDITION=\"$DB_EDITION\"" >>.env

if [ "$DB_EDITION" = "ee" ]; then
  # Values must not contain spaces: load_env.sh exports .env through xargs.
  {
    echo "# --- Enterprise Edition --------------------------------------------------"
    echo "COMPOSE_FILE=\"docker-compose.yml:docker-compose.ee.yml\""
    echo "DB_IMAGE=\"${DB_IMAGE:-oracle/database:23.26.0-ee}\""
    echo "ORACLE_SID=\"ORCLCDB\""
    echo "ORACLE_PDB=\"$FIRST_PDB\""
    echo "APEX_PDBS=\"$APEX_PDBS\""
    echo "INIT_SGA_SIZE=\"${INIT_SGA_SIZE:-4096}\""
    echo "INIT_PGA_SIZE=\"${INIT_PGA_SIZE:-1024}\""
    echo "ENABLE_ARCHIVELOG=\"true\""
    echo "RESTART_POLICY=\"unless-stopped\""
    echo "DB_READY_TIMEOUT_MIN=\"90\""
    echo "# EE has no 12 GB limit: no per-schema or APEX tablespace ceiling"
    echo "USER_TBS_MAXSIZE=\"UNLIMITED\""
    echo "APEX_TBS_MAXSIZE=\"UNLIMITED\""
    echo "# EE has no 12 GB limit: used-space and stop never warn"
    echo "SPACE_WARN_GB=\"100000\""
    echo "SPACE_CRIT_GB=\"100000\""
  } >>.env
fi

chmod 600 .env
[ -f .env.bak ] && chmod 600 .env.bak

echo "Created .env file ($DB_EDITION)"

# create bind-mount dirs if not exists. chmod 777 so the ORDS container's mapped
# user can write them under rootless podman.
if [ ! -d ./ords-config ]; then
  mkdir ./ords-config
  chmod 777 ./ords-config
fi
if [ ! -d ./apex-images ]; then
  mkdir ./apex-images
  chmod 777 ./apex-images
fi

mkdir -p ./backups/export
mkdir -p ./backups/import
