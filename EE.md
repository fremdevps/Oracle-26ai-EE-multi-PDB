# Enterprise Edition

Este fork agrega **Oracle AI Database 26ai Enterprise Edition** al proyecto
`uc-local-apex-dev`. Con `DB_EDITION=ee` el stack usa un CDB de EE con uno o
varios PDBs, y cada PDB es un APEX completo con su propio pool de ORDS.

El modo Free original sigue funcionando igual: si no se pasa `--edition ee`,
nada cambia.

## Arquitectura

| VM | CDB | PDBs | URL |
|---|---|---|---|
| DEV/TEST | `ORCLCDB` | `DEVPDB` (pool `default`), `TESTPDB` (pool `test`) | `/ords/` y `/ords/test/` |
| PROD | `ORCLCDB` | `PRODPDB` (pool `default`) | `/ords/` |

- Un solo contenedor de base de datos y un solo contenedor de ORDS por VM.
- APEX se instala en cada PDB. Todos los PDBs usan la misma versión de APEX,
  porque comparten la carpeta de imágenes `/i/`.
- Las conexiones SQLcl llevan el PDB en el nombre: `local-26ai-devpdb-sys`,
  `local-26ai-testpdb-sys`, `local-26ai-testpdb-<usuario>`.

## 1. Construir la imagen EE

Oracle no publica una imagen 26ai EE, así que se construye con los scripts
oficiales de `github.com/oracle/docker-images`.

1. Descargar **Oracle AI Database 26ai for Linux x86-64 ZIP** desde
   <https://www.oracle.com/database/technologies/oracle-database-software-downloads.html>
   (requiere cuenta Oracle). No descomprimirlo.
2. Copiarlo a `./ee-install/` en la VM, por ejemplo:
   `scp LINUX.X64_*_db_home.zip usuario@vm:~/uc-local-apex-dev/ee-install/`
3. Construir (unos 20-40 minutos, necesita ~25 GB libres):

```bash
./local-26ai.sh build-ee-image
```

La imagen queda como `oracle/database:23.26.0-ee`. Se construye una vez por VM
(o se exporta con `docker save` / `docker load` para no repetir el build).

## 2. Instalar

**VM DEV/TEST:**

```bash
./install.sh --edition ee --pdbs DEVPDB:default,TESTPDB:test --sga 6144 --pga 2048
```

**VM PROD:**

```bash
./install.sh --edition ee --pdbs PRODPDB:default --sga 8192 --pga 2048 --secure
```

La primera vez DBCA crea la base: tarda entre 20 y 60 minutos (el límite de
espera es `DB_READY_TIMEOUT_MIN="90"` en `.env`). Si algo falla, volver a
correr `./install.sh`: retoma donde quedó.

Los flags de edición solo se usan cuando `.env` no existe todavía. Después, la
configuración vive en `.env`.

## 3. Trabajar con un PDB

Todos los comandos aceptan `--pdb`. Sin `--pdb` se usa el primer PDB.

```bash
./local-26ai.sh --pdb TESTPDB create-user MIAPP
./local-26ai.sh --pdb TESTPDB backup-user MIAPP
./local-26ai.sh --pdb DEVPDB used-space
sql -name local-26ai-testpdb-sys
```

Agregar otro PDB más adelante (crea el PDB, instala APEX y el pool de ORDS):

```bash
./local-26ai.sh create-pdb UATPDB uat     # -> http://localhost:8181/ords/uat/
```

## Qué cambia con `DB_EDITION=ee`

| Tema | Free (original) | EE (este fork) |
|---|---|---|
| Imagen | `container-registry.oracle.com/database/free` | local, `DB_IMAGE` |
| Compose | `docker-compose.yml` | + `docker-compose.ee.yml` (vía `COMPOSE_FILE` en `.env`) |
| Límite de 12 GB | techos por tablespace | sin techos (`UNLIMITED`) |
| `cap-tablespaces` | disponible | bloqueado |
| `compress-space` | disponible | **bloqueado**: Advanced Compression es una opción con licencia aparte en EE |
| `repair-ru-dictionary` | disponible | bloqueado (EE se parchea con OPatch/datapatch) |
| Archive logs | se desactivan en la instalación | activos (`ENABLE_ARCHIVELOG="true"`), nunca se tocan |
| Reinicio | `no` | `unless-stopped` |
| `.env` | permisos por defecto | `600` |

## Variables nuevas en `.env`

| Clave | Uso |
|---|---|
| `DB_EDITION` | `free` o `ee` |
| `COMPOSE_FILE` | activa `docker-compose.ee.yml` |
| `DB_IMAGE` | tag de la imagen EE |
| `ORACLE_SID` | CDB, `ORCLCDB` |
| `ORACLE_PDB` | primer PDB (lo crea DBCA) |
| `APEX_PDBS` | lista `PDB:POOL` separada por comas, sin espacios |
| `INIT_SGA_SIZE` / `INIT_PGA_SIZE` | memoria en MB, solo al crear la base |
| `ENABLE_ARCHIVELOG` | modo archivelog al crear la base |
| `DB_READY_TIMEOUT_MIN` | espera del primer arranque |
| `USER_TBS_MAXSIZE` / `APEX_TBS_MAXSIZE` | techo de tablespaces (`UNLIMITED` en EE) |

## Pendiente (próximas fases)

- Red: publicar `1521`, `8181` y `8443` solo en `127.0.0.1` y exponer HTTPS con
  un proxy inverso.
- Backups RMAN automáticos (archivelog ya está activo) y copia fuera de la VM.
- Protección de scripts destructivos cuando el ambiente es PROD.
