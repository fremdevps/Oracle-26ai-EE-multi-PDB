#!/usr/bin/env bash
# desc: Disable archive logging to save disk space

# special thanks to philipp salvisberg (https://github.com/United-Codes/uc-local-apex-dev/issues/5)

set -e

source ./scripts/util/load_env.sh

echo "Disabling archive logs"
$CONTAINER_CLI exec "$CONTAINER_NAME" bash -c "sqlplus -S / as sysdba <<EOF
shutdown immediate;
startup mount;
alter database noarchivelog;
alter database open;
archive log list;
exit;
EOF"

echo "Removing archive logs"
# ORACLE_HOME is escaped so it expands inside the container: dbhomeFree on Free, dbhome_1 on EE.
$CONTAINER_CLI exec "$CONTAINER_NAME" bash -c "cd \$ORACLE_HOME/dbs && rm -f arch1*.dbf"
