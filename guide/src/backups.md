# Backups

A knowledge base backs itself up in two places. **Snapshots** are taken every hour on the machine
it runs on, to undo a mistake or a bad upgrade. **Copies off the machine** go to a bucket or another
drive once a day, encrypted, for when the machine and its disk are lost. This page covers both: what
they hold, how to set them up, how to watch and check them, and how to restore from either.

## What a backup holds

| Part | In a snapshot | In a copy off the machine |
|---|---|---|
| The database: papers, records, tasks, findings, accounts, settings | yes | yes |
| The config folder, its secrets included (OAuth secrets, tokens, keys) | yes | yes |
| The content folder (the group's pages, notebooks, assets) and the records' documents | yes | yes |
| Uploads, PDFs, figures and media | yes (`files`) | yes (`files`) |
| Paths `[backup] include` names (a web server's config, say) | yes | yes |
| The vectors search uses (Qdrant) | no | no |
| The built site, cloned codebases, Kaimon's code index | no: rebuilt | no: rebuilt |

The vectors are left out. After a restore onto a machine that still has the knowledge base's
Qdrant collections, search works at once. Onto a new machine, the vectors have to be made again
from the database's texts. That is not yet automatic; until it is, a restore on a new machine needs
its embeddings redone before search returns anything.

## Snapshots on this machine

The knowledge base snapshots itself every hour into a folder beside its data folder: the data
folder's path with `.backups` added (`~/.local/share/zemi.backups`, or `/srv/zemi/data.backups` on a
server). A snapshot packs the database, config and content into one compressed file, and copies the
files. A file unchanged since the last snapshot is hard-linked to that snapshot's copy, so it takes
no more space. The folder is readable only by its owner, since it holds the config's secrets.

```toml
[backup]
enabled = true                 # on by default
dir = "/mnt/backups/zemi"      # another disk, or a mounted share, survives losing this one
every_hours = 1
keep_all_hours = 24            # every snapshot of the last day
keep_half_daily_days = 3       # then one per 12 hours
keep_daily_days = 14           # then one a day; none older
files = true                   # false: the uploads only, not the PDFs and figures
min_free_gb = 5                # no snapshot when the disk has less free
max_gb = 0                     # past this, the oldest go first; 0 for no limit
include = ["/etc/caddy"]       # further paths, put back only when asked (--include)
```

`dir` must be outside the data folder. A small group's knowledge base takes a few MB a snapshot
packed, and its files once: about 45 snapshots under 1 GB.

Some snapshots are kept by name until deleted:
- `before-schema-<n>`, taken before the database is migrated to a new schema;
- `before-restore-<time>`, taken before a restore, so a restore can be undone the same way;
- any taken with `zemi backup --keep NAME`.

```sh
zemi backups                       # the snapshots, the latest first
zemi backup                        # one now
zemi backup --keep before-upgrade  # one now, kept until deleted
```

The Status page shows the last snapshot and the backups' size, with **Back up now**.

## Copies off this machine

Snapshots on the same machine are lost with it. `[backup.offsite]` sends the latest snapshot once a
day to an S3-compatible bucket (Cloudflare R2, Backblaze B2, AWS S3, MinIO) or to a folder on a
drive mounted here.

**What is sent.** The first copy sends every file once, each named in the store by a hash of its
content, plus the packed database, config and content. After that, a day's copy is the packed part
(a few MB to some tens of MB) and only the files that are new. A file is sent once, however many
copies name it. Copies older than `keep_days` are deleted, all but the latest, and with them the
files no remaining copy names.

**Encryption.** Everything is encrypted before it leaves the machine; the store holds nothing
readable, not even the files' names. Each object is sealed with AES-256-GCM under a data key made
with the store's first copy. The store keeps the data key only sealed, twice:

- with the **key**, a file on this machine (`zemi backup --offsite-key` makes it), which the service
  uses for its daily copies;
- with a **recovery passphrase** a person keeps, set with `zemi backup --offsite-recovery` and never
  stored. It's stretched with scrypt, so guessing it is slow.

Either one opens every copy. Losing the machine and its key file loses nothing while the passphrase
is known. Losing both means nobody can open the copies, including you, so keep a copy of the key
file somewhere other than the machine (a password manager), and the passphrase where you'd look for
it without the machine.

### Setting up with Cloudflare R2

R2's free plan includes 10 GB of storage, enough for a small group's copies.

1. **The bucket.** In the Cloudflare dashboard, go to **R2** and **Create bucket** (say
   `zemi-backups`). Several knowledge bases can share one bucket, each under its own `prefix`.
2. **Its credentials.** Under **R2 › Manage API tokens**, create a token with **Object Read &
   Write**, limited to that bucket. Of what it shows once, keep the **Access Key ID** and the
   **Secret Access Key**: copies go through R2's S3 interface, which uses that pair, not the token
   value. Your **account ID** is on the R2 overview page.
3. **The credentials file**, beside the config, readable only by you:
   ```sh
   umask 077; cat > ~/.config/zemi/r2_backup.toml <<'EOF'
   access_key_id = "…"
   secret_access_key = "…"
   EOF
   ```
4. **The key:**
   ```sh
   zemi backup --offsite-key        # makes ~/.config/zemi/backup_key
   ```
   Put a copy of the key file in your password manager.
5. **The config**, in `config.toml`:
   ```toml
   [backup.offsite]
   store = "s3"
   endpoint = "https://<account id>.r2.cloudflarestorage.com"
   bucket = "zemi-backups"
   prefix = "our-group"           # one per knowledge base sharing the bucket
   credentials = "r2_backup.toml" # beside the config
   key = "file:backup_key"
   every_hours = 24
   keep_days = 14
   files = true                   # false: the database, config and content only
   ```
6. **The first copy, then the recovery passphrase:**
   ```sh
   zemi backup --offsite            # sends the first copy, showing how far it has got
   zemi backup --offsite-recovery   # asks for the passphrase twice, without showing it
   ```
   The passphrase seals the data key the first copy made, so set it once a copy has been sent. On a
   server, run these as the service's user (see [Server deployment](deployment.md#Backups)).
7. **Restart the service.** It reads `[backup.offsite]` when it starts, and from then on sends a copy
   every `every_hours`.

Other S3-compatible stores take the same keys with their own `endpoint`. A folder on a mounted drive
needs no credentials:

```toml
[backup.offsite]
store = "dir:/Volumes/Spare/zemi-offsite"
key = "file:backup_key"
```

### Sending a copy, and watching one

The service sends a copy every `every_hours`, and the Status page's backups section shows where
copies go, how many there are, the last one, any failure, and a copy under way with how far it has
got. To send one now:

```sh
zemi backup --offsite                # sends it here, showing MB and files sent, the rate and the time left
zemi backup --offsite --background   # sends it from a process of its own, which goes on when the terminal closes
zemi backup --offsite --follow       # shows the copy under way, whoever sends it; Ctrl-C leaves it going
```

Only one copy is sent at a time. Running `zemi backup --offsite` while one is under way follows it
instead of starting another, and the service waits for it. A copy sent in the background writes its
output to `offsite.log` in the backups folder.

The first copy takes longest, since it sends every file; a knowledge base of a few hundred PDFs
sends a few hundred MB. Later copies send only what changed.

### Proving the copies open

A backup counts once it has been restored. Check that the latest copy opens with what you keep,
from any machine with the config's `[backup.offsite]`:

```sh
zemi backups --offsite                        # the copies, the latest first, and whether a passphrase is set
zemi backups --offsite --check                # fetch the latest whole with the key: decrypt every part, check the database
zemi backups --offsite --check --recovery     # the same with the passphrase
```

`--check` changes nothing: it fetches the copy into a folder of its own and removes it afterwards.

## Restoring

A restore needs the service stopped. It puts back the database, the content, the records and the
files as they were, after keeping what was there as the snapshot `before-restore-<time>`. With
`--config` it puts back the config folder's files too, and with `--include` the paths
`[backup] include` names, each where it was.

### From a snapshot on this machine

```sh
zemi backups                              # pick one
zemi restore 20261108T010000Z             # the service stopped first
```

To undo the restore, restore the `before-restore-…` snapshot it kept.

### From a copy off the machine

```sh
zemi backups --offsite                                        # the copies, the latest first
zemi restore --offsite 20261108T010000Z --config              # with the key file here
zemi restore --offsite 20261108T010000Z --config --recovery   # or with the passphrase
```

The copy is fetched into the snapshot `offsite-<time>`, each part checked as it is decrypted and
each file against its hash, and then restored as a snapshot is.

### After losing the machine

1. Install Zemi on the new machine ([Installation](installation.md), or
   [Server deployment](deployment.md) for a shared service).
2. Write a config holding only `[backup.offsite]` and the store's credentials file, as in the
   setup above. The key file is gone with the old machine, so the passphrase opens the copies.
3. Restore the latest copy with its config folder:
   ```sh
   zemi backups --offsite                                  # the copies, the latest first
   zemi restore --offsite <latest> --config --recovery
   ```
   `--config` brings back the whole config folder, the key file and the credentials included, so
   the service sends its daily copies again once it starts.
4. Start the service. Search needs its vectors made again (see [What a backup
   holds](#What-a-backup-holds)).

Moving a knowledge base to another machine works the same way.
