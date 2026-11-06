# Meilisearch upgrade fixture

`meilisearch-1.55.0.tar.gz` contains a database created by Meilisearch 1.55.0 on
aarch64-darwin. The `upgrade-fixture` index uses `id` as its primary key and
contains this document:

```json
{
  "id": "retained",
  "text": "Search data from the previous engine"
}
```

The startup check extracts the archive into its temporary state directory, then
starts the current packaged service. It verifies the upgrade task, retained
document, pre-upgrade backup and automatic backup retention. No older
Meilisearch package is needed to run the check.

The archive excludes LMDB `lock.mdb` files. LMDB recreates process locks on the
test machine. Archive ownership and timestamps are normalised; directories have
mode `0700` and files have mode `0600`.

To regenerate the fixture with a Meilisearch 1.55.0 binary:

1. Start an empty database with a loopback listener, no master key and analytics
   disabled.
2. Submit a one-element JSON array containing the document above to
   `POST /indexes/upgrade-fixture/documents?primaryKey=id` and wait for the
   indexing task to succeed.
3. Request `POST /snapshots` and wait for the snapshot task to succeed.
4. Repack the snapshot without `lock.mdb` files and normalise archive metadata.

Keep a physical database archive. Importing a JSON dump with the current engine
would create a current-format database and bypass the upgrade.
