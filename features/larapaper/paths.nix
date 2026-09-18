# LaraPaper's state locations and listening port. The container feature and the
# backup child both read this file, so the two cannot disagree about a path.
{
  # LaraPaper's HTTP port inside the container. Upstream fixes it, and the
  # image reads no variable to change it.
  containerPort = 8080;

  databaseVolume = "larapaper-database";
  storageVolume = "larapaper-storage";

  databaseDir = "/var/www/html/database/storage";
  databaseFile = "database.sqlite";

  storageDir = "/var/www/html/storage/app/public/images/generated";
}
