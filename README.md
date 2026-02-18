# swrmgr

Multi-tenant Docker Swarm management toolkit with a plugin system.

Manage the full lifecycle of isolated customer stacks — provisioning, secrets, backups, networking, DNS, IAM — from a single CLI. Extend with plugins to add credential managers, monitoring, analytics, or any business-specific logic.

## How it works

Each customer gets an isolated stack deployed on Docker Swarm with its own overlay network, database, and secrets. The core toolkit handles orchestration. Plugins handle everything else.

```
swrmgr <tower> <function> [arguments...]
```

**Core towers:** `stack`, `system`, `aws`

**Plugin towers:** Anything you add — `traefik`, `bitwarden`, `metrics`, or your own.

## Quick start

```bash
git clone https://github.com/your-org/swrmgr.git
cd swrmgr
./install.sh
```

The installer prompts for your AWS account, domain, S3 bucket, and SSH key. These go into `/etc/environment` and are sourced on every invocation.

```bash
# Create a customer stack
swrmgr stack create acme-corp

# Deploy / update
swrmgr stack up acme-corp

# Backup
swrmgr stack backup-create acme-corp

# Bring everything up
swrmgr system up
```

## Architecture

```
                    ALB (TLS termination)
                           │
                      ┌────┴────┐
                      │ Traefik │ (plugin)
                      └────┬────┘
                           │
              ┌────────────┼────────────┐
              │            │            │
         ┌────┴────┐ ┌────┴────┐ ┌────┴────┐
         │ Stack A │ │ Stack B │ │ Stack N │
         └────┬────┘ └────┬────┘ └────┬────┘
              │
     Your services (defined in etc/stack.yml)
              │
        ┌─────┴─────┐
        │  Database  │ (pinned to node)
        └────────────┘
```

Each stack runs on an isolated overlay network. Databases are pinned to specific nodes via placement constraints, exposed on dynamically allocated ports. Secrets live in AWS Secrets Manager. DNS is managed via Route53.

## Project structure

```
swrmgr/
├── bin/                    # Core commands
│   ├── swrmgr           # Main dispatcher
│   ├── stack/              # Stack lifecycle
│   ├── system/             # Cluster operations
│   └── aws/                # AWS resource management
├── lib/
│   └── core.sh             # Shared library (hooks, validation, helpers)
├── etc/
│   ├── stack.yml           # Stack template (customize this)
│   ├── iam.json            # IAM policy template
│   └── environment.example # Configuration reference
├── plugins/                # Drop-in plugins
│   ├── traefik/
│   ├── bitwarden/
│   └── metrics/
└── install.sh
```

## Configuration

All configuration lives in `/etc/environment`. See `etc/environment.example` for the full reference.

| Variable | Required | Description |
|----------|----------|-------------|
| `SWRMGR_BASE_DOMAIN` | Yes | Base domain for all stacks (e.g. `example.com`) |
| `SWRMGR_AWS_ACCOUNT_ID` | Yes | AWS account ID |
| `SWRMGR_AWS_REGION` | Yes | AWS region (default: `us-east-1`) |
| `SWRMGR_ECR_REGISTRY` | Yes | ECR registry URL |
| `SWRMGR_S3_BUCKET` | Yes | S3 bucket for customer data |
| `NODE_SSH_KEY_NAME` | Yes | SSH key filename for node access |
| `PUBLIC_DNS_ZONE_ID` | No | Route53 public hosted zone ID |
| `PRIVATE_DNS_ZONE_ID` | No | Route53 private hosted zone ID |
| `PRIVATE_DNS_ZONE_NAME` | No | Private DNS zone name |
| `SWRMGR_MAX_PARALLEL` | No | Max concurrent stack deploys (default: 10) |
| `SWRMGR_CREATE_WAIT` | No | Seconds to wait after stack create (default: 120) |
| `SWRMGR_REQUIRED_ENV_KEYS` | No | Space-separated list of required .env keys |
| `SWRMGR_SHARED_ENV_FILTER` | No | Pipe-separated regex for keys to strip before saving |

## Customizing your stack

Edit `etc/stack.yml` to define your application's services. Use `${VARIABLE}` syntax — the toolkit uses `envsubst` for substitution at deploy time.

Available variables:

| Variable | Source |
|----------|--------|
| `${stack}` | Stack name |
| `${SWRMGR_BASE_DOMAIN}` | Your base domain |
| `${SWRMGR_ECR_REGISTRY}` | ECR registry URL |
| `${DATABASE_NODE}` | Node hostname for database placement |
| `${DATABASE_EXPOSE_PORT}` | Allocated port for database |
| `${IMG_TAG}` | Image tag (default: `stable`) |
| `${AWSLOG_GROUP}` | CloudWatch log group name |
| Any key from `.env` | Sourced before template rendering |

## Stack naming rules

Stack names must match `^[a-z0-9][a-z0-9-]{1,61}[a-z0-9]$`:

- Lowercase letters, numbers, and hyphens only
- Must start and end with a letter or number
- 3 to 63 characters

This constraint ensures names are safe across file paths, Docker, S3, IAM, and DNS.

---

## Core commands

### Stack lifecycle

```bash
swrmgr stack create <name>       # Full provisioning pipeline
swrmgr stack up <name>           # Deploy / update
swrmgr stack down <name>         # Stop (preserves data)
swrmgr stack delete <name>       # Permanent destruction (interactive confirm)
swrmgr stack init <name>         # Initialize without deploying
```

### Environment management

```bash
swrmgr stack env-retrieve <name>    # Pull from Secrets Manager
swrmgr stack env-save <name>        # Validate and push to Secrets Manager
swrmgr stack env-get <name> <key>   # Read a single value
swrmgr stack env-test <name>        # Validate required keys
```

### Backups

```bash
swrmgr stack backup-create <name> [hold]     # Backup to S3
swrmgr stack backup-restore <name> [node]    # Restore from backup
```

### Connectivity

```bash
swrmgr stack connect <name> <service>        # Interactive shell
swrmgr stack node <name> <service>           # Which node is it on?
swrmgr stack container <name> <service>      # Container ID
```

### System operations

```bash
swrmgr system up                # Start everything
swrmgr system down              # Stop everything
swrmgr system stack-list        # List all stacks
swrmgr system node-list         # List all nodes
swrmgr system network-generate  # Create overlay networks
```

### AWS resources

```bash
swrmgr aws dns-create <name>      # Register DNS records
swrmgr aws dns-delete <name>      # Remove DNS records
swrmgr aws user-create <name>     # Create IAM user + policy
swrmgr aws user-delete <name>     # Full IAM cleanup
swrmgr aws secrets-init <name>    # Create Secrets Manager entry
swrmgr aws secrets-delete <name>  # Delete Secrets Manager entry
```

---

## Plugins

Plugins extend the toolkit without modifying core code. A plugin can register as a **tower** (adding new commands) and/or hook into **lifecycle events** (running code before/after core operations).

### Plugin structure

```
plugins/my-plugin/
├── plugin.conf                          # Metadata
├── bin/                                 # Commands (if registering a tower)
│   ├── setup
│   └── teardown
└── hooks/                               # Lifecycle hooks
    └── stack/
        ├── create/after/
        │   └── 50-my-setup              # Runs after stack create
        └── delete/before/
            └── 50-my-teardown           # Runs before stack delete
```

### plugin.conf

```bash
PLUGIN_NAME="my-plugin"
PLUGIN_VERSION="1.0.0"
PLUGIN_DESCRIPTION="What this plugin does"
PLUGIN_TOWER="my-plugin"    # Optional — registers as a command tower
```

### Tower commands

If `PLUGIN_TOWER` is set, the plugin's `bin/` scripts become available as:

```bash
swrmgr my-plugin setup
swrmgr my-plugin teardown
```

### Lifecycle hooks

Hooks are executable files in the `hooks/` directory, organized by event path. They run in numeric-prefix order across all plugins.

| Hook | Fires when |
|------|------------|
| `stack:init:before` / `after` | Stack initialization |
| `stack:create:before` / `after` | Stack creation |
| `stack:up:before` / `after` | Stack deployment |
| `stack:down:before` / `after` | Stack shutdown |
| `stack:delete:before` / `after` | Stack destruction |
| `stack:backup:before` / `after` | Backup creation |
| `stack:restore:before` / `after` | Backup restoration |
| `stack:yaml-generate:before` | Before YAML template rendering |
| `stack:env-test:after` | After environment validation |
| `system:up:before` / `after` | System startup |
| `system:up:services` | After networking, before stacks (for infrastructure services) |
| `system:down:before` / `after` | System shutdown |
| `system:cleanup:before` / `after` | System cleanup |

Hooks receive the stack name as the first argument (for stack-scoped events).

### Included plugins

**traefik** — Manages the Traefik reverse proxy. Dynamically generates the Traefik stack YAML with all customer networks. Hooks into `system:up:services` to start before customer stacks.

**bitwarden** — Manages credentials in Bitwarden. Hooks into `stack:create:after` and `stack:delete:before` to create and remove login entries automatically.

**metrics** — Logs test results to a MySQL database. Provides `swrmgr metrics save` for recording pass/fail outcomes.

### Writing your own plugin

1. Create `plugins/my-plugin/plugin.conf`
2. Add commands in `plugins/my-plugin/bin/`
3. Add hooks in `plugins/my-plugin/hooks/<event-path>/##-description`
4. Run `./install.sh` to deploy

Hooks have access to the core library:

```bash
#!/usr/bin/env bash
set -euo pipefail
. "${SWRMGR_ROOT:-/opt/swrmgr}/lib/core.sh"

stack="${1}"
# Your logic here
```

---

## Audit logging

Every command is logged to `/var/log/swrmgr/audit.log`:

```
2026-02-18T20:15:00Z user=jsmith host=manager-01 cmd=swrmgr stack delete acme-corp
```

The `user` field captures `$SUDO_USER` — the real person who ran the command, not the execution user.

---

## Requirements

- Bash ≥ 4.0
- Docker ≥ 20.x with Swarm mode enabled
- AWS CLI v2
- jq, curl, rsync, openssl, envsubst
- SSH access to all swarm nodes
- MySQL client (for database operations)

---

## License

MIT
