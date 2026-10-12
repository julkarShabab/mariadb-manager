#!/usr/bin/env bash
# =====================================================================
# mariadb-manager.sh  (dynamic version)
# Backup, restore, delete, drop, list, live-database view, auto-cleanup
# Dumps are stored as gzip (.sql.gz)
# =====================================================================

set -o pipefail   # a pipeline fails if ANY command in it fails (important for dump | gzip)

# ---------------------- CONFIG (all overridable) ----------------------
# Order of priority: command-line flag > environment variable > default below
BACKUP_DIR="${BACKUP_DIR:-/var/backups/mariadb}"        # where dumps are stored
RETENTION_DAYS="${RETENTION_DAYS:-7}"                   # dumps older than this are deleted
LOG_FILE="${LOG_FILE:-/var/log/mariadb-manager.log}"    # action log
CREDS_FILE="${CREDS_FILE:-}"                            # empty = auto-detect
YES=0                                                   # 1 = skip confirmations (for cron)

# ---------------------- GLOBAL FLAG PARSING ---------------------------
# Flags must come BEFORE the command, e.g.: ./mariadb-manager.sh --days 14 backup mydb
while [ $# -gt 0 ]; do
    case "$1" in
        --dir)   BACKUP_DIR="$2";     shift 2 ;;   # change backup folder
        --days)  RETENTION_DAYS="$2"; shift 2 ;;   # change retention days
        --creds) CREDS_FILE="$2";     shift 2 ;;   # change credentials file
        -y|--yes) YES=1;              shift ;;     # no confirmation prompts
        *) break ;;                                # first non-flag = the command
    esac
done

# Retention must be a plain number, otherwise find -mtime would misbehave
[[ "$RETENTION_DAYS" =~ ^[0-9]+$ ]] || { echo "ERROR: --days must be a number"; exit 1; }

# ---------------------- TOOL + CREDENTIAL DETECTION -------------------
# MariaDB 11.x ships mariadb-dump / mariadb; older versions only mysqldump / mysql
if command -v mariadb-dump >/dev/null 2>&1; then
    DUMP_BIN="mariadb-dump"; CLIENT_BIN="mariadb"
else
    DUMP_BIN="mysqldump";    CLIENT_BIN="mysql"
fi

# Auto-detect the credentials file if none was given
if [ -z "$CREDS_FILE" ]; then
    sudo_home=""
    [ -n "$SUDO_USER" ] && sudo_home=$(getent passwd "$SUDO_USER" | cut -d: -f6)   # home of the user who ran sudo
    for c in "$HOME/.my.cnf" "$sudo_home/.my.cnf" "/root/.my.cnf"; do
        [ -f "$c" ] && { CREDS_FILE="$c"; break; }
    done
fi

# --defaults-extra-file must be the FIRST option of the client; empty array = no creds file
AUTH=()
[ -n "$CREDS_FILE" ] && [ -f "$CREDS_FILE" ] && AUTH=(--defaults-extra-file="$CREDS_FILE")

# ---------------------------- HELPERS ---------------------------------
log() {
    # Timestamped message to screen and to the log file
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*" | tee -a "$LOG_FILE"
}

confirm() {
    # y/N question; auto-yes when --yes was given
    [ "$YES" -eq 1 ] && return 0
    read -r -p "$1 [y/N]: " ans
    [[ "$ans" =~ ^[Yy]$ ]]
}

valid_name() {
    # Only letters, digits, underscore, dollar, dash: protects the SQL from bad names
    [[ "$1" =~ ^[A-Za-z0-9_\$-]+$ ]]
}

setup() {
    # Create backup folder (private) and make sure the log file is writable
    mkdir -p "$BACKUP_DIR" || { echo "Cannot create $BACKUP_DIR (try sudo or --dir)"; exit 1; }
    chmod 700 "$BACKUP_DIR"
    touch "$LOG_FILE" 2>/dev/null || LOG_FILE="$HOME/mariadb-manager.log"
}

pick_db() {
    # Numbered menu of live databases (system ones hidden). Result goes in PICKED.
    # $1 = "all" adds an extra option 0 = all databases
    mapfile -t DBLIST < <("$CLIENT_BIN" "${AUTH[@]}" -N -e "SHOW DATABASES;" 2>/dev/null \
        | grep -Ev '^(information_schema|performance_schema|mysql|sys)$')
    [ ${#DBLIST[@]} -gt 0 ] || { log "ERROR: no databases found or cannot connect"; exit 1; }
    [ "$1" = "all" ] && echo "  0) ALL databases"
    local i=1
    for d in "${DBLIST[@]}"; do printf '%3d) %s\n' "$i" "$d"; i=$((i+1)); done
    read -r -p "Pick number: " n
    if [ "$1" = "all" ] && [ "$n" = "0" ]; then PICKED="--all"; return; fi
    [[ "$n" =~ ^[0-9]+$ ]] && [ "$n" -ge 1 ] && [ "$n" -le ${#DBLIST[@]} ] || { echo "Invalid choice"; exit 1; }
    PICKED="${DBLIST[$((n-1))]}"
}

pick_dump() {
    # Numbered menu of dump files, newest first. Result goes in PICKED (full path).
    # $1 = optional name prefix filter, e.g. "mydb"
    local pat="${1:-}*.sql.gz"
    mapfile -t DUMPS < <(find "$BACKUP_DIR" -maxdepth 1 -type f -name "$pat" -printf '%T@ %p\n' \
        | sort -rn | cut -d' ' -f2-)   # %T@ = mtime in seconds; sort newest first; cut removes the number
    [ ${#DUMPS[@]} -gt 0 ] || { log "No dumps found in $BACKUP_DIR"; exit 1; }
    local i=1
    for f in "${DUMPS[@]}"; do
        printf '%3d) %-50s %s\n' "$i" "$(basename "$f")" "$(du -h "$f" | cut -f1)"
        i=$((i+1))
    done
    read -r -p "Pick number: " n
    [[ "$n" =~ ^[0-9]+$ ]] && [ "$n" -ge 1 ] && [ "$n" -le ${#DUMPS[@]} ] || { echo "Invalid choice"; exit 1; }
    PICKED="${DUMPS[$((n-1))]}"
}

resolve_file() {
    # Accept a full path, a path relative to here, or just a file name inside BACKUP_DIR
    local f="$1"
    [ -f "$f" ] && { realpath "$f"; return; }
    [ -f "$BACKUP_DIR/$f" ] && { echo "$BACKUP_DIR/$f"; return; }
    return 1
}

usage() {
cat <<EOF
Usage: $0 [flags] <command> [args]

Flags (put BEFORE the command):
  --dir <path>     backup folder        (now: $BACKUP_DIR)
  --days <n>       retention in days    (now: $RETENTION_DAYS)
  --creds <file>   MariaDB login file   (now: ${CREDS_FILE:-none found})
  -y, --yes        skip confirmations (for cron)

Commands (arguments are optional - missing ones open a numbered menu):
  backup  [db | --all]          Dump one database or all into .sql.gz
  restore [file.sql.gz] [db]    Restore a dump into any database name
  delete  [file.sql.gz]         Delete one dump
  delete  --db <db>             Delete ALL dumps of one database
  drop    [db]                  DROP a live database (dangerous)
  cleanup                       Delete dumps older than $RETENTION_DAYS days
  list                          Show stored dumps
  dbs     [db]                  Show live databases (with size) or tables of one DB
EOF
}

# ---------------------------- BACKUP ----------------------------------
do_backup() {
    local target="$1"
    [ -z "$target" ] && { pick_db all; target="$PICKED"; }   # no argument -> menu

    local stamp; stamp=$(date '+%Y-%m-%d_%H-%M-%S')
    local out dump_args

    if [ "$target" = "--all" ]; then
        out="$BACKUP_DIR/all-databases_${stamp}.sql.gz"
        dump_args=(--all-databases)
    else
        valid_name "$target" || { log "ERROR: invalid database name '$target'"; exit 1; }
        # Check the database really exists before dumping
        if ! "$CLIENT_BIN" "${AUTH[@]}" -e "USE \`$target\`;" 2>/dev/null; then
            log "ERROR: database '$target' not found or access denied"; exit 1
        fi
        out="$BACKUP_DIR/${target}_${stamp}.sql.gz"
        dump_args=("$target")   # NO --databases: the dump has no USE line, so it can be restored under any name
    fi

    log "Backup started -> $out"

    # --single-transaction : consistent snapshot without locking InnoDB tables
    # --routines/--triggers/--events : include procedures, triggers, scheduled events
    # gzip -9 : maximum compression
    if "$DUMP_BIN" "${AUTH[@]}" --single-transaction --routines --triggers --events \
         "${dump_args[@]}" | gzip -9 > "$out"; then
        if gzip -t "$out" 2>/dev/null; then       # integrity test of the archive
            log "Backup OK ($(du -h "$out" | cut -f1)): $out"
        else
            log "ERROR: archive is corrupt, removing $out"; rm -f "$out"; exit 1
        fi
    else
        log "ERROR: dump failed, removing partial file"; rm -f "$out"; exit 1
    fi

    do_cleanup   # remove old dumps after every successful backup
}

# ---------------------------- RESTORE ---------------------------------
do_restore() {
    local file="$1" db="$2"

    if [ -z "$file" ]; then pick_dump; file="$PICKED"
    else file=$(resolve_file "$file") || { log "ERROR: file not found: $1"; exit 1; }
    fi
    gzip -t "$file" 2>/dev/null || { log "ERROR: $file is not a valid gzip file"; exit 1; }

    local base; base=$(basename "$file" .sql.gz)

    # ---- full restore of an all-databases dump (it contains its own CREATE/USE lines) ----
    if [[ "$base" == all-databases_* ]]; then
        confirm "Restore ALL databases from $base? Existing data may be overwritten." || { echo "Cancelled."; exit 0; }
        log "Restore (all) started: $file"
        if gunzip -c "$file" | "$CLIENT_BIN" "${AUTH[@]}"; then log "Restore OK (all databases)"
        else log "ERROR: restore failed"; exit 1; fi
        return
    fi

    # ---- single database restore into any name ----
    if [ -z "$db" ]; then
        local def="${base%_*_*}"   # strip the _DATE_TIME part -> original database name
        read -r -p "Target database name [$def]: " db
        db="${db:-$def}"
    fi
    valid_name "$db" || { log "ERROR: invalid database name '$db'"; exit 1; }

    confirm "This will load $(basename "$file") into '$db' (overwrites same-named tables). Continue?" || { echo "Cancelled."; exit 0; }
    log "Restore started: $file -> $db"

    "$CLIENT_BIN" "${AUTH[@]}" -e "CREATE DATABASE IF NOT EXISTS \`$db\`;" || exit 1

    # sed removes any CREATE DATABASE / USE line (present in old dumps made with --databases),
    # so everything lands in <db> no matter what name the dump originally had
    if gunzip -c "$file" | sed -E '/^(CREATE DATABASE|USE )/d' | "$CLIENT_BIN" "${AUTH[@]}" "$db"; then
        log "Restore OK: $db"
    else
        log "ERROR: restore failed"; exit 1
    fi
}

# ---------------------------- DELETE ----------------------------------
do_delete() {
    if [ "$1" = "--db" ]; then
        local db="$2"
        [ -z "$db" ] && { pick_db; db="$PICKED"; }
        valid_name "$db" || { log "ERROR: invalid database name"; exit 1; }
        mapfile -t files < <(find "$BACKUP_DIR" -maxdepth 1 -type f -name "${db}_*.sql.gz")
        [ ${#files[@]} -gt 0 ] || { log "No dumps found for '$db'"; exit 0; }
        printf '%s\n' "${files[@]}"
        confirm "Delete these ${#files[@]} file(s)?" || { echo "Cancelled."; exit 0; }
        rm -f -- "${files[@]}" && log "Deleted ${#files[@]} dump(s) of '$db'"
    else
        local f
        if [ -z "$1" ]; then pick_dump; f="$PICKED"
        else f=$(resolve_file "$1") || { log "ERROR: file not found: $1"; exit 1; }
        fi
        # Safety: only files inside BACKUP_DIR may be deleted
        [[ "$(realpath "$f")" == "$(realpath "$BACKUP_DIR")"/* ]] || { echo "Refusing: file is outside $BACKUP_DIR"; exit 1; }
        confirm "Delete $f ?" || { echo "Cancelled."; exit 0; }
        rm -f -- "$f" && log "Deleted: $f"
    fi
}

do_drop() {
    local db="$1"
    [ -z "$db" ] && { pick_db; db="$PICKED"; }
    case "$db" in
        mysql|information_schema|performance_schema|sys|"")
            echo "Refusing to drop system/empty database '$db'"; exit 1 ;;
    esac
    valid_name "$db" || { log "ERROR: invalid database name"; exit 1; }
    confirm "DROP DATABASE '$db' permanently? Make sure you have a backup!" || { echo "Cancelled."; exit 0; }
    "$CLIENT_BIN" "${AUTH[@]}" -e "DROP DATABASE \`$db\`;" && log "Dropped database: $db"
}

# ---------------------------- CLEANUP ---------------------------------
do_cleanup() {
    # -mtime +N = modified MORE than N full days ago
    local old
    old=$(find "$BACKUP_DIR" -maxdepth 1 -type f -name "*.sql.gz" -mtime +"$RETENTION_DAYS")
    if [ -z "$old" ]; then
        log "Cleanup: nothing older than $RETENTION_DAYS days"
    else
        echo "$old" | while read -r f; do log "Cleanup: removing old dump $f"; done
        find "$BACKUP_DIR" -maxdepth 1 -type f -name "*.sql.gz" -mtime +"$RETENTION_DAYS" -delete
    fi
}

# ------------------------------ LIST ----------------------------------
do_list() {
    echo "Dumps in $BACKUP_DIR (retention: $RETENTION_DAYS days):"
    ls -lht "$BACKUP_DIR"/*.sql.gz 2>/dev/null || echo "(none)"
}

# ------------------------- LIVE DATABASES -----------------------------
do_dbs() {
    local db="$1"
    if [ -z "$db" ]; then
        # All live databases with their size in MB (databases with no tables show 0)
        "$CLIENT_BIN" "${AUTH[@]}" -e "
            SELECT s.schema_name AS db,
                   COUNT(t.table_name) AS tables,
                   ROUND(COALESCE(SUM(t.data_length + t.index_length),0)/1024/1024, 2) AS size_mb
            FROM information_schema.schemata s
            LEFT JOIN information_schema.tables t ON t.table_schema = s.schema_name
            GROUP BY s.schema_name
            ORDER BY s.schema_name;"
    else
        valid_name "$db" || { echo "Invalid database name"; exit 1; }
        # Tables of one database with estimated rows and size
        "$CLIENT_BIN" "${AUTH[@]}" -e "
            SELECT table_name AS tbl,
                   table_rows AS approx_rows,
                   ROUND((data_length + index_length)/1024/1024, 2) AS size_mb
            FROM information_schema.tables
            WHERE table_schema = '$db'
            ORDER BY table_name;"
    fi
}

# ------------------------------ MAIN ----------------------------------
setup
case "$1" in
    backup)  do_backup  "$2" ;;
    restore) do_restore "$2" "$3" ;;
    delete)  do_delete  "$2" "$3" ;;
    drop)    do_drop    "$2" ;;
    cleanup) do_cleanup ;;
    list)    do_list ;;
    dbs)     do_dbs     "$2" ;;
    *)       usage ;;
esac
