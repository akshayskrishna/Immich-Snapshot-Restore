#!/usr/bin/env bash
set -Eeuo pipefail
IFS=$'\n\t'

SCRIPT_PATH="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)/$(basename -- "${BASH_SOURCE[0]}")"
BASH_BIN="$(command -v bash || true)"

AUTO_YES=false
IMMICH_DIR=""
BACKUP_ROOT=""
BACKUP_DIR=""
COMPOSE_FILE=""
MANIFEST_FILE=""
DB_SERVICE=""
MEDIA_ROOT=""
EXTERNAL_LIBRARY=""
STACK_STOPPED=false

usage() {
    cat <<EOF
Immich restore snapshot

Restores an Immich backup created by backup-immich-snapshot.sh.

The script:
  - finds the latest backup automatically when given a backup root
  - checks the fresh install against the backup manifest
  - refuses to restore if the compose services/images do not match
  - restores the database dump, media library, and optional external library

Options:
  --immich-dir PATH   Path to the Immich Docker compose folder
  --backup-root PATH  Root folder that contains immich-backup-* directories
  --backup-dir PATH   Exact backup directory to restore
  --yes               Skip the final confirmation prompt
  -h, --help          Show this help text

Examples:
  bash "$SCRIPT_PATH" --immich-dir /srv/immich --backup-root /mnt/backups/immich
  bash "$SCRIPT_PATH" --immich-dir /srv/immich --backup-dir /mnt/backups/immich/immich-backup-2026-07-05_02-00-00 --yes
EOF
}

log() {
    printf '%s\n' "$*"
}

warn() {
    printf 'WARN: %s\n' "$*" >&2
}

die() {
    printf 'ERROR: %s\n' "$*" >&2
    exit 1
}

need_cmd() {
    command -v "$1" >/dev/null 2>&1 || die "Required command not found: $1"
}

confirm() {
    local prompt="$1"
    local reply

    while true; do
        read -r -p "$prompt [y/N]: " reply || return 1
        case "${reply,,}" in
            y|yes) return 0 ;;
            n|no|'') return 1 ;;
            *) log "Please answer y or n." ;;
        esac
    done
}

prompt_text() {
    local prompt="$1"
    local value

    while true; do
        read -r -p "$prompt: " value || return 1
        if [[ -n "$value" ]]; then
            printf '%s\n' "$value"
            return 0
        fi
        log "Please enter a non-empty value."
    done
}

canonical_dir() {
    cd -- "$1" && pwd -P
}

path_is_within() {
    local child="$1"
    local parent="$2"
    [[ "$child" == "$parent" || "$child" == "$parent/"* ]]
}

find_compose_file() {
    local dir="$1"
    local candidate

    for candidate in docker-compose.yml docker-compose.yaml compose.yml compose.yaml; do
        if [[ -f "$dir/$candidate" ]]; then
            printf '%s\n' "$dir/$candidate"
            return 0
        fi
    done

    return 1
}

read_env_value() {
    local file="$1"
    local key="$2"
    local line

    line="$(grep -m1 -E "^${key}=" "$file" 2>/dev/null || true)"
    [[ -n "$line" ]] || return 1
    line="${line#${key}=}"
    line="$(printf '%s' "$line" | sed 's/\r$//; s/^"//; s/"$//')"
    printf '%s\n' "$line"
}

find_latest_backup() {
    local root="$1"
    local -a candidates=()
    local candidate

    shopt -s nullglob
    candidates=("$root"/immich-backup-* "$root"/immich-snapshot-*)
    shopt -u nullglob

    if (( ${#candidates[@]} == 0 )); then
        return 1
    fi

    printf '%s\n' "${candidates[@]}" | sort | while IFS= read -r candidate; do
        [[ -d "$candidate" ]] || continue
        compgen -G "$candidate/database/immich-database-*.sql.gz" >/dev/null || continue
        printf '%s\n' "$candidate"
    done | tail -n 1
}

looks_like_backup_dir() {
    local dir="$1"
    [[ -d "$dir/database" ]] || return 1
    compgen -G "$dir/database/immich-database-*.sql.gz" >/dev/null || return 1
    return 0
}

select_backup_dir() {
    if [[ -n "$BACKUP_DIR" ]]; then
        return 0
    fi

    if [[ -z "$BACKUP_ROOT" ]]; then
        BACKUP_ROOT="$(prompt_text "Enter the backup root directory")"
    fi

    BACKUP_ROOT="$(canonical_dir "$BACKUP_ROOT")"

    if looks_like_backup_dir "$BACKUP_ROOT"; then
        BACKUP_DIR="$BACKUP_ROOT"
        return 0
    fi

    BACKUP_DIR="$(find_latest_backup "$BACKUP_ROOT" 2>/dev/null || true)"

    [[ -n "$BACKUP_DIR" ]] || die "No immich-backup-* or immich-snapshot-* directories were found in: $BACKUP_ROOT"
}

find_manifest_file() {
    local backup_dir="$1"
    local candidate="$backup_dir/backup-manifest.json"
    [[ -f "$candidate" ]] && printf '%s\n' "$candidate"
}

load_manifest_and_validate() {
    local manifest_file="$1"
    local compose_file="$2"
    local current_media_root="${3:-}"

    python3 - "$manifest_file" "$compose_file" "$current_media_root" <<'PY'
import json
import shlex
import subprocess
import sys
from pathlib import Path

manifest_file, compose_file, current_media_root = sys.argv[1:4]

with open(manifest_file, 'r', encoding='utf-8') as fh:
    manifest = json.load(fh)

def run(cmd):
    return subprocess.check_output(cmd, text=True).splitlines()

saved_services = sorted(manifest.get('compose_services', []))
saved_images = sorted(manifest.get('compose_images', []))
current_services = sorted(run(['docker', 'compose', '-f', compose_file, 'config', '--services']))
current_images = sorted(run(['docker', 'compose', '-f', compose_file, 'config', '--images']))

missing_services = [s for s in saved_services if s not in current_services]
extra_services = [s for s in current_services if s not in saved_services]
missing_images = [i for i in saved_images if i not in current_images]
extra_images = [i for i in current_images if i not in saved_images]

if missing_services or extra_services or missing_images or extra_images:
    print('ERROR: Compose compatibility check failed.')
    if missing_services:
        print('Missing services: ' + ', '.join(missing_services))
    if extra_services:
        print('Unexpected services: ' + ', '.join(extra_services))
    if missing_images:
        print('Missing images: ' + ', '.join(missing_images))
    if extra_images:
        print('Unexpected images: ' + ', '.join(extra_images))
    sys.exit(1)

saved_media_root = manifest.get('media_root', '')
if current_media_root and saved_media_root and Path(current_media_root).resolve() != Path(saved_media_root).resolve():
    print('ERROR: Media storage path does not match the backup manifest.')
    print(f'Backup media root: {saved_media_root}')
    print(f'Current media root: {current_media_root}')
    sys.exit(1)

print(f"DB_SERVICE={shlex.quote(manifest.get('db_service', ''))}")
print(f"MEDIA_ROOT={shlex.quote(saved_media_root)}")
print(f"EXTERNAL_LIBRARY={shlex.quote(manifest.get('external_library') or '')}")
PY
}

resolve_media_root() {
    if [[ -n "$MEDIA_ROOT" ]]; then
        return 0
    fi

    if [[ -f "$IMMICH_DIR/.env" ]]; then
        MEDIA_ROOT="$(read_env_value "$IMMICH_DIR/.env" "UPLOAD_LOCATION" || true)"
    fi

    [[ -n "$MEDIA_ROOT" ]] || die "Could not determine the Immich media root."

    if [[ "$MEDIA_ROOT" != /* ]]; then
        MEDIA_ROOT="$IMMICH_DIR/$MEDIA_ROOT"
    fi

    MEDIA_ROOT="$(canonical_dir "$MEDIA_ROOT")"
}

restore_database() {
    local dump_file="$1"

    log ""
    log "Starting database service..."
    docker compose -f "$COMPOSE_FILE" up -d "$DB_SERVICE"

    log "Recreating database..."
    docker compose -f "$COMPOSE_FILE" exec -T "$DB_SERVICE" sh -lc '
        set -eu
        db_name="${DB_DATABASE_NAME:-${POSTGRES_DB:-}}"
        db_user="${DB_USERNAME:-${POSTGRES_USER:-}}"

        if [ -z "$db_name" ] || [ -z "$db_user" ]; then
            echo "ERROR: The database container does not expose DB_DATABASE_NAME/DB_USERNAME or POSTGRES_DB/POSTGRES_USER." >&2
            exit 1
        fi

        dropdb --if-exists --username="$db_user" "$db_name"
        createdb --username="$db_user" --owner="$db_user" "$db_name"
    '

    log "Restoring database dump..."
    gunzip -c "$dump_file" | docker compose -f "$COMPOSE_FILE" exec -T "$DB_SERVICE" sh -lc '
        set -eu
        db_name="${DB_DATABASE_NAME:-${POSTGRES_DB:-}}"
        db_user="${DB_USERNAME:-${POSTGRES_USER:-}}"

        if [ -z "$db_name" ] || [ -z "$db_user" ]; then
            echo "ERROR: The database container does not expose DB_DATABASE_NAME/DB_USERNAME or POSTGRES_DB/POSTGRES_USER." >&2
            exit 1
        fi

        exec psql --username="$db_user" --dbname="$db_name"
    '
}

restore_tree() {
    local source="$1"
    local destination="$2"
    local label="$3"

    if [[ ! -d "$source" ]]; then
        warn "$label backup directory not found, skipping: $source"
        return 0
    fi

    mkdir -p "$destination"
    log "Restoring $label..."
    rsync -a --no-owner --no-group --no-perms --human-readable --info=progress2 --stats "$source/" "$destination/"
}

cleanup() {
    if [[ "$STACK_STOPPED" == true ]]; then
        log ""
        log "Starting Immich services back up..."
        docker compose -f "$COMPOSE_FILE" up -d || true
    fi
}

trap cleanup EXIT INT TERM

while [[ $# -gt 0 ]]; do
    case "$1" in
        --immich-dir)
            IMMICH_DIR="${2:-}"
            [[ -n "$IMMICH_DIR" ]] || die "--immich-dir requires a path"
            shift 2
            ;;
        --backup-root)
            BACKUP_ROOT="${2:-}"
            [[ -n "$BACKUP_ROOT" ]] || die "--backup-root requires a path"
            shift 2
            ;;
        --backup-dir)
            BACKUP_DIR="${2:-}"
            [[ -n "$BACKUP_DIR" ]] || die "--backup-dir requires a path"
            shift 2
            ;;
        --yes)
            AUTO_YES=true
            shift
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        *)
            die "Unknown argument: $1"
            ;;
    esac
done

need_cmd docker
need_cmd rsync
need_cmd gunzip
need_cmd python3
need_cmd grep
need_cmd sed
need_cmd mktemp

if [[ -z "$IMMICH_DIR" ]]; then
    if confirm "Is the current folder your Immich Docker folder?"; then
        IMMICH_DIR="$(pwd -P)"
    else
        IMMICH_DIR="$(prompt_text "Enter the full path to the Immich Docker folder")"
    fi
fi

if [[ "$IMMICH_DIR" != /* ]]; then
    IMMICH_DIR="$PWD/$IMMICH_DIR"
fi

[[ -d "$IMMICH_DIR" ]] || die "Immich directory does not exist: $IMMICH_DIR"
IMMICH_DIR="$(canonical_dir "$IMMICH_DIR")"
COMPOSE_FILE="$(find_compose_file "$IMMICH_DIR" 2>/dev/null || true)"
[[ -n "$COMPOSE_FILE" ]] || die "No supported compose file was found in: $IMMICH_DIR"

select_backup_dir
BACKUP_DIR="$(canonical_dir "$BACKUP_DIR")"
[[ -d "$BACKUP_DIR" ]] || die "Backup directory does not exist: $BACKUP_DIR"

CURRENT_MEDIA_ROOT=""
if [[ -f "$IMMICH_DIR/.env" ]]; then
    CURRENT_MEDIA_ROOT="$(read_env_value "$IMMICH_DIR/.env" "UPLOAD_LOCATION" || true)"
    if [[ -n "$CURRENT_MEDIA_ROOT" && "$CURRENT_MEDIA_ROOT" != /* ]]; then
        CURRENT_MEDIA_ROOT="$IMMICH_DIR/$CURRENT_MEDIA_ROOT"
    fi
    if [[ -n "$CURRENT_MEDIA_ROOT" ]]; then
        CURRENT_MEDIA_ROOT="$(canonical_dir "$CURRENT_MEDIA_ROOT")"
    fi
fi

MANIFEST_FILE="$(find_manifest_file "$BACKUP_DIR" || true)"
if [[ -n "$MANIFEST_FILE" ]]; then
    log "Found backup manifest: $MANIFEST_FILE"
    eval "$(load_manifest_and_validate "$MANIFEST_FILE" "$COMPOSE_FILE" "${CURRENT_MEDIA_ROOT:-}")"
else
    warn "No manifest file found in the backup. Compatibility checks will be limited."
    if [[ -f "$IMMICH_DIR/.env" ]]; then
        MEDIA_ROOT="$(read_env_value "$IMMICH_DIR/.env" "UPLOAD_LOCATION" || true)"
    fi
    if [[ -z "$MEDIA_ROOT" ]]; then
        MEDIA_ROOT="$(prompt_text "Enter the Immich media storage path")"
    fi
    if [[ "$MEDIA_ROOT" != /* ]]; then
        MEDIA_ROOT="$IMMICH_DIR/$MEDIA_ROOT"
    fi
    MEDIA_ROOT="$(canonical_dir "$MEDIA_ROOT")"
fi

if [[ -z "$DB_SERVICE" ]]; then
    DB_SERVICE="$(python3 - "$COMPOSE_FILE" <<'PY'
import subprocess
import sys
compose_file = sys.argv[1]
services = subprocess.check_output(['docker', 'compose', '-f', compose_file, 'config', '--services'], text=True).splitlines()
for candidate in ('immich_postgres', 'immich-postgres', 'postgres', 'postgresql', 'db', 'database', 'immich_db', 'immich-db', 'postgres-db'):
    if candidate in services:
        print(candidate)
        raise SystemExit(0)
raise SystemExit(1)
PY
)" || true
fi

[[ -n "$DB_SERVICE" ]] || die "Could not determine the database service."

if ! docker compose -f "$COMPOSE_FILE" config --services | grep -Fxq "$DB_SERVICE"; then
    die "The database service is not present in the compose file: $DB_SERVICE"
fi

MEDIA_ROOT="$(canonical_dir "$MEDIA_ROOT")"

if [[ -n "$EXTERNAL_LIBRARY" ]]; then
    if [[ "$EXTERNAL_LIBRARY" != /* ]]; then
        EXTERNAL_LIBRARY="$IMMICH_DIR/$EXTERNAL_LIBRARY"
    fi
    EXTERNAL_LIBRARY="$(canonical_dir "$EXTERNAL_LIBRARY")"
fi

DB_DUMP_FILE=""
mapfile -t dump_candidates < <(find "$BACKUP_DIR/database" -maxdepth 1 -type f -name 'immich-database-*.sql.gz' 2>/dev/null | sort)
if (( ${#dump_candidates[@]} == 0 )); then
    die "No database dump was found in: $BACKUP_DIR/database"
fi
DB_DUMP_FILE="${dump_candidates[-1]}"

log "======================================================"
log "Immich restore started: $(date)"
log "Immich directory:   $IMMICH_DIR"
log "Compose file:       $COMPOSE_FILE"
log "Backup directory:    $BACKUP_DIR"
log "Database service:   $DB_SERVICE"
log "Media target:       $MEDIA_ROOT"
log "External library:    ${EXTERNAL_LIBRARY:-<none>}"
log "======================================================"

if [[ "$AUTO_YES" == false ]]; then
    confirm "Proceed with the restore now?" || die "Cancelled by user."
fi

log ""
log "Stopping the Immich compose stack..."
docker compose -f "$COMPOSE_FILE" stop
STACK_STOPPED=true

restore_database "$DB_DUMP_FILE"
restore_tree "$BACKUP_DIR/media" "$MEDIA_ROOT" "media"

if [[ -n "$EXTERNAL_LIBRARY" && -d "$BACKUP_DIR/external" ]]; then
    restore_tree "$BACKUP_DIR/external" "$EXTERNAL_LIBRARY" "external library"
fi

log ""
log "Starting Immich services..."
docker compose -f "$COMPOSE_FILE" up -d
STACK_STOPPED=false

log ""
log "Immich restore completed successfully: $(date)"
log "Backup directory used: $BACKUP_DIR"
log "Database dump used:     $DB_DUMP_FILE"
