#!/usr/bin/env bash
# desc: (EE) Move datafiles out of $ORACLE_HOME/dbs into the oradata volume (OMF), in every PDB

set -euo pipefail

# Older versions of this fork created AUDIT_TRAIL and TBS_APEX with fixed file
# names. On Enterprise Edition those files ended up in $ORACLE_HOME/dbs, which
# is inside the container layer and is lost when the container is recreated.
# This moves them ONLINE (no downtime) to Oracle Managed Files under
# /opt/oracle/oradata. Safe to re-run: it only touches files still in /dbs/.

source ./scripts/util/load_env.sh

if [ "${DB_EDITION:-free}" != "ee" ]; then
  echo "move-datafiles-omf is only for DB_EDITION=ee" >&2
  exit 1
fi

IFS=',' read -r -a entries <<<"${APEX_PDBS:-}"
for entry in "${entries[@]}"; do
  pdb="${entry%%:*}"
  echo "=== ${pdb} ==="
  sql -S "sys/${ORACLE_PASSWORD}@localhost:${DBPORT}/${pdb}" as SYSDBA <<'SQL'
set serveroutput on size unlimited feedback off
begin
  for r in (select file_name from dba_data_files
             where file_name like '%/dbs/%'
             order by file_name)
  loop
    execute immediate 'alter database move datafile ''' || r.file_name || '''';
    dbms_output.put_line('moved ' || r.file_name);
  end loop;
end;
/
select tablespace_name, file_name from dba_data_files
 where tablespace_name in ('AUDIT_TRAIL', 'TBS_APEX')
 order by 1;
exit
SQL
done
