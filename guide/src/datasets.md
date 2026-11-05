# Datasets

Members who read papers publish the results (parses, summaries, vectors) as a dataset; the others
import it instead of reading the papers themselves.

## Storage

A directory or an S3-compatible bucket (Cloudflare R2, AWS S3, Backblaze B2, MinIO). Objects are
content-addressed, so only changes are transferred. Old versions of documents and content are kept,
so the store grows; old builds of the site's parts are pruned.

```toml
[dataset]
role = "publish"                            # or "consume"
stream = "ada"                              # default: your login name
store = "s3"                                # or "dir:/path/to/dataset"
endpoint = "https://<account id>.r2.cloudflarestorage.com"
bucket = "my-group-kb"
prefix = "kb"                               # where in the bucket
content = true                              # pages, studies and notebooks too
credentials = "~/.config/zemi/r2_publish"   # access_key_id and secret_access_key
check_hours = 1                             # how often `zemi` imports what is newer (0: never)
autosync_hours = 0                          # a publisher syncs and publishes this often (0: never)
```

## Streams

Each publisher writes its own stream and imports the others'.

- A member publishes what they read, not what they imported.
- A document shown only to the members of its projects (a codebase, say) is not published.
- If two streams have the same paper, the most complete copy wins, then the newest.
- Content files (pages, studies, notebooks) sync the same way. Conflicting edits are both kept and
  shown on the Configuration page.
- The first publish fixes the dataset's models; members' configs follow them.

## Commands

`zemi publish` (or the Status page, or the `publish` tool) and `zemi pull`.

Member keys on Cloudflare R2:

1. `zemi token issuer` saves a Cloudflare API token that can issue keys.
2. `zemi token create alice --out alice.toml` issues a read-only key (`--write` to publish).
3. The member runs `zemi token add alice.toml`.

`zemi` then imports at startup and every `check_hours`. `zemi token list` and `zemi token revoke`
manage keys.

A dataset holds everything a site is built from. The demo is built from one.
