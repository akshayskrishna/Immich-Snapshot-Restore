# Immich Restore Snapshot

A restore script for Immich backups.

This guide explains how the restore workflow works, what it validates, and how to run it safely on a fresh Immich install of the same version.

If you want the backup tool

- [Complete Snapshots](https://github.com/akshayskrishna/Immich-Backup-Snapshot)
- [Incremental Backup](https://github.com/akshayskrishna/Immich-Incremental-Snapshot)

### Tested on version

- [x] v2.7.5
- [x] v3.0.1

> [!CAUTION]
> Do not mix between the version, the Immich instance will crash

## What this tool does

- finding the latest backup automatically when you provide a backup root
- accepting either `immich-backup-*` or `immich-snapshot-*` backup folders
- reading the `backup-manifest.json` written by the backup script when it is available
- checking the current Immich compose services and images against the manifest
- refusing to restore if the compose shape does not match
- restoring the PostgreSQL database dump
- restoring the media library
- restoring the external library when one was backed up
- normalizing ownership on the selected restore paths with `sudo chown -R 1000:1000` before restore begins
- starting Immich again after the restore

## Safety checks

The restore script is designed for a **fresh install of the same Immich version**.

Before restoring, it checks:

- the compose service list
- the compose image list
- the media storage path
- the presence of a database dump in the selected backup

If any of those checks fail, the script stops before touching the live data.

### Caution

> [!WARNING]
>
> - This script assumes the user installing and running will be the main user, it has chown command hardcoded.

## Backup layout it expects

The restore script expects the backup tree created by the snapshot script. It accepts either of these folder patterns:

```text
immich-backup-YYYY-MM-DD_HH-MM-SS/
  backup-manifest.json
  database/
    immich-database-YYYY-MM-DD_HH-MM-SS.sql.gz
  media/
  external/        # only when an external library was backed up
  logs/

immich-snapshot-YYYY-MM-DD_HH-MM-SS/
  backup-manifest.json
  database/
    immich-database-YYYY-MM-DD_HH-MM-SS.sql.gz
  media/
  external/        # only when an external library was backed up
  logs/
```

## How it works

### 1) Select the Immich Docker folder

The script first asks whether the current folder is the Immich Docker folder.

- If yes, it uses the current working directory.
- If no, it asks for the correct path.
- It validates that a supported Docker Compose file exists before continuing.

### 2) Select the backup source

You can point the script at either:

- a specific backup directory, or
- a backup root that contains multiple `immich-backup-*` folders

If you give only the root, the script automatically chooses the latest valid backup.

### 3) Validate the fresh install

If a manifest exists, the script compares the current compose config to the saved manifest.

It checks:

- service names
- image names/tags
- media path

This helps prevent restoring into the wrong stack version or an incompatible compose layout.

### 4) Stop the stack briefly

The script stops Immich before restoring data.

That keeps the restore consistent and avoids live writes during the file copy and database import.

### 5) Restore the database

The script decompresses the saved SQL dump and pipes it into `psql` inside the database container.

This is the step that brings back the Immich metadata, albums, asset records, and related state.

### 6) Restore the files

The script restores:

- `media/` back to the Immich upload location
- `external/` back to the external library path, if present

### 7) Start Immich again

After everything is restored, the script brings the stack back up.

## Usage

### Download the script

```bash
wget https://raw.githubusercontent.com/akshayskrishna/Immich-Snapshot-Restore/main/restore-immich-snapshot.sh
```

### Interactive (recommended)

```bash
bash restore-immich-snapshot.sh
```

### Restore the latest backup in a root folder

```bash
bash restore-immich-snapshot.sh \
  --immich-dir /path/to/immich-app \
  --backup-root /path/to/backups
```

### Restore a specific snapshot

```bash
bash restore-immich-snapshot.sh \
  --immich-dir /path/to/immich-app \
  --backup-dir /path/to/backups/immich-backup-2026-xx-xx_xx-xx-xx \
  --yes
```

## Requirements

The script expects these tools to be available:

- `bash`
- `docker`
- `rsync`
- `gunzip`
- `python3`
- `grep`
- `sed`
- `mktemp`

## Safety notes

- Use a fresh Immich install of the same version.
- Do not point the script at the wrong backup root.
- Always verify the backup manifest before restoring in production.
- The script is intentionally cautious and fails closed when compatibility checks do not match.

## Banner inspiration

The ASCII branding style in this script is inspired by:

- [shinshin86/oh-my-logo](https://github.com/shinshin86/oh-my-logo)

## Recommended workflow

1. Make a fresh Immich install of the same version.
2. Confirm the compose folder.
3. Confirm the backup directory or backup root.
4. Let the script validate the manifest.
5. Restore the database and media.
6. Confirm Immich starts cleanly afterward.

> Updated on July 06, 2026
