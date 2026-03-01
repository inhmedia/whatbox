#!/usr/bin/env bash
# whatbox - What's on this box?
# A single bash script that snapshots your server stack into markdown.
# Designed to feed into Claude Code / LLMs for full server context.
#
# USAGE (run from your LOCAL machine - does everything in one shot):
#
#   ssh user@your-server 'sudo bash -s' < whatbox.sh > whatbox-report.md
#
# With --full for verbose output (schema dumps, iptables, PHP modules, etc.):
#
#   ssh user@your-server 'sudo bash -s -- --full' < whatbox.sh > whatbox-report.md
#
# Or with a custom port:
#
#   ssh -p 2222 user@your-server 'sudo bash -s' < whatbox.sh > whatbox-report.md
#
# This streams the script over stdin, runs it remotely, and saves the
# markdown output directly to your local machine. Nothing is left on the server.
#
# You can also run it directly on the server if you prefer:
#
#   sudo bash whatbox.sh > whatbox-report.md
#   sudo bash whatbox.sh --full > whatbox-report.md
#
# MySQL credentials (optional - needed if root doesn't have socket auth):
#
#   ssh root@your-server 'bash -s' < server-id.sh > server-report.md  # will try socket auth
#   MYSQL_USER=myuser MYSQL_PASS=mypass ssh root@your-server 'bash -s' < server-id.sh > server-report.md
#
# Or on the server directly:
#
#   MYSQL_USER=myuser MYSQL_PASS=mypass bash server-id.sh > server-report.md

set +e  # Don't exit on errors - many commands are expected to fail on any given system

# --- Flag parsing ---
FULL_MODE=false
for arg in "$@"; do
  case "$arg" in
    --full) FULL_MODE=true ;;
    --help|-h)
      echo "Usage: whatbox [--full]"
      echo ""
      echo "What's on this box? Generates a markdown snapshot of your server stack."
      echo "Default output is optimized for feeding into Claude Code / LLMs."
      echo ""
      echo "  --full    Include verbose details (full schema dumps, nginx -T,"
      echo "            iptables rules, PHP modules, disk usage breakdown)"
      echo ""
      echo "Typical workflow:"
      echo "  ssh user@server 'sudo bash -s' < whatbox.sh > whatbox-report.md"
      echo "  # Then paste or pipe into Claude Code for full server context"
      exit 0
      ;;
  esac
done

# --- MySQL auth helper ---
# Tries multiple auth methods in order:
#   1. Env vars (MYSQL_USER / MYSQL_PASS)
#   2. /root/.my.cnf (if it exists, mysql reads it automatically)
#   3. debian-sys-maint creds from /etc/mysql/debian.cnf
#   4. Socket auth as root (no password)
MYSQL_AUTH_ARGS=()
_mysql_auth_resolved=false

resolve_mysql_auth() {
  if $_mysql_auth_resolved; then return; fi
  _mysql_auth_resolved=true

  # Method 1: explicit env vars
  if [[ -n "${MYSQL_USER:-}" ]]; then
    MYSQL_AUTH_ARGS+=(-u "$MYSQL_USER")
    [[ -n "${MYSQL_PASS:-}" ]] && MYSQL_AUTH_ARGS+=(-p"$MYSQL_PASS")
    return
  fi

  # Method 2: /root/.my.cnf exists — mysql will use it automatically
  if [[ -f /root/.my.cnf ]]; then
    return
  fi

  # Method 3: socket auth as root (works on many Ubuntu/Debian installs)
  # Try without ANY args first — mysql will use unix socket as current user
  if mysql -e "SELECT 1;" &>/dev/null; then
    return
  fi
  # Then try explicit -u root
  if mysql -u root -e "SELECT 1;" &>/dev/null; then
    MYSQL_AUTH_ARGS+=(-u root)
    return
  fi

  # Method 4: debian-sys-maint via --defaults-file (most reliable)
  if [[ -f /etc/mysql/debian.cnf ]]; then
    if mysql --defaults-file=/etc/mysql/debian.cnf -e "SELECT 1;" &>/dev/null; then
      MYSQL_AUTH_ARGS+=(--defaults-file=/etc/mysql/debian.cnf)
      >&2 echo "  MySQL: connected via debian-sys-maint"
      return
    fi
  fi

  # Method 5: check .env files for DB creds
  for envfile in /var/www/*/.env /var/www/*/*/.env /var/www/*/*/*/.env; do
    if [[ -f "$envfile" ]]; then
      local db_user db_pass

      # Try separate USER/PASS variables
      db_user=$(grep -m1 -iE '^(DB_USER|MYSQL_USER|DATABASE_USER)=' "$envfile" 2>/dev/null | cut -d= -f2- | tr -d '"'"'")
      db_pass=$(grep -m1 -iE '^(DB_PASS|DB_PASSWORD|MYSQL_PASS|MYSQL_PASSWORD|DATABASE_PASSWORD)=' "$envfile" 2>/dev/null | cut -d= -f2- | tr -d '"'"'")

      # Try connection URL format: mysql://user:pass@host/db or mysql+driver://user:pass@host/db
      if [[ -z "$db_user" ]]; then
        local db_url
        db_url=$(grep -m1 -iE '^(DATABASE_URL|DB_URL|MYSQL_URL|SQLALCHEMY_DATABASE_URI)=' "$envfile" 2>/dev/null | cut -d= -f2- | tr -d '"'"'")
        if echo "$db_url" | grep -qiE 'mysql'; then
          # Parse user:pass from mysql://user:pass@host or mysql+pymysql://user:pass@host
          db_user=$(echo "$db_url" | sed -E 's|.*://([^:]+):.*|\1|')
          db_pass=$(echo "$db_url" | sed -E 's|.*://[^:]+:([^@]+)@.*|\1|')
        fi
      fi

      if [[ -n "$db_user" && -n "$db_pass" ]]; then
        # Extract database name from URL if available (mysql://user:pass@host/dbname)
        local db_name=""
        if [[ -n "${db_url:-}" ]]; then
          db_name=$(echo "$db_url" | sed -E 's|.*@[^/]+/([^?]+).*|\1|')
        fi
        # Test with specific database first, then without
        if [[ -n "$db_name" ]] && mysql -u "$db_user" -p"$db_pass" "$db_name" -e "SELECT 1;" &>/dev/null; then
          MYSQL_AUTH_ARGS+=(-u "$db_user" -p"$db_pass")
          return
        elif mysql -u "$db_user" -p"$db_pass" -e "SELECT 1;" &>/dev/null; then
          MYSQL_AUTH_ARGS+=(-u "$db_user" -p"$db_pass")
          return
        fi
      fi
    fi
  done
}

mysql_cmd() {
  resolve_mysql_auth
  mysql "${MYSQL_AUTH_ARGS[@]}" "$@"
}

mysqldump_cmd() {
  resolve_mysql_auth
  mysqldump "${MYSQL_AUTH_ARGS[@]}" "$@"
}

# --- Helpers ---
md_section() {
  echo ""
  echo "---"
  echo ""
  echo "## $1"
  echo ""
}

md_sub() {
  echo ""
  echo "### $1"
  echo ""
}

code_block_start() {
  echo '```'"${1:-}"
}

code_block_end() {
  echo '```'
}

cmd_exists() {
  command -v "$1" &>/dev/null
}

# Wrap a command's output in a fenced code block
run_in_block() {
  local label="${1:-}"
  shift
  code_block_start "$label"
  "$@" 2>/dev/null || echo "(no output)"
  code_block_end
}

# --- Check for root ---
if [[ $EUID -ne 0 ]]; then
  echo "> **WARNING:** Not running as root. Some information will be incomplete."
  echo "> Re-run with: \`sudo bash $0\`"
  echo ""
fi

# --- Header ---
echo "# whatbox — Server Stack Report"
echo ""
if $FULL_MODE; then
  echo "> **Mode:** Full (verbose — includes schema dumps, detailed configs)"
else
  echo "> **Mode:** Default (optimized for LLM context — run with \`--full\` for verbose output)"
fi
echo ""
echo "| | |"
echo "|---|---|"
echo "| **Generated** | $(date -u '+%Y-%m-%d %H:%M:%S UTC') |"
echo "| **Hostname** | $(hostname 2>/dev/null || echo 'unknown') |"
if [[ -f /etc/os-release ]]; then
  . /etc/os-release
  echo "| **OS** | $PRETTY_NAME |"
else
  echo "| **OS** | $(uname -s) |"
fi
echo "| **Kernel** | $(uname -r) |"
echo "| **Arch** | $(uname -m) |"
echo "| **Uptime** | $(uptime -p 2>/dev/null || uptime) |"

# ==========================================================
# 1. SYSTEM INFO
# ==========================================================
md_section "System Info"

md_sub "CPU"
code_block_start
if [[ -f /proc/cpuinfo ]]; then
  MODEL=$(grep -m1 'model name' /proc/cpuinfo | cut -d: -f2 | xargs)
  CORES=$(nproc 2>/dev/null || grep -c '^processor' /proc/cpuinfo)
  echo "Model: $MODEL"
  echo "Cores: $CORES"
else
  sysctl -n machdep.cpu.brand_string 2>/dev/null || echo "unknown"
fi
code_block_end

md_sub "Memory"
code_block_start
free -h 2>/dev/null || vm_stat 2>/dev/null || echo "unknown"
code_block_end

md_sub "Disk"
code_block_start
df -h --total 2>/dev/null | grep -E '(Filesystem|total|/$)' || df -h 2>/dev/null
code_block_end

if $FULL_MODE; then
  md_sub "Disk Usage (top-level)"
  code_block_start
  du -sh /* 2>/dev/null | sort -rh | head -15
  code_block_end
fi

# ==========================================================
# 2. NETWORK
# ==========================================================
md_section "Network"

md_sub "Public IP"
code_block_start
if cmd_exists curl; then
  curl -s --connect-timeout 5 https://ifconfig.me 2>/dev/null || echo "(could not reach ifconfig.me)"
elif cmd_exists wget; then
  wget -qO- --timeout=5 https://ifconfig.me 2>/dev/null || echo "(could not reach ifconfig.me)"
else
  echo "(no curl or wget)"
fi
code_block_end

md_sub "Network Interfaces"
code_block_start
if cmd_exists ip; then
  ip -brief addr 2>/dev/null
else
  ifconfig 2>/dev/null | grep -E '(^[a-z]|inet )' || true
fi
code_block_end

md_sub "Listening Ports"
code_block_start
if cmd_exists ss; then
  ss -tulnp 2>/dev/null
elif cmd_exists netstat; then
  netstat -tulnp 2>/dev/null
else
  echo "(no ss or netstat)"
fi
code_block_end

md_sub "Firewall"

if $FULL_MODE; then
  echo "**iptables:**"
  code_block_start
  iptables -L -n --line-numbers 2>/dev/null | head -40 || echo "(cannot read iptables)"
  code_block_end
fi

if cmd_exists ufw; then
  echo ""
  echo "**ufw:**"
  code_block_start
  ufw status verbose 2>/dev/null || true
  code_block_end
fi

if cmd_exists firewall-cmd; then
  echo ""
  echo "**firewalld:**"
  code_block_start
  firewall-cmd --list-all 2>/dev/null || true
  code_block_end
fi

# ==========================================================
# 3. WEB SERVERS
# ==========================================================
md_section "Web Servers"

md_sub "Nginx"
if cmd_exists nginx; then
  echo "**Version:** \`$(nginx -v 2>&1)\`"
  echo ""
  echo "**Enabled sites:**"
  code_block_start
  if [[ -d /etc/nginx/sites-enabled ]]; then
    ls -1 /etc/nginx/sites-enabled/ 2>/dev/null
  elif [[ -d /etc/nginx/conf.d ]]; then
    ls -1 /etc/nginx/conf.d/ 2>/dev/null
  fi
  code_block_end

  echo ""
  echo "**Server names & listen directives:**"
  code_block_start nginx
  if [[ -d /etc/nginx/sites-enabled ]]; then
    grep -rh 'server_name\|listen ' /etc/nginx/sites-enabled/ 2>/dev/null | sed 's/^[[:space:]]*//' | sort -u
  elif [[ -d /etc/nginx/conf.d ]]; then
    grep -rh 'server_name\|listen ' /etc/nginx/conf.d/ 2>/dev/null | sed 's/^[[:space:]]*//' | sort -u
  fi
  code_block_end

  if $FULL_MODE; then
    echo ""
    echo "**Key config directives:**"
    code_block_start nginx
    nginx -T 2>/dev/null | grep -E '(server_name|listen|root|proxy_pass|location|upstream)' | sed 's/^[[:space:]]*//' | head -60
    code_block_end
  fi
else
  echo "*Not installed.*"
fi

md_sub "Apache"
if cmd_exists apache2 || cmd_exists httpd; then
  APACHE_BIN=$(command -v apache2 2>/dev/null || command -v httpd 2>/dev/null)
  APACHE_CTL=$(command -v apache2ctl 2>/dev/null || command -v apachectl 2>/dev/null)
  echo "**Version:** \`$($APACHE_BIN -v 2>&1 | head -1)\`"

  echo ""
  echo "**Virtual host summary (parsed):**"
  code_block_start
  $APACHE_CTL -S 2>/dev/null || true
  code_block_end

  echo ""
  echo "**Enabled site configs:**"
  code_block_start
  if [[ -d /etc/apache2/sites-enabled ]]; then
    ls -1 /etc/apache2/sites-enabled/ 2>/dev/null
  fi
  if [[ -d /etc/httpd/conf.d ]]; then
    ls -1 /etc/httpd/conf.d/ 2>/dev/null
  fi
  code_block_end

  if $FULL_MODE; then
    echo ""
    echo "**Virtual host details:**"
    # Search all Apache config locations for vhost directives
    for conf_dir in /etc/apache2/sites-enabled /etc/apache2/sites-available /etc/apache2/conf-enabled /etc/httpd/conf.d; do
      if [[ -d "$conf_dir" ]]; then
        echo ""
        echo "**$conf_dir:**"
        code_block_start apache
        grep -rn 'ServerName\|ServerAlias\|DocumentRoot\|ProxyPass\|<VirtualHost\|</VirtualHost' "$conf_dir" 2>/dev/null | sed 's/^[[:space:]]*//' || true
        code_block_end
      fi
    done

    # Also check the main config and any includes
    echo ""
    echo "**Main config includes:**"
    code_block_start apache
    grep -rn 'Include\|ServerName\|DocumentRoot' /etc/apache2/apache2.conf 2>/dev/null | grep -v '^#' || true
    grep -rn 'Include\|ServerName\|DocumentRoot' /etc/httpd/conf/httpd.conf 2>/dev/null | grep -v '^#' || true
    code_block_end

    echo ""
    echo "**Enabled modules:**"
    code_block_start
    $APACHE_CTL -M 2>/dev/null | sort || $APACHE_BIN -M 2>/dev/null | sort || true
    code_block_end
  fi
else
  echo "*Not installed.*"
fi

md_sub "Caddy"
if cmd_exists caddy; then
  echo "**Version:** \`$(caddy version 2>&1)\`"
  if $FULL_MODE && [[ -f /etc/caddy/Caddyfile ]]; then
    echo ""
    echo "**Caddyfile:**"
    code_block_start
    cat /etc/caddy/Caddyfile 2>/dev/null
    code_block_end
  fi
else
  echo "*Not installed.*"
fi

# ==========================================================
# 4. SSL / TLS CERTIFICATES
# ==========================================================
md_section "SSL / TLS Certificates"

if cmd_exists certbot; then
  code_block_start
  certbot certificates 2>/dev/null || echo "(could not list certs)"
  code_block_end
elif [[ -d /etc/letsencrypt/live ]]; then
  echo "Certbot not in PATH but \`/etc/letsencrypt/live\` exists:"
  code_block_start
  ls /etc/letsencrypt/live/ 2>/dev/null
  code_block_end
else
  echo "*No certbot / no Let's Encrypt certs found.*"
fi

# ==========================================================
# 5. DATABASES
# ==========================================================
md_section "Databases"

md_sub "MySQL / MariaDB"
if cmd_exists mysql; then
  echo "**Version:** \`$(mysql --version 2>&1)\`"

  # Check bind address
  BIND_ADDR=$(grep -rh '^bind-address' /etc/mysql/ 2>/dev/null | tail -1 | awk '{print $NF}')
  echo ""
  echo "**Bind address:** \`${BIND_ADDR:-not set (defaults to 0.0.0.0)}\`"

  echo ""
  echo "**Databases:**"
  code_block_start
  # Get databases from SHOW DATABASES
  MYSQL_DBS=$(mysql_cmd -N -e "SHOW DATABASES;" 2>/dev/null | grep -v -E '^(information_schema|performance_schema|sys|mysql)$')

  # Also discover databases from config files (.env, PHP configs, etc.)
  DISCOVERED_DBS=""
  for envfile in /var/www/*/.env /var/www/*/*/.env /var/www/*/*/*/.env; do
    if [[ -f "$envfile" ]]; then
      db_from_url=$(grep -iE '^(DATABASE_URL|DB_URL|MYSQL_URL|SQLALCHEMY_DATABASE_URI)=' "$envfile" 2>/dev/null | grep -i mysql | sed -E 's|.*@[^/]+/([^?]+).*|\1|' | cut -d= -f2-)
      [[ -n "$db_from_url" ]] && DISCOVERED_DBS+="$db_from_url "
      db_from_var=$(grep -m1 -iE '^(DB_DATABASE|DB_NAME|MYSQL_DATABASE)=' "$envfile" 2>/dev/null | cut -d= -f2- | tr -d '"'"'")
      [[ -n "$db_from_var" ]] && DISCOVERED_DBS+="$db_from_var "
    fi
  done
  # Search PHP files for database names (e.g. $db_name = 'serpsup')
  for phpfile in /var/www/*/config*.php /var/www/*/*/config*.php /var/www/*/db*.php /var/www/*/*/db*.php /var/www/*/*/settings*.php; do
    if [[ -f "$phpfile" ]]; then
      db_from_php=$(grep -iE "(db_name|database|dbname)" "$phpfile" 2>/dev/null | grep -oE "['\"][a-zA-Z0-9_]+['\"]" | tr -d "\"'" | grep -v -iE '^(mysql|localhost|root|utf8|true|false|null|password|username|host|port|name|database|db|db_name|dbname|DB_NAME|DATABASE)$' | head -3)
      [[ -n "$db_from_php" ]] && DISCOVERED_DBS+="$db_from_php "
    fi
  done
  # Search docker-compose files for MYSQL_DATABASE / POSTGRES_DB
  for composefile in /var/www/*/docker-compose.yml /var/www/*/docker-compose.yaml /var/www/*/compose.yml; do
    if [[ -f "$composefile" ]]; then
      db_from_compose=$(grep -iE 'MYSQL_DATABASE|MARIADB_DATABASE' "$composefile" 2>/dev/null | sed 's/.*[=:]\s*//' | tr -d '"'"' ")
      [[ -n "$db_from_compose" ]] && DISCOVERED_DBS+="$db_from_compose "
    fi
  done

  # Merge and deduplicate
  ALL_DBS=$(echo "$MYSQL_DBS $DISCOVERED_DBS" | tr ' ' '\n' | grep -v '^$' | sort -u | tr '\n' ' ')
  MYSQL_DBS="$ALL_DBS"

  if [[ -n "$MYSQL_DBS" ]]; then
    echo "$MYSQL_DBS"
  else
    echo "(could not find any databases)"
  fi
  code_block_end

  echo ""
  echo "**Users & access hosts:**"
  code_block_start
  mysql_cmd -e "SELECT user, host, plugin FROM mysql.user ORDER BY user;" 2>/dev/null || echo "(insufficient privileges to read mysql.user)"
  code_block_end

  if $FULL_MODE; then
    echo ""
    echo "**User privileges:**"
    code_block_start
    mysql_cmd -e "SELECT grantee, privilege_type, table_schema FROM information_schema.schema_privileges ORDER BY grantee, table_schema;" 2>/dev/null || \
    mysql_cmd -e "SELECT CONCAT(user,'@',host) AS account, Super_priv, Grant_priv FROM mysql.user ORDER BY user;" 2>/dev/null || \
    echo "(insufficient privileges)"
    code_block_end

    echo ""
    echo "**Global grants (per user):**"
    code_block_start
    mysql_cmd -N -e "SELECT DISTINCT CONCAT(user,'@',host) FROM mysql.user WHERE user != '' ORDER BY user;" 2>/dev/null | while read -r acct; do
      echo "-- $acct"
      mysql_cmd -e "SHOW GRANTS FOR ${acct};" 2>/dev/null || true
      echo ""
    done
    code_block_end
  fi

  echo ""
  echo "**Schema dump (structure only, no data):**"
  if [[ -n "$MYSQL_DBS" ]]; then
    for db in $MYSQL_DBS; do
      echo ""
      echo "**Database: \`$db\`**"
      echo ""

      # Try main auth first, then find db-specific creds from config files
      DUMP_OK=false
      DB_AUTH_ARGS=("${MYSQL_AUTH_ARGS[@]}")

      if ! mysql "${DB_AUTH_ARGS[@]}" "$db" -e "SELECT 1;" &>/dev/null; then
        # Main auth failed for this db — search config files for creds specific to this database
        for cfgfile in /var/www/*/.env /var/www/*/*/.env /var/www/*/*/*/.env /var/www/*/config*.php /var/www/*/*/config*.php /var/www/*/db*.php /var/www/*/*/db*.php; do
          if [[ -f "$cfgfile" ]] && grep -qi "$db" "$cfgfile" 2>/dev/null; then
            local cfg_user cfg_pass
            if [[ "$cfgfile" == *.php ]]; then
              # PHP: look for user/pass assignments near the db name
              cfg_user=$(grep -iE "(db_user|user|username)" "$cfgfile" 2>/dev/null | grep -oE "['\"][a-zA-Z0-9_]+['\"]" | tr -d "\"'" | grep -v -iE '^(db_user|user|username|root|localhost)$' | head -1)
              cfg_pass=$(grep -iE "(db_pass|password|passwd)" "$cfgfile" 2>/dev/null | grep -oE "['\"][^'\"]+['\"]" | tr -d "\"'" | grep -v -iE '^(db_pass|password|passwd)$' | head -1)
            else
              # .env: look for standard vars
              cfg_user=$(grep -m1 -iE '^(DB_USER|MYSQL_USER|DATABASE_USER)=' "$cfgfile" 2>/dev/null | cut -d= -f2- | tr -d '"'"'")
              cfg_pass=$(grep -m1 -iE '^(DB_PASS|DB_PASSWORD|MYSQL_PASS|MYSQL_PASSWORD|DATABASE_PASSWORD)=' "$cfgfile" 2>/dev/null | cut -d= -f2- | tr -d '"'"'")
              # Also try connection URL
              if [[ -z "$cfg_user" ]]; then
                local cfg_url
                cfg_url=$(grep -m1 -iE '^(DATABASE_URL|DB_URL)=' "$cfgfile" 2>/dev/null | cut -d= -f2- | tr -d '"'"'")
                if echo "$cfg_url" | grep -qiE 'mysql'; then
                  cfg_user=$(echo "$cfg_url" | sed -E 's|.*://([^:]+):.*|\1|')
                  cfg_pass=$(echo "$cfg_url" | sed -E 's|.*://[^:]+:([^@]+)@.*|\1|')
                fi
              fi
            fi
            if [[ -n "$cfg_user" && -n "$cfg_pass" ]] && mysql -u "$cfg_user" -p"$cfg_pass" "$db" -e "SELECT 1;" &>/dev/null; then
              DB_AUTH_ARGS=(-u "$cfg_user" -p"$cfg_pass")
              >&2 echo "  MySQL: connected to $db via creds from $cfgfile"
              break
            fi
          fi
        done
      fi

      echo "Tables:"
      code_block_start
      mysql "${DB_AUTH_ARGS[@]}" "$db" -e "SELECT table_name, engine, table_rows, ROUND(data_length/1024/1024,2) AS size_mb FROM information_schema.tables WHERE table_schema='$db' ORDER BY table_name;" 2>/dev/null || \
      mysql "${DB_AUTH_ARGS[@]}" "$db" -e "SHOW TABLES;" 2>/dev/null || \
      echo "(could not access $db - no working credentials found)"
      code_block_end
      if $FULL_MODE; then
        echo ""
        echo "Full schema:"
        code_block_start sql
        mysqldump "${DB_AUTH_ARGS[@]}" --no-data --skip-comments --compact "$db" 2>/dev/null || echo "(could not dump schema for $db)"
        code_block_end
      fi
    done
  else
    echo "*No databases found.*"
  fi
else
  echo "*Not installed.*"
fi

md_sub "PostgreSQL"
if cmd_exists psql; then
  echo "**Version:** \`$(psql --version 2>&1)\`"
  echo ""
  echo "**Databases:**"
  code_block_start
  sudo -u postgres psql -l 2>/dev/null || psql -l 2>/dev/null || echo "(could not connect)"
  code_block_end

  echo ""
  echo "**Schema dump (structure only):**"
  PG_DBS=$(sudo -u postgres psql -t -c "SELECT datname FROM pg_database WHERE datistemplate = false AND datname != 'postgres';" 2>/dev/null | xargs)
  if [[ -n "$PG_DBS" ]]; then
    for db in $PG_DBS; do
      echo ""
      echo "**Database: \`$db\`**"
      echo ""
      echo "Tables:"
      code_block_start
      sudo -u postgres psql -d "$db" -c "SELECT schemaname, tablename, pg_size_pretty(pg_total_relation_size(schemaname||'.'||tablename)) AS size FROM pg_tables WHERE schemaname NOT IN ('pg_catalog','information_schema') ORDER BY tablename;" 2>/dev/null || true
      code_block_end
      if $FULL_MODE; then
        echo ""
        echo "Full schema:"
        code_block_start sql
        sudo -u postgres pg_dump --schema-only --no-owner --no-privileges "$db" 2>/dev/null || echo "(could not dump schema for $db)"
        code_block_end
      fi
    done
  fi
else
  echo "*Not installed.*"
fi

md_sub "PostgreSQL (Docker)"
# Check for Postgres containers and dump their schemas too
if cmd_exists docker; then
  PG_CONTAINERS=$(docker ps --format '{{.Names}} {{.Image}}' 2>/dev/null | grep -i postgres | awk '{print $1}')
  if [[ -n "$PG_CONTAINERS" ]]; then
    for container in $PG_CONTAINERS; do
      echo ""
      echo "**Container: \`$container\`**"
      PG_USER=$(docker exec "$container" bash -c 'echo $POSTGRES_USER' 2>/dev/null)
      PG_USER="${PG_USER:-postgres}"
      echo ""
      echo "Databases:"
      code_block_start
      docker exec "$container" psql -U "$PG_USER" -l 2>/dev/null || echo "(could not connect)"
      code_block_end

      DOCKER_PG_DBS=$(docker exec "$container" psql -U "$PG_USER" -t -c "SELECT datname FROM pg_database WHERE datistemplate = false AND datname != 'postgres';" 2>/dev/null | xargs)
      if [[ -n "$DOCKER_PG_DBS" ]]; then
        for db in $DOCKER_PG_DBS; do
          echo ""
          echo "**Database: \`$db\`**"
          echo ""
          echo "Tables:"
          code_block_start
          docker exec "$container" psql -U "$PG_USER" -d "$db" -c "SELECT schemaname, tablename, pg_size_pretty(pg_total_relation_size(schemaname||'.'||tablename)) AS size FROM pg_tables WHERE schemaname NOT IN ('pg_catalog','information_schema') ORDER BY tablename;" 2>/dev/null || true
          code_block_end
          if $FULL_MODE; then
            echo ""
            echo "Full schema:"
            code_block_start sql
            docker exec "$container" pg_dump -U "$PG_USER" --schema-only --no-owner --no-privileges "$db" 2>/dev/null || echo "(could not dump schema for $db)"
            code_block_end
          fi
        done
      fi
    done
  else
    echo "*No PostgreSQL containers running.*"
  fi
fi

md_sub "MongoDB"
if cmd_exists mongosh || cmd_exists mongo; then
  MONGO_BIN=$(command -v mongosh 2>/dev/null || command -v mongo 2>/dev/null)
  echo "**Version:** \`$($MONGO_BIN --version 2>&1 | head -1)\`"
  echo ""
  echo "**Databases:**"
  code_block_start
  $MONGO_BIN --quiet --eval "db.adminCommand('listDatabases').databases.forEach(d => print(d.name))" 2>/dev/null || echo "(could not connect)"
  code_block_end
else
  echo "*Not installed.*"
fi

md_sub "Redis"
if cmd_exists redis-cli; then
  echo "**Version:** \`$(redis-cli --version 2>&1)\`"
  echo ""
  code_block_start
  redis-cli INFO server 2>/dev/null | grep -E '(redis_version|tcp_port|uptime|connected_clients)' || echo "(could not connect)"
  echo ""
  echo "# Keyspace"
  redis-cli INFO keyspace 2>/dev/null || true
  code_block_end
else
  echo "*Not installed.*"
fi

md_sub "SQLite Databases"
if cmd_exists sqlite3; then
  # Find SQLite files, exclude system/cache directories
  SQLITE_FILES=$(find /var/www /home /srv /opt -name '*.sqlite' -o -name '*.sqlite3' -o -name '*.db' 2>/dev/null | grep -v '/var/cache/' | grep -v '/node_modules/' | head -20)
  if [[ -n "$SQLITE_FILES" ]]; then
    echo "**Databases found:**"
    code_block_start
    echo "$SQLITE_FILES"
    code_block_end

    echo "$SQLITE_FILES" | while read -r dbfile; do
      # Verify it's actually a SQLite file
      if sqlite3 "$dbfile" "SELECT 1;" &>/dev/null; then
        SIZE=$(du -h "$dbfile" 2>/dev/null | awk '{print $1}')
        echo ""
        echo "**\`$dbfile\`** ($SIZE)"
        echo ""
        echo "Tables:"
        code_block_start
        sqlite3 "$dbfile" ".tables" 2>/dev/null || true
        code_block_end
        if $FULL_MODE; then
          echo ""
          echo "Schema:"
          code_block_start sql
          sqlite3 "$dbfile" ".schema" 2>/dev/null || true
          code_block_end
        fi
      fi
    done
  else
    echo "*No SQLite databases found in app directories.*"
  fi
else
  # No sqlite3 binary - just list the files
  echo "**Databases found** (sqlite3 not installed, cannot dump schema):"
  code_block_start
  find /var/www /home /srv /opt -name '*.sqlite' -o -name '*.sqlite3' -o -name '*.db' 2>/dev/null | grep -v '/var/cache/' | grep -v '/node_modules/' | head -20 || echo "(none found)"
  code_block_end
fi

# ==========================================================
# 6. RUNTIMES & LANGUAGES
# ==========================================================
md_section "Runtimes & Languages"

echo "| Runtime | Version |"
echo "|---------|---------|"
for rt in node python3 python php ruby go java javac rustc dotnet perl; do
  if cmd_exists "$rt"; then
    VER=$("$rt" --version 2>&1 | head -1)
    echo "| \`$rt\` | $VER |"
  fi
done

md_sub "Node.js Details"
if cmd_exists node; then
  echo "| Tool | Version |"
  echo "|------|---------|"
  echo "| npm | $(npm --version 2>/dev/null || echo 'not found') |"
  echo "| yarn | $(yarn --version 2>/dev/null || echo 'not found') |"
  echo "| pnpm | $(pnpm --version 2>/dev/null || echo 'not found') |"
  echo ""
  echo "**Global npm packages:**"
  code_block_start
  npm list -g --depth=0 2>/dev/null || true
  code_block_end
else
  echo "*Node.js not installed.*"
fi

md_sub "Python Details"
PYTHON_BIN=$(command -v python3 2>/dev/null || command -v python 2>/dev/null)
if [[ -n "${PYTHON_BIN:-}" ]]; then
  echo "**pip:** \`$(pip3 --version 2>/dev/null || pip --version 2>/dev/null || echo 'not found')\`"
  echo ""
  echo "**Virtual environments found:**"
  code_block_start
  find /home /var /srv /opt -maxdepth 4 -name 'pyvenv.cfg' 2>/dev/null | head -10 || echo "(none)"
  code_block_end
else
  echo "*Python not installed.*"
fi

md_sub "PHP Details"
if cmd_exists php; then
  echo "**Composer:** \`$(composer --version 2>/dev/null || echo 'not found')\`"
  if $FULL_MODE; then
    echo ""
    echo "**Loaded modules:**"
    code_block_start
    php -m 2>/dev/null | head -30
    code_block_end
  fi
else
  echo "*PHP not installed.*"
fi

# ==========================================================
# 7. SERVICES & PROCESSES
# ==========================================================
md_section "Services & Processes"

md_sub "Running Systemd Services"
if cmd_exists systemctl; then
  code_block_start
  systemctl list-units --type=service --state=running --no-pager 2>/dev/null | head -40
  code_block_end
else
  echo "*No systemd.*"
fi

md_sub "Top Processes by Memory"
code_block_start
ps aux --sort=-%mem 2>/dev/null | head -15 || ps aux | head -15 2>/dev/null
code_block_end

# ==========================================================
# 8. DOCKER & CONTAINERS
# ==========================================================
md_section "Docker & Containers"

md_sub "Docker"
if cmd_exists docker; then
  echo "**Version:** \`$(docker --version 2>&1)\`"
  echo ""
  echo "**Running containers:**"
  code_block_start
  docker ps --format "table {{.ID}}\t{{.Image}}\t{{.Status}}\t{{.Ports}}\t{{.Names}}" 2>/dev/null || echo "(cannot connect to docker daemon)"
  code_block_end

  echo ""
  echo "**All containers (including stopped):**"
  code_block_start
  docker ps -a --format "table {{.ID}}\t{{.Image}}\t{{.Status}}\t{{.Names}}" 2>/dev/null || true
  code_block_end

  echo ""
  echo "**Images:**"
  code_block_start
  docker images --format "table {{.Repository}}\t{{.Tag}}\t{{.Size}}" 2>/dev/null || true
  code_block_end

  echo ""
  echo "**Networks:**"
  code_block_start
  docker network ls 2>/dev/null || true
  code_block_end

  echo ""
  echo "**Volumes:**"
  code_block_start
  docker volume ls 2>/dev/null || true
  code_block_end
else
  echo "*Docker not installed.*"
fi

md_sub "Docker Compose Files"
code_block_start
find / -maxdepth 5 -name 'docker-compose.yml' -o -name 'docker-compose.yaml' -o -name 'compose.yml' -o -name 'compose.yaml' 2>/dev/null | head -15 || echo "(none found)"
code_block_end

md_sub "Podman"
if cmd_exists podman; then
  echo "**Version:** \`$(podman --version 2>&1)\`"
  code_block_start
  podman ps -a 2>/dev/null || true
  code_block_end
else
  echo "*Not installed.*"
fi

# ==========================================================
# 9. PROCESS MANAGERS
# ==========================================================
md_section "Process Managers"

md_sub "PM2"
if cmd_exists pm2; then
  code_block_start
  pm2 list 2>/dev/null || true
  code_block_end
else
  PM2_DUMPS=$(find /home -maxdepth 4 -path '*/.pm2/dump.pm2' 2>/dev/null)
  if [[ -n "$PM2_DUMPS" ]]; then
    echo "PM2 not in PATH but dump files found:"
    code_block_start
    echo "$PM2_DUMPS"
    code_block_end
  else
    echo "*Not installed.*"
  fi
fi

md_sub "Supervisor"
if cmd_exists supervisorctl; then
  code_block_start
  supervisorctl status 2>/dev/null || echo "(could not connect)"
  code_block_end
else
  echo "*Not installed.*"
fi

# ==========================================================
# 10. CRON JOBS
# ==========================================================
md_section "Cron Jobs"

md_sub "System Crontabs"
for f in /etc/crontab /etc/cron.d/*; do
  if [[ -f "$f" ]]; then
    echo "**$f:**"
    code_block_start
    grep -v '^#' "$f" 2>/dev/null | grep -v '^$' || true
    code_block_end
    echo ""
  fi
done

md_sub "User Crontabs"
if [[ -d /var/spool/cron/crontabs ]]; then
  for f in /var/spool/cron/crontabs/*; do
    if [[ -f "$f" ]]; then
      echo "**$(basename "$f"):**"
      code_block_start
      cat "$f" 2>/dev/null
      code_block_end
      echo ""
    fi
  done
elif [[ -d /var/spool/cron ]]; then
  for f in /var/spool/cron/*; do
    if [[ -f "$f" ]]; then
      echo "**$(basename "$f"):**"
      code_block_start
      cat "$f" 2>/dev/null
      code_block_end
      echo ""
    fi
  done
fi

md_sub "Systemd Timers"
code_block_start
systemctl list-timers --all --no-pager 2>/dev/null | head -20 || echo "(no systemd)"
code_block_end

# ==========================================================
# 11. USERS & SSH
# ==========================================================
md_section "Users & SSH"

md_sub "Users with Login Shells"
code_block_start
grep -v '/nologin\|/false' /etc/passwd 2>/dev/null | cut -d: -f1,6,7
code_block_end

md_sub "Sudo Access"
code_block_start
if [[ -f /etc/sudoers ]]; then
  grep -v '^#' /etc/sudoers 2>/dev/null | grep -v '^$' | grep -v '^Defaults' || true
fi
if [[ -d /etc/sudoers.d ]]; then
  for f in /etc/sudoers.d/*; do
    if [[ -f "$f" ]]; then
      echo "# $f"
      grep -v '^#' "$f" 2>/dev/null | grep -v '^$' || true
    fi
  done
fi
code_block_end

md_sub "SSH Configuration"

echo "| Setting | Value |"
echo "|---------|-------|"
PORT=$(grep -i '^Port ' /etc/ssh/sshd_config 2>/dev/null | awk '{print $2}')
echo "| Port | ${PORT:-22 (default)} |"
PASS_AUTH=$(grep -i '^PasswordAuthentication' /etc/ssh/sshd_config 2>/dev/null | awk '{print $2}')
echo "| PasswordAuthentication | ${PASS_AUTH:-not set} |"
PUBKEY_AUTH=$(grep -i '^PubkeyAuthentication' /etc/ssh/sshd_config 2>/dev/null | awk '{print $2}')
echo "| PubkeyAuthentication | ${PUBKEY_AUTH:-not set} |"
PERMIT_ROOT=$(grep -i '^PermitRootLogin' /etc/ssh/sshd_config 2>/dev/null | awk '{print $2}')
echo "| PermitRootLogin | ${PERMIT_ROOT:-not set} |"

echo ""
echo "**Authorized keys files:**"
code_block_start
find /home /root -name 'authorized_keys' 2>/dev/null || echo "(none found)"
code_block_end

# ==========================================================
# 12. INSTALLED PACKAGES
# ==========================================================
md_section "Installed Packages"

if cmd_exists apt; then
  echo "**Package manager:** apt (Debian/Ubuntu)"
  echo ""
  echo "**Total installed:** $(dpkg -l 2>/dev/null | grep '^ii' | wc -l)"
  echo ""
  echo "**Manually installed (likely relevant):**"
  code_block_start
  apt-mark showmanual 2>/dev/null | head -50
  code_block_end
elif cmd_exists yum; then
  echo "**Package manager:** yum (RHEL/CentOS)"
  echo ""
  echo "**Total installed:** $(rpm -qa 2>/dev/null | wc -l)"
  echo ""
  echo "**Recently installed:**"
  code_block_start
  rpm -qa --last 2>/dev/null | head -30
  code_block_end
elif cmd_exists dnf; then
  echo "**Package manager:** dnf (Fedora)"
  echo ""
  echo "**Total installed:** $(rpm -qa 2>/dev/null | wc -l)"
elif cmd_exists pacman; then
  echo "**Package manager:** pacman (Arch)"
  echo ""
  echo "**Total installed:** $(pacman -Q 2>/dev/null | wc -l)"
fi

if cmd_exists snap; then
  echo ""
  echo "**Snap packages:**"
  code_block_start
  snap list 2>/dev/null || true
  code_block_end
fi

# ==========================================================
# 13. APPLICATION DISCOVERY
# ==========================================================
md_section "Application Discovery"

md_sub "Web App Directories"
for dir in /var/www /srv/www /home/*/public_html /var/www/html /opt; do
  if [[ -d "$dir" ]]; then
    echo "**$dir:**"
    code_block_start
    ls -la "$dir" 2>/dev/null
    code_block_end
    echo ""
  fi
done

md_sub "Git Repositories"
code_block_start
find /var/www /srv /home /opt -maxdepth 4 -name '.git' -type d 2>/dev/null | while read -r gitdir; do
  REPO_DIR=$(dirname "$gitdir")
  REMOTE=$(git -C "$REPO_DIR" remote get-url origin 2>/dev/null || echo "(no remote)")
  BRANCH=$(git -C "$REPO_DIR" branch --show-current 2>/dev/null || echo "unknown")
  echo "$REPO_DIR  [branch: $BRANCH]  remote: $REMOTE"
done
code_block_end

md_sub "Node Apps (package.json)"
code_block_start
find /var/www /srv /home /opt -maxdepth 4 -name 'package.json' -not -path '*/node_modules/*' 2>/dev/null | while read -r pj; do
  DIR=$(dirname "$pj")
  NAME=$(grep -o '"name"[[:space:]]*:[[:space:]]*"[^"]*"' "$pj" 2>/dev/null | head -1 | cut -d'"' -f4)
  echo "$DIR  ($NAME)"
done
code_block_end

md_sub "Python Apps"
code_block_start
find /var/www /srv /home /opt -maxdepth 4 \( -name 'requirements.txt' -o -name 'pyproject.toml' \) -not -path '*/venv/*' -not -path '*/.venv/*' 2>/dev/null || echo "(none found)"
code_block_end

md_sub ".env Files (locations only - may contain secrets)"
code_block_start
find /var/www /srv /home /opt -maxdepth 4 -name '.env' 2>/dev/null || echo "(none found)"
code_block_end

md_sub ".htpasswd Files (password-protected directories)"
code_block_start
find /etc /var/www /srv /home -maxdepth 5 -name '.htpasswd' 2>/dev/null | while read -r f; do
  echo "$f ($(wc -l < "$f") users)"
done
code_block_end

# ==========================================================
# 14. QUICK SUMMARY
# ==========================================================
# ==========================================================
# 15. SECURITY NOTES
# ==========================================================
md_section "Security Notes"

echo "Automated checks — not exhaustive, just the obvious stuff."
echo ""

# SSH checks
PERMIT_ROOT=$(grep -i '^PermitRootLogin' /etc/ssh/sshd_config 2>/dev/null | awk '{print $2}')
PASS_AUTH=$(grep -i '^PasswordAuthentication' /etc/ssh/sshd_config 2>/dev/null | awk '{print $2}')
if [[ "$PERMIT_ROOT" == "yes" || -z "$PERMIT_ROOT" ]]; then
  echo "- **PermitRootLogin** is \`${PERMIT_ROOT:-not set (defaults to yes)}\` — consider disabling"
fi
if [[ "$PASS_AUTH" != "no" ]]; then
  echo "- **PasswordAuthentication** is \`${PASS_AUTH:-not set (defaults to yes)}\` — consider disabling in favor of key-only"
fi

# Firewall
UFW_STATUS=$(ufw status 2>/dev/null | head -1)
if echo "$UFW_STATUS" | grep -qi inactive; then
  echo "- **UFW is inactive** — no firewall rules beyond Docker's iptables chains"
fi

# MySQL exposed
if cmd_exists mysql; then
  BIND_ADDR=$(grep -rh '^bind-address' /etc/mysql/ 2>/dev/null | tail -1 | awk '{print $NF}')
  if [[ "$BIND_ADDR" == "0.0.0.0" || -z "$BIND_ADDR" ]]; then
    echo "- **MySQL is bound to 0.0.0.0** (port 3306 open to internet)"
    # Check if any user has % host
    WILDCARD_USERS=$(mysql_cmd -N -e "SELECT CONCAT(user,'@',host) FROM mysql.user WHERE host='%' AND user != '';" 2>/dev/null)
    if [[ -n "$WILDCARD_USERS" ]]; then
      echo "  - Users accessible from any host: \`$WILDCARD_USERS\`"
    fi
  fi
fi

# Unattended upgrades
if ! systemctl is-active --quiet unattended-upgrades 2>/dev/null; then
  echo "- **Unattended upgrades** not running — security patches may not auto-install"
fi

# SSL cert expiry warnings (< 30 days)
if cmd_exists certbot; then
  certbot certificates 2>/dev/null | grep -A2 'Certificate Name' | while read -r line; do
    if echo "$line" | grep -q 'VALID:'; then
      DAYS=$(echo "$line" | grep -o '[0-9]* day' | awk '{print $1}')
      CERT_LINE="$line"
      if [[ -n "$DAYS" && "$DAYS" -lt 30 ]]; then
        echo "- **SSL cert expiring soon** ($DAYS days): $CERT_LINE"
      fi
    fi
  done
fi

# Swap
SWAP_TOTAL=$(free -b 2>/dev/null | awk '/Swap/{print $2}')
if [[ "${SWAP_TOTAL:-0}" -eq 0 ]]; then
  echo "- **No swap configured** — OOM killer will terminate processes if memory is exhausted"
fi

echo ""

# ==========================================================
# 16. QUICK SUMMARY
# ==========================================================
md_section "Quick Summary"

PUBLIC_IP=$(curl -s --connect-timeout 3 https://ifconfig.me 2>/dev/null || echo 'unknown')

echo "| Category | Details |"
echo "|----------|---------|"
echo "| **OS** | ${PRETTY_NAME:-$(uname -s)} |"
echo "| **Kernel** | $(uname -r) |"
echo "| **Hostname** | $(hostname 2>/dev/null) |"
echo "| **Public IP** | $PUBLIC_IP |"

WEB=""
cmd_exists nginx && WEB+="nginx "
cmd_exists apache2 && WEB+="apache2 "
cmd_exists httpd && WEB+="httpd "
cmd_exists caddy && WEB+="caddy "
echo "| **Web Server** | ${WEB:-none detected} |"

DB=""
cmd_exists mysql && DB+="mysql "
cmd_exists psql && DB+="postgresql "
(cmd_exists mongosh || cmd_exists mongo) && DB+="mongodb "
cmd_exists redis-cli && DB+="redis "
echo "| **Databases** | ${DB:-none detected} |"

RT=""
cmd_exists node && RT+="node($(node -v 2>/dev/null)) "
cmd_exists python3 && RT+="python3($(python3 -V 2>&1 | awk '{print $2}')) "
cmd_exists php && RT+="php($(php -v 2>/dev/null | head -1 | awk '{print $2}')) "
cmd_exists ruby && RT+="ruby($(ruby -v 2>/dev/null | awk '{print $2}')) "
cmd_exists go && RT+="go($(go version 2>/dev/null | awk '{print $3}')) "
cmd_exists java && RT+="java "
echo "| **Runtimes** | ${RT:-none detected} |"

if cmd_exists docker; then
  RUNNING=$(docker ps -q 2>/dev/null | wc -l | xargs)
  TOTAL=$(docker ps -aq 2>/dev/null | wc -l | xargs)
  echo "| **Docker** | $RUNNING running / $TOTAL total containers |"
else
  echo "| **Docker** | not installed |"
fi

if cmd_exists pm2; then
  PM2_COUNT=$(pm2 jlist 2>/dev/null | python3 -c "import sys,json; apps=json.load(sys.stdin); print(f'{len(apps)} app(s)')" 2>/dev/null || echo "installed")
  echo "| **PM2** | $PM2_COUNT |"
fi

echo ""
echo "---"
echo ""
echo "*Report complete. $(date -u '+%Y-%m-%d %H:%M:%S UTC')*"

# Print status to stderr so it doesn't pollute the markdown on stdout
>&2 echo ""
>&2 echo "Done. Report written to stdout."
>&2 echo "If you redirected to a file, open it in any markdown viewer."
