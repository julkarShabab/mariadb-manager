# mariadb-manager

A single Bash script to back up, restore, delete, and clean up MariaDB databases. Dumps are stored as gzip files (`.sql.gz`), and dumps older than a set number of days (default 7) are removed automatically.

If you leave out a database or file name, the script shows a numbered menu so you pick by number instead of typing long names.

## Features

- **backup**: dump one database or all databases to a timestamped `.sql.gz` file
- **restore**: load a dump back under the original name or any new name
- **delete**: remove one dump, or all dumps of one database
- **drop**: remove a live database from the server (asks first)
- **cleanup**: delete dumps older than the retention days (default 7)
- **list**: show stored dumps with size and date
- **dbs**: show live databases with table count and size, or the tables of one database
- Numbered menus when arguments are missing
- Settings can be changed per run with flags or environment variables, no file editing
- Integrity check (`gzip -t`) after every backup; corrupt or partial files are deleted
- Confirmation prompts before restore, delete, and drop
- Every action is logged with a timestamp

## Requirements

- Linux with Bash
- MariaDB (the script uses `mariadb-dump` / `mariadb`, and falls back to `mysqldump` / `mysql` on older versions)
- `gzip`, `find`, `sudo`
- A MariaDB login (see "Login setup" below)

## Installation

```bash
# Run in terminal (any directory)
git clone https://github.com/julkarShabab/mariadb-manager.git   # download the repo
cd mariadb-manager                                          # go into the folder
chmod +x mariadb-manager.sh                                 # make the script runnable
```

Or, if you only copy the file by hand:

```bash
# Run in terminal (folder holding the script)
chmod +x mariadb-manager.sh     # make the script runnable
```

## Login setup

The script reads the MariaDB login from a `.my.cnf` file, so no password is ever written inside the script.

First test whether you need it. If this prints a result without asking for a password, MariaDB root uses the Unix socket and you can skip the file:

```bash
# Run in terminal
sudo mariadb -e "SELECT 1;"     # works without a password = no .my.cnf needed
```

If you get `Access denied`, create the file with your **MariaDB** password (not your sudo password):

```bash
# Run in terminal
nano ~/.my.cnf                  # create the login file
chmod 600 ~/.my.cnf             # only you can read it
```

```ini
# ~/.my.cnf
[client]
user=root
password=YOUR_MARIADB_PASSWORD
```

The script looks for the login file in this order: `~/.my.cnf`, the home of the user who ran `sudo`, then `/root/.my.cnf`. You can also point to any file with `--creds`.

Never commit `.my.cnf` to Git. The `.gitignore` in this repo already blocks it.

## Where things are stored

```
/var/backups/mariadb/                      <- dumps (folder is chmod 700, root only)
    mydb_2026-10-12_10-00-00.sql.gz
    all-databases_2026-10-12_10-00-00.sql.gz
/var/log/mariadb-manager.log               <- log of every action
~/.my.cnf                                  <- MariaDB login (chmod 600)
```

If `/var/log` is not writable, the log falls back to `~/mariadb-manager.log`.

## Usage

Syntax:

```bash
# Run in terminal
sudo ./mariadb-manager.sh [flags] <command> [arguments]   # flags first, then command, then arguments
```

1. **Flags** (optional) change a setting for this run only. They go before the command.
2. **Command** (required) is the action: `backup`, `restore`, `delete`, `drop`, `cleanup`, `list`, `dbs`.
3. **Arguments** (optional) are what the command works on, such as a database or file name. If you leave them out, a numbered menu appears.

### Commands

```bash
# Run in terminal (from the folder holding the script)
sudo ./mariadb-manager.sh                         # show help/usage
sudo ./mariadb-manager.sh backup                  # menu: pick a database (0 = ALL)
sudo ./mariadb-manager.sh backup mydb             # back up one database
sudo ./mariadb-manager.sh backup --all            # back up all databases
sudo ./mariadb-manager.sh list                    # show stored dumps
sudo ./mariadb-manager.sh dbs                     # live databases with table count and size
sudo ./mariadb-manager.sh dbs mydb                # tables inside mydb with rows and size
sudo ./mariadb-manager.sh restore                 # menu: pick a dump, then choose target name
sudo ./mariadb-manager.sh restore FILE.sql.gz mydb_copy   # restore a specific dump into a chosen name
sudo ./mariadb-manager.sh delete                  # menu: pick one dump to delete
sudo ./mariadb-manager.sh delete --db mydb        # delete all dumps starting with mydb_
sudo ./mariadb-manager.sh drop                    # menu: drop a live database (dangerous)
sudo ./mariadb-manager.sh cleanup                 # delete dumps older than 7 days
```

### What each command does

| Command | What it does |
|---|---|
| `backup [db\|--all]` | Dumps with `--single-transaction` (no table locking) including routines, triggers, and events. Compresses on the fly with `gzip -9`, tests the file, then runs cleanup. |
| `restore [file] [db]` | Unzips the dump into the MariaDB client. `CREATE DATABASE` / `USE` lines are removed, so it can be loaded into any database name. Press Enter at the name prompt to use the original name. |
| `delete [file]` | Deletes one dump. Refuses files outside the backup folder. |
| `delete --db <db>` | Lists, then deletes all dumps whose name starts with `<db>_`. Read the list before confirming. |
| `drop [db]` | Drops a live database. Refuses `mysql`, `sys`, `information_schema`, `performance_schema`. |
| `cleanup` | Deletes `.sql.gz` files in the backup folder older than the retention days. |
| `list` | Lists stored dumps, newest first. |
| `dbs [db]` | Shows live databases (table count, size in MB), or the tables of one database (approximate rows, size). |

Restoring an `all-databases_*` dump does not ask for a target name. It restores every database in the file, and existing data can be overwritten.

## Flags

Flags go **before** the command.

| Flag | What it changes | Default |
|---|---|---|
| `--dir <path>` | Backup folder | `/var/backups/mariadb` |
| `--days <n>` | Retention in days | `7` |
| `--creds <file>` | Login file | auto-detected |
| `-y`, `--yes` | Skips all y/N confirmations | off |

```bash
# Run in terminal
sudo ./mariadb-manager.sh --days 14 cleanup               # keep 14 days instead of 7, this run only
sudo ./mariadb-manager.sh --dir /data/dumps backup mydb   # store this dump in another folder
sudo ./mariadb-manager.sh --creds /root/.my.cnf list      # use a specific login file
sudo RETENTION_DAYS=3 ./mariadb-manager.sh list           # same override through an environment variable
```

Environment variables: `BACKUP_DIR`, `RETENTION_DAYS`, `LOG_FILE`, `CREDS_FILE`. Priority is flag, then environment variable, then built-in default.

Use `--yes` with care: it also skips the confirmation for `delete` and `drop`.

## How the 7-day cleanup works

Cleanup runs automatically at the end of every successful `backup`, and you can run it by hand with `cleanup`. It deletes `.sql.gz` files in the backup folder whose modified time is older than the retention days, and logs each file it removes.

There is no scheduler built in. Backups are **manual**: nothing runs unless you run the script. If you stop taking backups, old dumps stay until you run `backup` or `cleanup` again.

## Suggested first test

```bash
# Run in terminal (from the folder holding the script)
sudo ./mariadb-manager.sh backup mydb      # 1. create a dump
sudo ./mariadb-manager.sh list             # 2. confirm the file exists
sudo ./mariadb-manager.sh restore          # 3. pick the dump, type a new name like mydb_test
sudo ./mariadb-manager.sh dbs mydb_test    # 4. confirm the tables exist in the restored copy
sudo ./mariadb-manager.sh drop mydb_test   # 5. remove the test copy
```

A restore creates a live database inside MariaDB. It does not create a file. The dump file stays untouched in the backup folder.

## Reading the log

```bash
# Run in terminal
sudo tail -n 30 /var/log/mariadb-manager.log   # last 30 log lines
```

Only `backup`, `restore`, `delete`, `drop`, `cleanup`, and errors write to the log. `list`, `dbs`, and the help text do not, so an empty log just means none of those actions have run yet.

## Troubleshooting

| Problem | Likely cause and fix |
|---|---|
| `Access denied for user` | Wrong or missing login. Check `~/.my.cnf` or pass `--creds`. |
| `Cannot create /var/backups/mariadb` | Run with `sudo`, or choose a writable folder with `--dir`. |
| `no databases found or cannot connect` | MariaDB is not running or login failed. Check `sudo systemctl status mariadb`. |
| `file not found` | Wrong name. Run `list`, or run `restore` with no arguments and pick from the menu. |
| `Invalid choice` | You typed something other than a number from the list. |
| `invalid database name` | Only letters, digits, `_`, `$`, and `-` are allowed. |
| `archive is corrupt` / `dump failed` | The partial file was removed. Check the log and free disk space with `df -h`. |

## Safety notes

1. `drop` and `restore` change real data. Back up first.
2. Keep `~/.my.cnf` at `chmod 600` and the backup folder at `chmod 700`.
3. Never commit `.my.cnf`, dumps, or logs to Git.
4. Backups on the same disk do not protect against disk failure. Copy important dumps to another machine.
5. Using the MariaDB `root` account is the simplest option. A dedicated backup user with limited rights is safer long term.

## Known limits

1. Flags must come before the command (`--days 14 cleanup`, not `cleanup --days 14`).
2. Retention uses the file's modified time, not the date in the filename.
3. `delete --db mydb` matches `mydb_*`, so a database named `mydb_test` would also match.
4. Row counts in `dbs <db>` are estimates for InnoDB tables.
