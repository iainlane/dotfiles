# The podman volumes the controller keeps its state in, with the mount point
# each takes inside the container.
[
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
  {
    volume = "unifi-var-log";
    target = "/var/log";
  }
]
