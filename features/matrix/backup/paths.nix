# Where the homeserver writes its database backups. The homeserver takes them
# itself, on a path named in its configuration, and the backup feature uploads
# what it finds there, so both halves have to name the same volume and mount
# point.
{
  path = "/var/lib/continuwuity-backup";
  volume = "matrix-backup";
}
