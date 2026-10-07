# copy-checker

copy verify checker

## verify-backup

A single Bash script that checks whether **every file in a source folder was actually copied** to one or more backup destinations: external USB disks, a second volume, a mounted share.

It was written for a Synology NAS that was backed up to USB disks, but it runs on any Linux box with Bash and the standard GNU tools.

- **Finds what is missing**: files that are not in any destination, or whose copy has the wrong size.
- **Checks the content**: compares hashes of source and copy, either quick (`fast`) or whole-file (`full`).
- **Handles split backups**: one source folder can be spread over several disks. A file counts as copied if it is in *any* of the destinations.
- **Lets you close SSH**: long steps run in the background with `-d`, so you don't need `screen` or `tmux`.
- **Resumes**: stop it (or lose power) during a multi-hour hash run, then start it again. It picks up from the files not hashed yet.
- **Reads disks in parallel**: files are grouped by physical device, so the source volume and each USB disk are read at the same time.
- **Never modifies your data**: it only reads the source and destination folders.

### Quick start

```bash
# 1. Copy the script and an example config to the NAS
cp verify_backup.conf.example verify_backup.conf
vi verify_backup.conf                       # describe your source → destination folders

# 2. Quick check (seconds): is every file there, with the right size?
sudo bash verify_backup.sh size

# 3. Content check, one step at a time, in the background
sudo bash verify_backup.sh -d hash-src      # hash the source files
sudo bash verify_backup.sh status           # progress; you can log out meanwhile
sudo bash verify_backup.sh -d hash-dst      # hash the backup copies
sudo bash verify_backup.sh compare          # compare and write the report
```

`sudo` is only needed if your user cannot read every file in the folders being checked.

### Configuration

`verify_backup.conf` (next to the script, or pass `-c FILE`) has one mapping per line:

```
NAME | SOURCE | DESTINATION [| DESTINATION ...]
```

```
# a folder copied to one disk
PHOTOS    | /volume1/photo/2024         | /volumeUSB1/usbshare/photo/2024

# a folder too big for one disk, split across two
PROJECT_A | /volume1/data/project_a/raw | /volumeUSB1/usbshare/project_a/raw | /volumeUSB2/usbshare/project_a/raw
```

- `NAME` is a short label used in the report file names. Use letters, digits, `.`, `_` or `-`.
- Each destination must keep the **same relative layout** as the source. `SOURCE/a/b.txt` is looked for at `DESTINATION/a/b.txt`.
- Lines starting with `#` and blank lines are ignored.
- Every folder is checked before anything starts, so a typo stops the script immediately.

### Commands

| Command | What it does | Typical time |
|---|---|---|
| `size` | Lists source and destinations, then checks presence and file size only | seconds |
| `hash-src [fast\|full]` | Hashes every source file | minutes (`fast`) / hours (`full`) |
| `hash-dst [fast\|full]` | Hashes every file in the destinations | minutes (`fast`) / hours (`full`) |
| `compare [fast\|full]` | Compares the two sets of hashes and writes a report | seconds |
| `status` | Shows running steps, their latest progress and the hashes already computed | — |
| `stop` | Stops running steps. Run the step again to resume | — |

`hash-src` and `hash-dst` are independent. Run them one after the other, or together since they read different disks. `compare` refuses to start while either one is still running, or if one is missing.

#### Options

| Option | Meaning |
|---|---|
| `-d`, `--detach` | Run in the background with `nohup` and `setsid`. Output goes to `<workdir>/<command>.log` |
| `-c`, `--config FILE` | Mapping file (default: `verify_backup.conf` next to the script) |
| `-w`, `--workdir DIR` | Where hashes, logs and reports are stored (default: `verify_work/` next to the script) |
| `-h`, `--help` | Show the built-in help |

Options go before the command: `verify_backup.sh -c other.conf -d hash-src full`.

### `fast` vs `full`

| Mode | What is hashed | Catches | Misses |
|---|---|---|---|
| `fast` (default) | first and last 4 MB of each file | missing files, truncated copies, empty or zero-filled files, an interrupted copy whose end was never written | corruption in the middle of a file whose size is right |
| `full` | the whole file | any difference | — |

A good routine: run `size` first, then `fast`, then `full` overnight for the final word.

Hashes from different settings are never mixed. The hash files are tagged with the mode, chunk size and algorithm (for example `fast4M-md5` or `full-md5`), and `compare` only compares files with the same tag.

#### Settings (environment variables)

| Variable | Default | Meaning |
|---|---|---|
| `HASH_CMD` | `md5sum` | Hash program. `md5sum` is the fastest and is fine for detecting copy errors. Use `sha256sum` if you need it |
| `CHUNK_MB` | `4` | Size of the head and tail chunks hashed in `fast` mode |
| `PARALLEL` | `1` | Files read at the same time **per device**. Keep 1 for spinning USB disks; 2–4 can help on RAID or SSD |

```bash
sudo HASH_CMD=sha256sum CHUNK_MB=64 bash verify_backup.sh -d hash-src fast
```

Use the same settings for `hash-src`, `hash-dst` and `compare`.

### The report

Each `compare` (or `size`) creates `verify_work/report_<tag>_<date>/`:

```
report.txt                    summary, one block per mapping
<NAME>.MISSING.txt            ← source files with no copy at all
<NAME>.SIZE_MISMATCH.txt      ← a copy exists but its size differs (usually an incomplete copy)
<NAME>.HASH_MISMATCH.txt      ← same size, different content
<NAME>.READ_ERRORS.txt        ← a file could not be read (permissions, disk error)
<NAME>.MULTIPLE_COPIES.txt      info: file present in more than one destination, with the status of each copy
<NAME>.ONLY_IN_DEST.txt         info: files in the destination that are not in the source
```

Lists are only written when there is something to list: if none of the four ← files exists, the backup is complete. Example summary:

```
PROJECT_A    source 1520 files (3712.4 GB) | ok 1517 | MISSING 2 | SIZE MISMATCH 1 | HASH MISMATCH 0 | READ ERRORS 0
             (info: multiple copies 0 | only in destination 0)

RESULT: 3 PROBLEMS — details in /volume1/homes/me/verify_work/report_fast4M-md5_20261007_101500
```

When a file has copies on several disks, it counts as OK if **at least one** copy is intact. The exit code is `0` when everything is OK, `1` when problems were found and `2` on usage or configuration errors.

### The work directory

`verify_work/` keeps everything between steps:

| File | Content |
|---|---|
| `src.hash.<tag>.tsv`, `dst.hash.<tag>.tsv` | Final manifests: name, root, relative path, size, hash |
| `raw.*.tsv` | Hashes as they are computed (used to resume) |
| `*.log` | Output of each step |
| `report_*/` | Reports |

To start over from scratch, delete the folder.

### Notes

- **Ignored files**: Synology `@eaDir` and `#recycle` folders, macOS `.DS_Store` and Windows `Thumbs.db` are left out on both sides.
- **Requirements**: Bash, plus the GNU versions of `find`, `stat`, `xargs`, `head`, `tail` and `md5sum`/`sha256sum`, and `df`. All of these ship with Synology DSM 7 and common Linux distributions. On macOS, install GNU coreutils and findutils.
- **File names**: paths with tabs or newlines in them are not supported.
- **Logging out**: a step started without `-d` stops when the SSH session closes. Use `-d` for anything long.
