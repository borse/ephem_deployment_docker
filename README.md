# ePHEM — Deployment Guide

![Odoo](https://img.shields.io/badge/Odoo-18.0-714B67?logo=odoo&logoColor=white)
![Docker](https://img.shields.io/badge/Docker-Compose-2496ED?logo=docker&logoColor=white)
![NGINX](https://img.shields.io/badge/NGINX-reverse--proxy-009639?logo=nginx&logoColor=white)
![Let's Encrypt](https://img.shields.io/badge/SSL-Let's%20Encrypt-003A70?logo=letsencrypt&logoColor=white)

Deploy and develop ePHEM using Docker. The setup script handles everything — just run it and choose your use case.

---

## Table of Contents

- [Choose Your Setup](#choose-your-setup)
- [Requirements](#requirements)
- [Quick Start](#quick-start)
  - [Step 1 — Install Docker](#step-1--install-docker)
  - [Step 2 — Clone This Repo](#step-2--clone-this-repo)
  - [Step 3 — Run Setup](#step-3--run-setup)
- [Mode 1 — Server Deploy](#mode-1--server-deploy)
  - [Configure Your Settings](#configure-your-settings)
  - [Set Up SSL](#set-up-ssl)
  - [Open ePHEM](#open-ephem)
- [Mode 2 — Demo / Evaluate](#mode-2--demo--evaluate)
- [Mode 3 — Developer](#mode-3--developer)
  - [Developer Prerequisites](#developer-prerequisites)
  - [GitHub SSH Key](#github-ssh-key)
  - [What the Script Sets Up](#what-the-script-sets-up)
  - [Open in PyCharm](#open-in-pycharm)
  - [Docker Plugin for PyCharm](#docker-plugin-for-pycharm)
  - [Development Cycle](#development-cycle)
  - [Useful Developer Commands](#useful-developer-commands)
  - [Git Workflow](#git-workflow)
- [ePHEM Custom Modules](#ephem-custom-modules)
- [Adding Domains](#adding-domains)
- [Duplicating Databases](#duplicating-databases)
- [Updating ePHEM](#updating-ephem)
- [Backups](#backups)
- [Day-to-Day Commands](#day-to-day-commands)
- [Troubleshooting](#troubleshooting)
- [Uninstalling ePHEM](#uninstalling-ephem)
- [File Structure](#file-structure)
- [Security Notes](#security-notes)
- [Need Help?](#need-help)

---

## Choose Your Setup

When you run `bash setup.sh`, the first thing it asks is who you are:

```
What are you setting up?

  1) Server deploy     — Production or staging server
  2) Demo / Evaluate   — Try ePHEM locally (no development)
  3) Developer         — I'm a collaborator; I want to edit addons and use PyCharm
```

Here's how each mode works:

![Setup flow](docs/setup-flow.svg)

**Modes 1 and 2** use a read-only **deploy key** — a machine-specific key you email to the ePHEM team to get access to the private addons repo. No GitHub account needed.

**Mode 3** uses your **personal SSH key** already on GitHub — you clone with full write access, push branches, and edit addons live in PyCharm.

---

## Requirements

- **A server or computer** running one of:
  - **Linux** (Ubuntu 22.04+ recommended) — works out of the box
  - **Mac** (macOS 12+) — install [Docker Desktop for Mac](https://docs.docker.com/desktop/install/mac-install/)
  - **Windows 10/11** — install [Docker Desktop for Windows](https://docs.docker.com/desktop/install/windows-install/) and run all commands inside **WSL**
- At least **2 GB RAM**
- **SSH access** (for remote servers) or a terminal (for local machines)
- **A domain name** (for production servers with SSL) — pointed at the server's IP via a DNS A record

> **No domain?** Fine for testing and local use. The script detects this and runs on `http://YOUR_IP:8069` or `http://localhost:8069`. You can add a domain later.

> **Windows users:** Open a WSL terminal (search "WSL" or "Ubuntu" in Start) and run all commands there.

---

## Quick Start

These three steps apply to all modes. After cloning and running setup, the script guides you through the rest.

### Step 1 — Install Docker

**Linux (Ubuntu/Debian):**

```bash
curl -fsSL https://get.docker.com | sh
```

```bash
sudo usermod -aG docker $USER
```

**Log out and log back in** — this is required for the group change to take effect. A new terminal alone is not enough.

Verify it worked:

```bash
groups        # should include: docker
docker --version
```

> If you skip the `usermod` step, `setup.sh` will detect it and tell you exactly what to do.

**Mac or Windows:** Install [Docker Desktop](https://docs.docker.com/desktop/) and make sure it's running. On Windows, open a **WSL terminal** for all remaining steps.

### Step 2 — Clone This Repo

```bash
git clone https://github.com/borse/ephem_deployment_docker.git ephem-deploy
cd ephem-deploy
```

> **If you see "git: command not found":** `sudo apt install -y git`

### Step 3 — Run Setup

```bash
bash setup.sh
```

The script asks which mode you want, then handles everything from there — creating config files, downloading images, cloning addons, and starting containers.

> **First run:** Takes 2–5 minutes to download (~1 GB of Docker images). Future runs are instant.

---

## Mode 1 — Server Deploy

For deploying ePHEM on a production or staging server.

### Configure Your Settings

When you run `bash setup.sh` and choose **1**, the script creates a `.env` file from the template and immediately stops to ask you to fill it in. Open it:

```bash
nano .env
```

**Required — set real passwords:**

```env
POSTGRES_PASSWORD=your_strong_password_here
ODOO_ADMIN_PASSWORD=your_master_password_here
```

**Recommended for production — set your domain:**

```env
DOMAIN=ephem.health.gov.xx
SSL_EMAIL=admin@health.gov.xx
```

> **Generate strong passwords:** `openssl rand -base64 24`

> **New to `nano`?** Arrow keys to move, type to edit. `Ctrl+O` then `Enter` to save, `Ctrl+X` to exit.

Once saved, run setup again:

```bash
bash setup.sh
```

### Set Up SSL

After setup completes, if you set a domain, enable HTTPS:

```bash
bash scripts/ssl-setup.sh ephem.health.gov.xx admin@health.gov.xx
```

> **SSL prerequisite:** Port 80 and 443 must be open on your server firewall, and your domain DNS must already point to the server's IP. Let's Encrypt will fail if either is missing.

### Open ePHEM

Open your browser:

- **With SSL:** `https://ephem.health.gov.xx`
- **With domain, no SSL yet:** `http://ephem.health.gov.xx`
- **Without domain:** `http://YOUR_SERVER_IP` (shown by the setup script)

Fill in the database creation form:

| Field | What to enter |
|-------|--------------|
| **Master Password** | Your `ODOO_ADMIN_PASSWORD` |
| **Database Name** | Your subdomain (e.g. `ephem`) or any name |
| **Email** | Your admin email |
| **Password** | Admin user password |
| **Language** | Your language |
| **Country** | Your country |

Click **Create Database** (takes 1–2 minutes). 🎉

---

## Mode 2 — Demo / Evaluate

For trying ePHEM on any machine — locally or on a cloud server — without any development intent.

Run `bash setup.sh` and choose **2**. The script:

- Creates a `.env` with auto-generated passwords (no editing needed)
- Skips domain and SSL — Odoo is exposed directly on port 8069
- Starts ePHEM and shows you the URLs to access it

At the end you'll see:

```
Your demo is available at:
  http://localhost:8069        (on this machine)
  http://YOUR_SERVER_IP:8069  (from other devices on the network)
```

When you're done:

```bash
docker compose down        # stop (keep data)
docker compose down -v     # stop and delete all data
```

---

## Mode 3 — Developer

For collaborators who want to edit ePHEM custom addons locally, with live reloading and PyCharm integration.

### Developer Prerequisites

- **Docker** — installed and your user in the `docker` group (see [Step 1](#step-1--install-docker))
- **PyCharm** — [Community Edition](https://www.jetbrains.com/pycharm/download/) (free) or Professional
- **Git** — pre-installed on Mac/Linux. Windows: [git-scm.com](https://git-scm.com/download/win) or WSL
- **Collaborator access** on `borse/ePHEM` — request this from the ePHEM team before running setup

### GitHub SSH Key

Developer mode uses your personal SSH key — the same one you use to push to GitHub. You do **not** get a deploy key; you use your own identity.

**Check if you already have a key:**

```bash
cat ~/.ssh/id_ed25519.pub
```

**If not, generate one:**

```bash
ssh-keygen -t ed25519 -C "your@email.com"
```

**Add it to GitHub:**

1. Copy the output of `cat ~/.ssh/id_ed25519.pub`
2. Go to [github.com/settings/keys](https://github.com/settings/keys)
3. Click **New SSH key**, paste, save

**Verify it works:**

```bash
ssh -T git@github.com
# Hi yourname! You've successfully authenticated...
```

The setup script runs this check automatically and stops with clear instructions if it fails.

### What the Script Sets Up

When you choose mode 3, `setup.sh`:

1. Verifies your GitHub SSH access
2. Asks which branch to work on (`18_national_dev` recommended)
3. Clones the addons repo with **full write access** (not depth-limited)
4. Creates `docker-compose.override.yml` with:
   - `custom-addons/` mounted **read-write** (live editing — no container rebuild needed)
   - Nginx and Certbot disabled — Odoo is accessed directly on `:8069`
5. Writes a developer `odoo.conf` with:
   - `workers = 0` — threading mode, simpler for local use
   - `log_level = debug` — verbose output in the logs
   - `dev_mode = reload,qweb,werkzeug,xml` — enables live asset reloading in the browser

> `docker-compose.override.yml` is picked up automatically by Docker Compose. Add it to `.gitignore` — do not commit it.

### Open in PyCharm

1. Open PyCharm
2. **File → Open** → select the `custom-addons/` folder
3. PyCharm opens with all ePHEM modules in the project tree

Your project structure will look like:

```
custom-addons/
├── eoc_base/
├── eoc_signals/
├── eoc_actors/
├── eoc_incident_management/
├── eoc_dashboard/
├── ...
```

PyCharm Community understands Odoo's Python and XML — you get full autocomplete, go-to-definition, and error highlighting without any extra configuration.

### Docker Plugin for PyCharm

The Docker plugin lets you start, stop, and restart containers and watch live logs — all from inside PyCharm without touching a terminal.

**Install:**

1. **Settings → Plugins** → search "Docker" → Install → restart PyCharm
2. **Settings → Build, Execution, Deployment → Docker** → click `+` → select **Unix socket** (auto-detected)
3. A **Services** panel appears at the bottom (**View → Tool Windows → Services**)

From the Services panel you can:

- See all running containers
- Start / stop / restart `ephem-app` with one click
- View live logs per container in a dedicated tab — persistent across PyCharm restarts

> **Permission denied in the Docker plugin?** Your user isn't in the `docker` group or the session hasn't picked it up yet. See [Permission denied connecting to Docker](#permission-denied-connecting-to-docker) in Troubleshooting.

### Development Cycle

**Edit → Restart → Test:**

1. Edit any file in `custom-addons/` in PyCharm
2. Restart Odoo — either from the Services panel in PyCharm, or in the terminal:

```bash
docker compose restart odoo
```

3. Test at `http://localhost:8069`

**Update a specific module** (re-reads views, data files, and migrations):

```bash
docker compose exec odoo odoo -u your_module_name -d YOUR_DB --db_host db --db_user odoo --db_password dev --stop-after-init --no-http
```

Or use the interactive script:

```bash
bash scripts/update-modules.sh
```

**Watch logs in real time:**

```bash
docker compose logs -f odoo
```

**Filter for errors only:**

```bash
docker compose logs -f odoo 2>&1 | grep -E "ERROR|Traceback|WARNING"
```

> **Tip:** For Python changes, restart Odoo. For XML/CSS/QWeb changes, a browser reload is often enough with `dev_mode` on.

### Useful Developer Commands

| What you want to do | Command |
|---------------------|---------|
| Start everything | `docker compose up -d` |
| Stop everything | `docker compose down` |
| Restart Odoo (after code changes) | `docker compose restart odoo` |
| View Odoo logs | `docker compose logs -f odoo` |
| Open Odoo Python shell | `docker compose exec odoo odoo shell -d YOUR_DB --db_host db --db_user odoo --db_password dev --no-http` |
| Open PostgreSQL console | `docker compose exec db psql -U odoo` |
| List databases | `docker compose exec db psql -U odoo -d postgres -c "\l"` |
| Check container status | `docker compose ps` |
| Pull latest Docker image | `docker compose pull && docker compose up -d` |

### Git Workflow

Work in the `custom-addons/` folder — that's the repo you push to.

**From PyCharm** (recommended):

- **Git → Commit** (`Ctrl+K`) to commit
- **Git → Push** (`Ctrl+Shift+K`) to push
- **Git → Pull** to get latest
- Branch switching: bottom-right corner of PyCharm

**From the terminal:**

```bash
cd custom-addons
git status
git add .
git commit -m "your message"
git push
```

---

## ePHEM Custom Modules

The ePHEM custom modules live in a private repository.

**For server deploy and demo (modes 1 & 2):** The setup script generates a machine-specific deploy key and displays it at the end of the first run. Email it to **`ephem@who.int`** with your country/server name in the subject. Once the team grants access, run `bash setup.sh` again — it clones the modules automatically.

**For developers (mode 3):** You need collaborator access on `borse/ePHEM`. Request this from the ePHEM team before running setup. Once granted, the script clones using your personal SSH key.

> **While waiting for access**, ePHEM runs with standard Odoo modules. You can create databases, configure users, and explore the interface. ePHEM-specific modules appear in **Apps** after access is granted and setup is re-run.

---

## Adding Domains

Run multiple databases on the same server — for example production, training, and simulation. Each domain points to its own independent database.

| URL | Database |
|-----|----------|
| `ephem.health.gov.xx` | `ephem` |
| `training.health.gov.xx` | `training` |
| `simex.health.gov.xx` | `simex` |

Before adding a domain, create a DNS A record pointing it to this server's IP.

**Add a single domain:**

```bash
bash scripts/add-domain.sh training.health.gov.xx
```

**Add multiple domains at once:**

```bash
bash scripts/add-domain.sh training.health.gov.xx simex.health.gov.xx
```

**Create a database for the new domain** at:

```
https://training.health.gov.xx/web/database/manager
```

> The database name must match the subdomain. For `training.health.gov.xx`, name it `training`.

**Disable the database manager** once all databases are set up:

```bash
nano .env   # set ODOO_LIST_DB=False
bash setup.sh
```

---

## Duplicating Databases

Create identical copies of a configured database — useful for training rooms where each group gets their own environment.

**Example: 6 training environments:**

```bash
# 1. Add all domains
bash scripts/add-domain.sh training-01.pheoc.com training-02.pheoc.com training-03.pheoc.com training-04.pheoc.com training-05.pheoc.com training-06.pheoc.com

# 2. Set up and configure training-01 at https://training-01.pheoc.com

# 3. Duplicate to all others
bash scripts/duplicate-db.sh training-01 training-02 training-03 training-04 training-05 training-06
```

All 6 databases are identical and completely independent.

---

## Updating ePHEM

Re-running `bash setup.sh` is the recommended way to update — it checks for addon and image updates and prompts you before pulling anything.

### Update via setup.sh (recommended)

```bash
bash setup.sh
```

The script will:
- Check if `custom-addons/` has new commits and ask if you want to pull
- Ask if you want to check for a newer Docker image
- Warn you clearly if an addon update requires running `bash scripts/update-modules.sh`

### Update Deployment Scripts

When this repo itself has changes (new scripts, config improvements):

```bash
git pull
bash setup.sh
```

> `git pull` on this repo never overwrites `.env`, `nginx/active.conf`, `odoo.conf`, or `docker-compose.override.yml`.

### Update Odoo Base Image Manually

```bash
bash scripts/backup.sh
docker compose pull
docker compose up -d
```

### Update Odoo Modules Across All Databases

After pulling addon updates, tell Odoo about the changes:

```bash
bash scripts/update-modules.sh --auto
```

Or for a specific database:

```bash
bash scripts/update-modules.sh --auto --db your-database-name
```

---

## Backups

```bash
bash scripts/backup.sh
```

**Automatic daily backups:**

```bash
crontab -e
```

Add (replace `YOUR_USERNAME` and the path to match your setup):

```
0 2 * * * /home/YOUR_USERNAME/ephem-deploy/scripts/backup.sh >> /home/YOUR_USERNAME/ephem-deploy/backups/backup.log 2>&1
```

Backups older than 14 days are deleted automatically.

> **Important:** Copy backups off the server regularly. Local backups are lost if the server fails.

**Restore from backup:**

```bash
docker compose stop odoo
gunzip < backups/DBNAME_TIMESTAMP.sql.gz | docker compose exec -T db psql -U odoo -d DBNAME
docker compose start odoo
```

---

## Day-to-Day Commands

Run from inside the `ephem-deploy` folder.

| What you want to do | Command |
|---------------------|---------|
| Start the system | `docker compose up -d` |
| Stop the system | `docker compose down` |
| Restart Odoo | `docker compose restart odoo` |
| Restart everything | `docker compose restart` |
| Check status | `docker compose ps` |
| View Odoo logs | `docker compose logs -f odoo` |
| Run a backup | `bash scripts/backup.sh` |
| Add a domain | `bash scripts/add-domain.sh new.domain.com` |
| Duplicate a database | `bash scripts/duplicate-db.sh source target1 target2` |
| Update modules | `bash scripts/update-modules.sh` |
| Re-run setup | `bash setup.sh` |

> Press `Ctrl+C` to stop watching logs.

---

## Troubleshooting

### Nothing loads in the browser

```bash
docker compose ps
docker compose up -d
```

### Odoo errors or blank pages

```bash
docker compose logs --tail=30 odoo
```

### Permission denied connecting to Docker

This means your user isn't in the `docker` group yet, or the session hasn't reloaded since it was added. Run:

```bash
sudo usermod -aG docker $USER
```

Then **log out and log back in completely** — not just a new terminal, a full desktop or SSH logout. Running processes (including PyCharm) inherit group memberships from the login session and won't see the change until you re-login.

After logging back in, verify:

```bash
groups   # should now include: docker
```

Then run `bash setup.sh` again.

> **Why doesn't `newgrp docker` work?** `newgrp` only applies to the current terminal. PyCharm and other GUI apps launched from the desktop still run without the `docker` group until you do a full logout.

### SSL certificate fails

Make sure ports 80 and 443 are open and your domain's DNS points to the server:

```bash
sudo ufw allow 80
sudo ufw allow 443
```

Also check your hosting provider's firewall (DigitalOcean, AWS, etc. have separate firewall settings). Then retry:

```bash
bash scripts/ssl-setup.sh yourdomain.com your@email.com
```

### New domain shows wrong database

Make sure `ODOO_DBFILTER=%d` is set in `.env` and database names match subdomains exactly, then:

```bash
bash setup.sh
```

### Custom modules not appearing

```bash
chmod -R 755 custom-addons/
docker compose restart odoo
```

Go to **Apps → Update Apps List**.

### Start completely fresh

> **Warning:** Deletes ALL data.

```bash
docker compose down -v
rm -f nginx/active.conf docker-compose.override.yml
bash setup.sh
```

---

## Uninstalling ePHEM

```bash
cd ephem-deploy
docker compose down -v
docker rmi borrs/ephem:latest nginx:alpine postgres:16-alpine certbot/certbot
cd ..
rm -rf ephem-deploy
```

**Also remove Docker (Linux):**

```bash
sudo apt remove -y docker-ce docker-ce-cli containerd.io docker-compose-plugin
```

**Mac:** Docker Desktop → Settings → Uninstall.

**Windows:** Windows Settings → Apps → Docker Desktop → Uninstall.

---

## File Structure

```
ephem-deploy/
│
├── docker-compose.yml              ← Container definitions (production)
├── docker-compose.override.yml     ← Local overrides (generated by setup.sh, not committed)
├── .env.example                    ← Settings template
├── .env                            ← Your settings (never committed)
├── odoo.conf                       ← Odoo config (generated by setup.sh)
├── setup.sh                        ← Main setup script — run this for installs and updates
│
├── nginx/
│   ├── default.conf                ← HTTP-only template (in Git, never modified)
│   └── active.conf                 ← Active NGINX config (created by scripts)
│
├── custom-addons/                  ← ePHEM modules (private repo)
│                                     read-only in server/demo, read-write in developer mode
│
├── scripts/
│   ├── ssl-setup.sh                ← Set up HTTPS with Let's Encrypt
│   ├── add-domain.sh               ← Add new domains to an existing installation
│   ├── duplicate-db.sh             ← Copy a database (for training environments)
│   ├── update-modules.sh           ← Update Odoo modules across databases after addon changes
│   ├── backup.sh                   ← Backup databases and filestore
│   ├── clone-addons.sh             ← Clone addons after deploy key access is granted
│   └── request-addons-access.sh    ← Generate a deploy key manually
│
├── backups/                        ← Backup files (auto-created)
└── logs/                           ← Module update logs (auto-created)
```

---

## Security Notes

**Built-in (server mode):**

- PostgreSQL and Odoo are not exposed to the internet — only NGINX is
- All traffic encrypted with HTTPS (TLS 1.2+)
- Security headers protect against common web attacks
- Rate limiting prevents abuse
- Containers run on a private Docker network
- SSL certificates renew automatically

**Note:** Demo and developer modes expose Odoo directly on port 8069 without SSL or a reverse proxy. This is intentional for local/evaluation use — do not use demo or developer mode on a public-facing production server.

**Recommended after production installation:**

- Disable password-based SSH login (use SSH keys only)
- Install fail2ban: `sudo apt install -y fail2ban`
- Copy backups off the server regularly
- Enable two-factor authentication for admin users (**Settings → Permissions**)
- Disable the database manager after all databases are created (`ODOO_LIST_DB=False` in `.env`, then re-run `bash setup.sh`)

---

## Need Help?

1. Check [Troubleshooting](#troubleshooting)
2. Run `docker compose logs` and share the output with the ePHEM team
3. Open an issue: [github.com/borse/ephem_deployment_docker/issues](https://github.com/borse/ephem_deployment_docker/issues)