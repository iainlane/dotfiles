# LaraPaper's state locations and listening port. The container feature and the
# backup child both read this file, so the two cannot disagree about a path.
{
  containerPort = 8080;

  databaseVolume = "larapaper-database";
  storageVolume = "larapaper-storage";

  databaseDir = "/var/lib/larapaper/database";
  databaseFile = "database.sqlite";

  storageDir = "/var/lib/larapaper/storage/app/public/images/generated";
}
