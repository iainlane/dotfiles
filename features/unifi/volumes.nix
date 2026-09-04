# The podman volumes the controller keeps its state in, with the mount point
# each takes inside the container. The container mounts them and the backup
# archives them, so both halves read the same list.
#
# `state` is what a rebuilt controller cannot reproduce: the site
# configuration, the adoption keys of every device, and the mongodb database.
# `/var/log` is listed apart because it holds none of that.
rec {
  state = [
    {
      volume = "unifi-persistent";
      target = "/persistent";
    }
    {
      volume = "unifi-data";
      target = "/data";
    }
    {
      volume = "unifi-srv";
      target = "/srv";
    }
    {
      volume = "unifi-var-lib-unifi";
      target = "/var/lib/unifi";
    }
    {
      volume = "unifi-var-lib-mongodb";
      target = "/var/lib/mongodb";
    }
    {
      volume = "unifi-etc-rabbitmq-ssl";
      target = "/etc/rabbitmq/ssl";
    }
  ];

  logs = [
    {
      volume = "unifi-var-log";
      target = "/var/log";
    }
  ];

  all = state ++ logs;
}
