# The parts of the database container that the rest of this profile names.
#
# The backup runs `pg_dump` inside the running container, so it needs the same
# Postgres build the image was made from. Defining it once keeps the two in
# step.
{pkgs}: {
  containerName = "agentsview-db";
  port = 5432;

  # Where Postgres puts its socket. The roles step and the backup both connect
  # over it.
  socketDir = "/tmp";

  superuser = "postgres";

  # AgentsView stores the vectors for its semantic search in pgvector, and asks
  # for the extension on every push.
  package = pkgs.postgresql_18.withPackages (p: [p.pgvector]);
}
