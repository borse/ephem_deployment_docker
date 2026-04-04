# ePHEM — Deployment Guide

![Odoo](https://img.shields.io/badge/Odoo-18.0-714B67?logo=odoo&logoColor=white)
![Docker](https://img.shields.io/badge/Docker-Compose-2496ED?logo=docker&logoColor=white)
![NGINX](https://img.shields.io/badge/NGINX-reverse--proxy-009639?logo=nginx&logoColor=white)
![Let's Encrypt](https://img.shields.io/badge/SSL-Let's%20Encrypt-003A70?logo=letsencrypt&logoColor=white)

Deploy ePHEM on your server by following this guide step by step. No Docker experience required.

---

## Table of Contents

- [How This Works](#how-this-works)
- [Requirements](#requirements)
- [Installation](#installation)
  - [Step 1 — Install Docker](#step-1--install-docker)
  - [Step 2 — Download the Deployment Files](#step-2--download-the-deployment-files)
  - [Step 3 — Configure Your Settings](#step-3--configure-your-settings)
  - [Step 4 — Run Setup](#step-4--run-setup)
  - [Step 5 — Set Up SSL](#step-5--set-up-ssl)
  - [Step 6 — Open ePHEM](#step-6--open-ephem)
- [ePHEM Custom Modules](#ephem-custom-modules)
- [Adding Domains](#adding-domains)
  - [Adding a Single Domain](#adding-a-single-domain)
  - [Adding Multiple Domains](#adding-multiple-domains)
  - [Creating Databases for New Domains](#creating-databases-for-new-domains)
- [Duplicating Databases](#duplicating-databases)
  - [Example: Training Environments](#example-training-environments)
- [Updating ePHEM](#updating-ephem)
  - [Update Custom Modules](#update-custom-modules)
  - [Update Deployment Configuration](#update-deployment-configuration)
  - [Update Odoo Base Image](#update-odoo-base-image)
  - [Update Odoo Modules Across Databases](#update-odoo-modules-across-databases)
- [Backups](#backups)
- [Day-to-Day Commands](#day-to-day-commands)
- [Troubleshooting](#troubleshooting)
- [File Structure](#file-structure)
- [Security Notes](#security-notes)
- [Need Help?](#need-help)

---

## How This Works

### What is Docker?

Docker runs software in **containers** — pre-packaged boxes that include everything an application needs. Instead of spending hours installing software manually, Docker sets everything up in minutes with a single command.

### What gets installed?

Docker starts **three containers** that work together on your server:

```
┌──────────────────────────────────────────────────────────────┐
│  Your Server                                                 │
│                                                              │
│  ┌──────────┐     ┌──────────────┐     ┌──────────────────┐  │
│  │  NGINX   │────▶│  Odoo 18     │────▶│  PostgreSQL 16   │  │
│  │  (door)  │     │  (ePHEM app) │     │  (database)      │  │
│  └──────────┘     └──────────────┘     └──────────────────┘  │
│     ▲                    ▲                                   │
│  open to             reads from                              │
│  the internet        custom-addons/                          │
│  (ports 80,443)      (ePHEM modules)                         │
└──────┼───────────────────────────────────────────────────────┘
       │
    Users open ePHEM in their browser
```

| Container | What it does |
|-----------|-------------|
| **NGINX** | The front door. Handles HTTPS and forwards traffic to Odoo. Only part visible from the internet. |
| **Odoo** | The ePHEM application. Uses a pre-built image — nothing to install manually. |
| **PostgreSQL** | The database. Stores all data. Hidden from the internet. |

### Where does the software come from?

| What | Source | What you do |
|------|--------|-------------|
| **Odoo 18 + system packages** | Pre-built Docker image by the ePHEM team | Nothing — Docker downloads it automatically |
| **ePHEM custom modules** | Private repository (access granted by ePHEM team) | The setup script generates an access key — send it to `ephem@who.int` |
| **Deployment files** | This repository | Download once, update with `git pull` |

---

## Requirements

- **A Linux server** — Ubuntu 22.04 or newer, with at least 2 GB RAM
- **SSH access** to the server (PuTTY on Windows, Terminal on Mac/Linux)
- **A domain name** (for production servers) — pointed at the server's IP address via a DNS A record

> **No domain?** That's fine for testing and local use. The setup script will detect this and make ePHEM accessible via `http://YOUR_SERVER_IP`. You can add a domain later.

---

## Installation

Connect to your server via SSH. Run all commands on the server.

### Step 1 — Install Docker

```bash
curl -fsSL https://get.docker.com | sh
```
The Above command may not always work on the first shot,
keep repeating until it finishes
```bash
sudo usermod -aG docker $USER
```

Log out and back in:

```bash
exit
```

Reconnect via SSH, then verify:

```bash
docker --version
```

### Step 2 — Download the Deployment Files

```bash
git clone https://github.com/borse/ephem_deployment_docker.git ephem-deploy
```

```bash
cd ephem-deploy
```

> **If you see "git: command not found":**
> ```bash
> sudo apt install -y git
> ```

### Step 3 — Configure Your Settings

```bash
cp .env.example .env
```

```bash
nano .env
```

**Set your passwords** (required):

```env
POSTGRES_PASSWORD=your_strong_password_here
ODOO_ADMIN_PASSWORD=your_master_password_here
```

**Set your domain** (optional — leave empty for IP-only access):

```env
# Production server with a domain:
DOMAIN=ephem.health.gov.xx
SSL_EMAIL=admin@health.gov.xx

# Testing / local VM without a domain:
DOMAIN=
```

> **Generate strong passwords:**
> ```bash
> openssl rand -base64 24
> ```

**Save:** `Ctrl+O`, `Enter`, `Ctrl+X`

### Step 4 — Run Setup

```bash
bash setup.sh
```

The setup script will:

- Verify Docker is installed
- Check your passwords are set
- Detect whether you have a domain or are running in IP mode
- Generate an access key for the ePHEM custom modules
- Sync settings from `.env` into the Odoo config
- Start all containers

At the end, the script shows your site URL and instructions for getting the ePHEM custom modules (see [ePHEM Custom Modules](#ephem-custom-modules)).

> **First run:** Takes 2–5 minutes to download (~1 GB). Future runs are instant.

### Step 5 — Set Up SSL

> **Skip this step** if you left `DOMAIN` empty in `.env`.

```bash
bash scripts/ssl-setup.sh ephem.health.gov.xx admin@health.gov.xx
```

Replace with your actual domain and email.

### Step 6 — Open ePHEM

Open your browser and go to:

- **With domain:** `https://ephem.health.gov.xx`
- **Without domain:** `http://YOUR_SERVER_IP` (shown by the setup script)

Fill in the database creation form:

| Field | What to enter |
|-------|--------------|
| **Master Password** | The `ODOO_ADMIN_PASSWORD` from your `.env` |
| **Database Name** | Use your subdomain (e.g. `ephem`) or any name |
| **Email** | Your admin email |
| **Password** | Choose a password for the admin user |
| **Language** | Your language |
| **Country** | Your country |

Click **Create Database** (takes 1–2 minutes).

🎉 **ePHEM is running!**

---

## ePHEM Custom Modules

The ePHEM custom modules are hosted in a private repository. When you run `bash setup.sh` for the first time, the script automatically generates an SSH access key and displays it at the end.

**To get access:**

1. Copy the SSH key shown by the setup script
2. Email it to **`ephem@who.int`** — include your country or server name in the subject
3. The ePHEM team will grant read-only access and confirm
4. Once confirmed, run `bash setup.sh` again — it will download the modules automatically

**While waiting for access**, ePHEM runs with standard Odoo modules. You can create databases, configure users, and explore the interface. The ePHEM-specific modules will appear in **Apps** after access is granted and setup is re-run.

> **Already have access?** Running `bash setup.sh` detects your key and clones the modules automatically — no extra steps.

---

## Adding Domains

Run multiple databases on the same server — for example production, training, and simulation exercises. Each domain points to its own independent database.

| URL | Database |
|-----|----------|
| `ephem.health.gov.xx` | `ephem` |
| `training.health.gov.xx` | `training` |
| `simex.health.gov.xx` | `simex` |

**Before adding a domain**, ask your IT team to create a DNS A record pointing the new domain to this server's IP.

### Adding a Single Domain

```bash
bash scripts/add-domain.sh training.health.gov.xx
```

### Adding Multiple Domains

```bash
bash scripts/add-domain.sh training.health.gov.xx simex.health.gov.xx staging.health.gov.xx
```

The script checks DNS, expands the SSL certificate, updates NGINX, and restarts — all automatically.

### Creating Databases for New Domains

After adding a domain, create a database for it at:

```
https://training.health.gov.xx/web/database/manager
```

> **Important:** The database name must match the subdomain. For `training.health.gov.xx`, name the database `training`.

You can also **duplicate** an existing database or **restore** from a backup (see [Duplicating Databases](#duplicating-databases)).

### Disable Database Manager

Once all databases are created, prevent unauthorized access to the database manager:

```bash
nano .env
```

Set `ODOO_LIST_DB=False`, save, then:

```bash
bash setup.sh
```

---

## Duplicating Databases

Create multiple copies of a configured database. Useful for setting up training rooms where each group gets their own environment.

### Example: Training Environments

**1. Add all domains:**

```bash
bash scripts/add-domain.sh training-01.pheoc.com training-02.pheoc.com training-03.pheoc.com training-04.pheoc.com training-05.pheoc.com training-06.pheoc.com
```

**2. Create and configure `training-01`** at `https://training-01.pheoc.com` — install modules, set up users, configure settings.

**3. Duplicate into all others:**

```bash
bash scripts/duplicate-db.sh training-01 training-02 training-03 training-04 training-05 training-06
```

All 6 databases are now identical copies. Each is accessible at its own URL and completely independent — changes to one don't affect the others.

---

## Updating ePHEM

### Update Custom Modules

When the ePHEM team releases new features or fixes:

```bash
cd ~/ephem-deploy/custom-addons
```

```bash
git pull
```

```bash
cd ..
```

```bash
docker compose restart odoo
```

Then go to **Apps → Update Apps List** and upgrade the modules.

### Update Deployment Configuration

When this repository is updated (new scripts, config changes):

```bash
cd ~/ephem-deploy
```

```bash
git pull
```

```bash
bash setup.sh
```

> `git pull` never overwrites your `.env`, `nginx/active.conf`, or `odoo.conf`.

### Update Odoo Base Image

When the ePHEM team announces a system update:

```bash
bash scripts/backup.sh
```

```bash
docker compose pull
```

```bash
docker compose up -d
```

### Update Odoo Modules Across Databases

To update or install modules across all databases at once:

**Auto mode** (all modules, all databases):

```bash
bash scripts/update-modules.sh --auto
```

**Auto mode on a specific database:**

```bash
bash scripts/update-modules.sh --auto --db training-server
```

**Interactive mode** (pick databases and modules):

```bash
bash scripts/update-modules.sh
```

---

## Backups

### Run a Backup

```bash
bash scripts/backup.sh
```

### Automatic Daily Backups

```bash
crontab -e
```

Add (replace the path):

```
0 2 * * * /home/YOUR_USERNAME/ephem-deploy/scripts/backup.sh >> /home/YOUR_USERNAME/ephem-deploy/backups/backup.log 2>&1
```

Backups older than 14 days are deleted automatically.

> **Important:** Copy backups to a different location regularly. If this server fails, local backups are lost too.

### Restore from Backup

```bash
docker compose stop odoo
```

```bash
gunzip < backups/DBNAME_TIMESTAMP.sql.gz | docker compose exec -T db psql -U odoo -d DBNAME
```

```bash
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
```

```bash
docker compose up -d
```

### Odoo errors or blank pages

```bash
docker compose logs --tail=30 odoo
```

### New domain shows wrong database

Make sure `ODOO_DBFILTER=%d` is set in `.env` and database names match subdomains exactly. Then:

```bash
bash setup.sh
```

### Custom modules not appearing

```bash
chmod -R 755 custom-addons/
```

```bash
docker compose restart odoo
```

Go to **Apps → Update Apps List**.

### SSL not working

```bash
sudo ufw allow 80
```

```bash
sudo ufw allow 443
```

```bash
bash scripts/ssl-setup.sh yourdomain.com your@email.com
```

### Start completely fresh

> **Warning:** Deletes ALL data.

```bash
docker compose down -v
```

```bash
rm -f nginx/active.conf
```

```bash
bash setup.sh
```

---

## File Structure

```
ephem-deploy/
│
├── docker-compose.yml         ← Container definitions
├── .env.example               ← Settings template — copy to .env
├── .env                       ← Your settings (never shared)
├── odoo.conf                  ← Odoo config (synced from .env by setup.sh)
├── setup.sh                   ← Main setup script — run after install and updates
│
├── nginx/
│   ├── default.conf           ← HTTP-only template (in Git, never modified)
│   └── active.conf            ← Active NGINX config (created by scripts)
│
├── custom-addons/             ← ePHEM modules (private repo)
│
├── scripts/
│   ├── ssl-setup.sh           ← Set up SSL certificates
│   ├── add-domain.sh          ← Add new domains
│   ├── duplicate-db.sh        ← Copy databases
│   ├── update-modules.sh      ← Update Odoo modules across databases
│   ├── backup.sh              ← Backup databases and filestore
│   ├── clone-addons.sh        ← Clone addons after access is granted
│   └── request-addons-access.sh ← Generate deploy key (also run by setup.sh)
│
├── backups/                   ← Backup files
└── logs/                      ← Module update logs
```

---

## Security Notes

**Built-in:**

- PostgreSQL and Odoo are hidden from the internet — only NGINX is exposed
- All traffic encrypted with HTTPS (TLS 1.2+)
- Security headers protect against common web attacks
- Rate limiting prevents abuse
- Containers run on a private Docker network
- SSL certificates renew automatically

**Recommended after installation:**

- Disable password-based SSH login (use SSH keys only)
- Install fail2ban: `sudo apt install -y fail2ban`
- Copy backups off the server regularly
- Enable two-factor authentication for admin users (Settings → Permissions)
- Disable the database manager after setup (`ODOO_LIST_DB=False` in `.env`)

---

## Need Help?

1. Check [Troubleshooting](#troubleshooting)
2. Run `docker compose logs` and share the output with the ePHEM team
3. Open an issue: [github.com/borse/ephem_deployment_docker/issues](https://github.com/borse/ephem_deployment_docker/issues)