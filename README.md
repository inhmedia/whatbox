# whatbox

What's on this box? A single bash script that snapshots your server stack into markdown. Feed the output into [Claude Code](https://docs.anthropic.com/en/docs/claude-code) so it has full context of your stack from the first message.

## The problem

Every time you SSH into a new box - a client's server, a fresh VPS, a machine you haven't touched in months - the first 20 minutes with Claude Code is the same back-and-forth:

> "What OS is this?" > "What web server?" > "Is there a database?" > "What's in the nginx config?" > "Any Docker containers?" > "What's the cron situation?"

This script answers all of that in one shot.

## Usage

Run from your local machine - streams the script over SSH, saves the output locally:

```bash
ssh user@your-server 'sudo bash -s' < whatbox.sh > whatbox-report.md
```

With a custom SSH port:

```bash
ssh -p 2222 user@your-server 'sudo bash -s' < whatbox.sh > whatbox-report.md
```

Or run directly on the server:

```bash
sudo bash whatbox.sh > whatbox-report.md
```

Then feed the report into Claude Code and start working.

### `--full` mode

Default output is sized for LLM context windows - enough to understand the stack without blowing your token budget. Add `--full` for verbose output including complete schema dumps, full nginx/Apache configs, iptables rules, PHP modules, and more:

```bash
ssh user@your-server 'sudo bash -s -- --full' < whatbox.sh > whatbox-report.md
```

## What it collects

### Always included (default)

| Section | Details |
|---------|---------|
| System | OS, kernel, CPU, memory, disk summary |
| Network | Public IP, interfaces, listening ports, UFW/firewalld status |
| Web servers | Nginx/Apache/Caddy - versions, enabled sites, server names and listen directives |
| SSL | Let's Encrypt cert inventory and expiry |
| Databases | MySQL, PostgreSQL, MongoDB, Redis, SQLite - versions, database list, table names with sizes, users and hosts |
| Runtimes | Node, Python, PHP, Ruby, Go, Java - versions and package managers |
| Docker | Running/stopped containers, images, networks, volumes, compose file locations |
| Process managers | PM2 apps, Supervisor status |
| Cron | System crontabs, user crontabs, systemd timers |
| Users and SSH | Login shells, sudo config, SSH settings, authorized_keys locations |
| App discovery | Web roots, git repos (with remotes/branches), Node/Python apps, .env file locations |
| Security notes | Checks for common issues (root login, password auth, exposed MySQL, missing swap, etc.) |

### Added with `--full`

- Full `mysqldump --no-data` schema dumps for every database
- PostgreSQL `pg_dump --schema-only` output
- SQLite `.schema` dumps
- MySQL per-user `SHOW GRANTS` and privilege details
- `nginx -T` parsed config directives
- Apache vhost details from all config directories, enabled modules
- Full Caddyfile contents
- `iptables -L -n` complete ruleset
- `du -sh /*` disk usage breakdown
- PHP loaded modules

## MySQL authentication

The script tries multiple auth methods automatically:

1. Environment variables (`MYSQL_USER` / `MYSQL_PASS`)
2. `/root/.my.cnf`
3. Unix socket auth as root
4. `debian-sys-maint` via `/etc/mysql/debian.cnf`
5. Credentials from `.env` files in `/var/www/`

To pass credentials explicitly:

```bash
MYSQL_USER=myuser MYSQL_PASS=mypass ssh user@server 'sudo bash -s' < whatbox.sh > whatbox-report.md
```

## Requirements

- Bash 4+
- Root/sudo access (runs without it but output will be incomplete)
- No dependencies to install. Uses standard system tools only.

## Security

The output contains sensitive information - IP addresses, database schemas, user accounts, SSH config, cron jobs, service details. Do not commit it to version control or share it publicly. The script is safe to share. The output is not.

## License

MIT
