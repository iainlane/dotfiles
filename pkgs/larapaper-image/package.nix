{
  lib,
  dockerTools,
  larapaper,
  trmnl-framework,
  trmnl-liquid-cli,
  nginx,
  python3Packages,
  chromium,
  nodejs_24,
  coreutils,
  writeText,
  writeShellApplication,
  makeFontsConf,
  noto-fonts,
  noto-fonts-cjk-sans,
  noto-fonts-cjk-serif,
  noto-fonts-color-emoji,
  open-sans,
  twitter-color-emoji,
  cacert,
}: let
  app = "${larapaper}/share/php/larapaper";
  inherit (larapaper) php;
  libraries = larapaper.webLibraries.sources;
  fonts = makeFontsConf {
    fontDirectories = [
      noto-fonts
      noto-fonts-cjk-sans
      noto-fonts-cjk-serif
      noto-fonts-color-emoji
      open-sans
      twitter-color-emoji
    ];
  };
  fpmConfig = writeText "larapaper-fpm.conf" ''
    [global]
    error_log = /dev/stderr
    daemonize = no
    [www]
    listen = 127.0.0.1:9000
    pm = dynamic
    pm.max_children = 8
    pm.start_servers = 2
    pm.min_spare_servers = 2
    pm.max_spare_servers = 4
    clear_env = no
    catch_workers_output = yes
    php_admin_value[memory_limit] = 256M
    php_admin_value[max_execution_time] = 120
  '';
  nginxConfig = writeText "larapaper-nginx.conf" ''
    pid /tmp/nginx.pid;
    error_log /dev/stderr;
    events {}
    http {
      include ${nginx}/conf/mime.types;
      access_log /dev/stdout;
      client_body_temp_path /tmp/nginx-client;
      proxy_temp_path /tmp/nginx-proxy;
      fastcgi_temp_path /tmp/nginx-fastcgi;
      uwsgi_temp_path /tmp/nginx-uwsgi;
      scgi_temp_path /tmp/nginx-scgi;
      server {
        listen 8080;
        root ${app}/public;
        index index.php;
        client_max_body_size 100m;
        location / { try_files $uri $uri/ /index.php?$query_string; }
        location = /index.php {
          include ${nginx}/conf/fastcgi_params;
          fastcgi_param SCRIPT_FILENAME ${app}/public/index.php;
          fastcgi_pass 127.0.0.1:9000;
          fastcgi_read_timeout 120s;
        }
        location ~ ^/(build/assets|fonts)/.*\.(woff2?|ttf|otf)$ {
          add_header Access-Control-Allow-Origin "*" always;
          try_files $uri =404;
        }
        location ~ \.php$ { return 404; }
        location ~ /\. { deny all; }
      }
    }
  '';
  supervisorConfig = writeText "larapaper-supervisor.conf" ''
    [supervisord]
    nodaemon=true
    logfile=/dev/null
    pidfile=/tmp/supervisord.pid
    [program:php-fpm]
    autorestart=true
    stdout_logfile=/dev/stdout
    stdout_logfile_maxbytes=0
    stderr_logfile=/dev/stderr
    stderr_logfile_maxbytes=0
    stopasgroup=true
    killasgroup=true
    command=${php}/bin/php-fpm -F -y ${fpmConfig}
    [program:nginx]
    autorestart=true
    stdout_logfile=/dev/stdout
    stdout_logfile_maxbytes=0
    stderr_logfile=/dev/stderr
    stderr_logfile_maxbytes=0
    stopasgroup=true
    killasgroup=true
    command=${nginx}/bin/nginx -e stderr -c ${nginxConfig} -g "daemon off;"
    stopsignal=QUIT
    [program:queue]
    autorestart=true
    stdout_logfile=/dev/stdout
    stdout_logfile_maxbytes=0
    stderr_logfile=/dev/stderr
    stderr_logfile_maxbytes=0
    stopasgroup=true
    killasgroup=true
    command=${php}/bin/php ${app}/artisan queue:work --tries=3
    stopwaitsecs=150
    [program:scheduler]
    autorestart=true
    stdout_logfile=/dev/stdout
    stdout_logfile_maxbytes=0
    stderr_logfile=/dev/stderr
    stderr_logfile_maxbytes=0
    stopasgroup=true
    killasgroup=true
    command=${php}/bin/php ${app}/artisan schedule:work
    [group:larapaper]
    programs=php-fpm,nginx,queue,scheduler
  '';
  entrypoint = writeShellApplication {
    name = "larapaper-start";
    runtimeInputs = [coreutils php nodejs_24 trmnl-liquid-cli];
    text = ''
      : "''${APP_KEY:?APP_KEY must be supplied at runtime}"
      export APP_URL="''${APP_URL:-http://localhost:8080}"
      asset_base="''${APP_URL%/}"
      export TRMNL_BLADE_FRAMEWORK_BASE_URL="$asset_base"
      export TRMNL_BLADE_FRAMEWORK_VERSION=${trmnl-framework.version}
      export TRMNL_BLADE_FRAMEWORK_JS_URL="$asset_base/js/${trmnl-framework.version}/plugins.js"
      export TRMNL_BLADE_HIGHCHARTS_JS_URL="$asset_base/js/highcharts/${libraries.highcharts.version}/highcharts.js"
      export TRMNL_BLADE_HIGHCHARTS_PATTERN_FILL_URL="$asset_base/js/highcharts/${libraries.highcharts.version}/pattern-fill.js"
      export TRMNL_BLADE_CHARTKICK_JS_URL="$asset_base/js/chartkick/${libraries.chartkick.version}/chartkick.min.js"
      export TRMNL_BLADE_MAPLIBRE_JS_URL="$asset_base/js/maplibre-gl/${libraries.maplibre-gl.version}/maplibre-gl.js"
      export TRMNL_BLADE_MAPLIBRE_CSS_URL="$asset_base/js/maplibre-gl/${libraries.maplibre-gl.version}/maplibre-gl.css"
      mkdir -p /var/lib/larapaper/{cache,database,storage/app/private,storage/app/public/images/generated,storage/framework/cache/data,storage/framework/sessions,storage/framework/views,storage/logs}
      touch "$DB_DATABASE"
      cd ${app}
      php artisan package:discover --ansi
      php artisan config:cache
      php artisan migrate --force
      exec ${python3Packages.supervisor}/bin/supervisord -c ${supervisorConfig}
    '';
  };
in
  dockerTools.buildLayeredImage {
    name = "larapaper";
    contents = [dockerTools.caCertificates dockerTools.binSh coreutils];
    extraCommands = ''
      mkdir -p etc var/lib/larapaper/database var/lib/larapaper/storage/app/public/images/generated tmp var/www
      chmod 1777 tmp
      ln -s ${app} var/www/html
      printf 'root:x:0:0:root:/root:/bin/sh\nwww-data:x:82:82:www-data:/tmp:/bin/sh\n' > etc/passwd
      printf 'root:x:0:\nwww-data:x:82:\n' > etc/group
    '';
    fakeRootCommands = ''
      chown -R 82:82 var/lib/larapaper
    '';
    config = {
      User = "82:82";
      Entrypoint = [(lib.getExe entrypoint)];
      WorkingDir = app;
      ExposedPorts."8080/tcp" = {};
      Env = [
        "APP_ENV=production"
        "APP_DEBUG=false"
        "APP_VERSION=${larapaper.version}"
        "DB_CONNECTION=sqlite"
        "DB_DATABASE=/var/lib/larapaper/database/database.sqlite"
        "QUEUE_CONNECTION=database"
        "CACHE_STORE=database"
        "SESSION_DRIVER=database"
        "LOG_CHANNEL=stderr"
        "PATH=${lib.makeBinPath [php nodejs_24 trmnl-liquid-cli coreutils]}"
        "TRMNL_LIQUID_ENABLED=1"
        "TRMNL_LIQUID_PATH=${lib.getExe trmnl-liquid-cli}"
        "PUPPETEER_DOCKER=true"
        "PUPPETEER_MODE=local"
        "PUPPETEER_SKIP_DOWNLOAD=true"
        "PUPPETEER_EXECUTABLE_PATH=${lib.getExe chromium}"
        "FONTCONFIG_FILE=${fonts}"
        "HOME=/tmp"
        "XDG_CACHE_HOME=/tmp/cache"
        "SSL_CERT_FILE=${cacert}/etc/ssl/certs/ca-bundle.crt"
      ];
    };
    passthru = {inherit larapaper trmnl-framework entrypoint;};
    meta.platforms = lib.platforms.linux;
  }
