# ePHEM — Deployment Guide

![Odoo](https://img.shields.io/badge/Odoo-18.0-714B67?logo=odoo&logoColor=white)
![Docker](https://img.shields.io/badge/Docker-Compose-2496ED?logo=docker&logoColor=white)
![NGINX](https://img.shields.io/badge/NGINX-reverse--proxy-009639?logo=nginx&logoColor=white)
![Let's Encrypt](https://img.shields.io/badge/SSL-Let's%20Encrypt-003A70?logo=letsencrypt&logoColor=white)

Deploy ePHEM on your server by following this guide step by step. No Docker experience required.

---

## Table of Contents

- [How This Works](#how-this-works)
- [What You Need Before Starting](#what-you-need-before-starting)
- [Installation](#installation)
  - [Step 1 — Install Docker](#step-1--install-docker)
  - [Step 2 — Download the Deployment Files](#step-2--download-the-deployment-files)
  - [Step 3 — Configure Your Settings](#step-3--configure-your-settings)
  - [Step 4 — Run the Setup Script](#step-4--run-the-setup-script)
  - [Step 5 — Set Up SSL (HTTPS)](#step-5--set-up-ssl-https)
  - [Step 6 — Open ePHEM in Your Browser](#step-6--open-ephem-in-your-browser)
- [Adding Domains](#adding-domains)
  - [Adding a Single Domain](#adding-a-single-domain)
  - [Adding Multiple Domains at Once](#adding-multiple-domains-at-once)
  - [Creating Databases for New Domains](#creating-databases-for-new-domains)
- [Duplicating Databases](#duplicating-databases)
  - [Example: Setting Up Training Environments](#example-setting-up-training-environments)
  - [Duplicating a Single Database](#duplicating-a-single-database)
  - [Overwriting Existing Databases](#overwriting-existing-databases)
- [Updating ePHEM](#updating-ephem)
  - [Update ePHEM Modules](#update-ephem-modules)
  - [Update the Deployment Configuration](#update-the-deployment-configuration)
  - [Update the Odoo Base Image](#update-the-odoo-base-image)
- [Backups](#backups)
  - [Manual Backup](#manual-backup)
  - [Automatic Daily Backups](#automatic-daily-backups)
  - [Restore a Backup](#restore-a-backup)
- [Day-to-Day Commands](#day-to-day-commands)
- [SSL Renewal](#ssl-renewal)
- [Troubleshooting](#troubleshooting)
- [File Structure](#file-structure)
- [Security Notes](#security-notes)
- [Need Help?](#need-help)

---

## How This Works

### What is Docker?

Docker runs software in **containers** — pre-packaged boxes that include everything an application needs. Instead of spending hours installing software manually, Docker does it in minutes with a single command.

### What happens when you start ePHEM?

Docker starts **three containers** that work together:

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
| **Odoo** | The ePHEM application. Uses a **pre-built image** — nothing to install manually. |
| **PostgreSQL** | The database. Stores all data. Hidden from the internet. |

### Where does the software come from?

| What | Where it comes from | What you do |
|------|-------------------|-------------|
| **Odoo 18 + system packages** | Pre-built Docker image published by the ePHEM team. | Nothing — Docker downloads it automatically. |
| **ePHEM modules** | [github.com/borse/ePHEM](https://github.com/borse/ePHEM) | Downloaded automatically by the setup script. Update with `git pull`. |
| **Deployment files** | [github.com/borse/ephem_deployment_docker](https://github.com/borse/ephem_deployment_docker) — this repo | Download once. Update with `git pull`. |

---

## What You Need Before Starting

- **A Linux server** — Ubuntu 22.04 or newer, with at least 2 GB RAM
- **A domain name** pointed at your server's IP address (ask your IT team to create a DNS A record)
- **SSH access** to the server (PuTTY on Windows, Terminal on Mac/Linux)

> **Check if your domain is set up correctly:**
> ```bash
> ping ephem.health.gov.xx
> ```
> If it shows your server's IP address, you're ready.

---

## Installation

Connect to your server via SSH. Run all commands on the server.

### Step 1 — Install Docker

```bash
curl -fsSL https://get.docker.com | sh
```

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

You should see `Docker version 27.x.x` or similar.

### Step 2 — Download the Deployment Files

```bash
git clone git@github.com:borse/ephem_deployment_docker.git ephem-deploy
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

**Change these values:**

```env
# Your domain (no www, no https)
DOMAIN=ephem.health.gov.xx

# Database password
POSTGRES_PASSWORD=CHANGE_ME

# Odoo master password (for database management page)
ODOO_ADMIN_PASSWORD=CHANGE_ME

# Email for SSL certificate
SSL_EMAIL=admin@health.gov.xx
```

> **Generate strong passwords:**
> ```bash
> openssl rand -base64 24
> ```

**Save:** `Ctrl+O`, `Enter`, `Ctrl+X`

### Step 4 — Run the Setup Script

```bash
./setup.sh
```

This script will:

- Verify Docker is installed
- Check your passwords are set
- Download the ePHEM modules automatically
- Sync settings from `.env` into the Odoo config
- Start all containers

> **First time:** Takes 2–5 minutes to download (~1 GB). Future starts are instant.

Check everything is running:

```bash
docker compose ps
```

All containers should show **Up**.

### Step 5 — Set Up SSL (HTTPS)

```bash
./scripts/ssl-setup.sh ephem.health.gov.xx admin@health.gov.xx
```

Replace with your actual domain and email. This will:

- Request an SSL certificate from Let's Encrypt
- Configure NGINX for HTTPS
- Set up HTTP → HTTPS redirect

### Step 6 — Open ePHEM in Your Browser

Go to:

```
https://ephem.health.gov.xx
```

Fill in the database creation form:

| Field | What to enter |
|-------|--------------|
| **Master Password** | The `ODOO_ADMIN_PASSWORD` from your `.env` |
| **Database Name** | Use your subdomain name (e.g. `ephem`) |
| **Email** | Your admin email |
| **Password** | Choose a password for the admin user |
| **Language** | Your language |
| **Country** | Your country |

Click **Create Database** (takes 1–2 minutes).

After login, go to **Apps → Update Apps List** and install the ePHEM modules.

🎉 **ePHEM is running!**

---

## Adding Domains

You can run multiple databases on the same server — for example production, training, and simulation exercises. Each domain points to its own independent database.

| URL | Database |
|-----|----------|
| `ephem.health.gov.xx` | `ephem` |
| `training.health.gov.xx` | `training` |
| `simex.health.gov.xx` | `simex` |

### Before Adding a Domain

Ask your IT team to create a **DNS A record** for the new domain pointing to the same server IP. Verify it works:

```bash
dig +short training.health.gov.xx
```

It should show your server's IP address.

### Adding a Single Domain

```bash
./scripts/add-domain.sh training.health.gov.xx
```

The script will:

1. Check DNS is set up correctly
2. Expand the SSL certificate to include the new domain
3. Update the NGINX config
4. Restart NGINX

### Adding Multiple Domains at Once

```bash
./scripts/add-domain.sh training.health.gov.xx simex.health.gov.xx staging.health.gov.xx
```

All domains are processed in one go — one certificate expansion, one NGINX restart.

### Creating Databases for New Domains

After adding a domain, you need to create a database for it.

**Option A — Create a fresh database:**

Go to:

```
https://training.health.gov.xx/web/database/manager
```

Enter the master password and click **Create Database**.

> **Important:** The database name must match the subdomain. For `training.health.gov.xx`, name the database `training`.

**Option B — Duplicate an existing database:**

If you want the new database to be a copy of an existing one (e.g. copy production as a starting point for training):

1. Go to `https://ephem.health.gov.xx/web/database/manager`
2. Click **Duplicate** next to your existing database
3. Name the copy to match the new subdomain (e.g. `training`)

**Option C — Restore from a backup:**

1. Go to `https://training.health.gov.xx/web/database/manager`
2. Click **Restore Database**
3. Upload a `.zip` backup file
4. Name it to match the subdomain

### Disable Database Manager After Setup

Once all databases are created, disable the database manager page to prevent unauthorized access:

```bash
nano .env
```

Change:

```env
ODOO_LIST_DB=False
```

```bash
./setup.sh
```

---

## Duplicating Databases

Use this to create multiple copies of a configured database. This is useful when you need several identical environments — for example, setting up training rooms where each group gets their own database.

### Example: Setting Up Training Environments

Let's say you need 6 training databases (`training-01` through `training-06`), all identical.

**1. Add all domains at once:**

```bash
./scripts/add-domain.sh training-01.pheoc.com training-02.pheoc.com training-03.pheoc.com training-04.pheoc.com training-05.pheoc.com training-06.pheoc.com
```

**2. Create and configure `training-01`:**

Go to `https://training-01.pheoc.com/web/database/manager`, create the `training-01` database, install the ePHEM modules, set up users, configure settings — everything you want all training environments to have.

**3. Duplicate into all the others:**

```bash
./scripts/duplicate-db.sh training-01 training-02 training-03 training-04 training-05 training-06
```

That's it. All 6 databases are now identical copies — same modules, same users, same configuration. Each one is accessible at its own URL.

### Duplicating a Single Database

You can also duplicate just one:

```bash
./scripts/duplicate-db.sh production staging
```

This creates a `staging` database that's an exact copy of `production`.

### Overwriting Existing Databases

If any of the target databases already exist, the script will ask before overwriting:

```
! The following databases already exist:
  - training-02
  - training-03

Overwrite them? This will DELETE their data. (y/n)
```

Type `y` to replace them with fresh copies, or `n` to cancel.

> **Tip:** After duplicating, each database is completely independent. Changes to `training-01` will NOT affect `training-02` or any other copy.

---

## Updating ePHEM

### Update ePHEM Modules

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

Then in your browser, go to **Apps → Update Apps List** and upgrade the ePHEM modules.

### Update the Deployment Configuration

When the deployment repo is updated (new scripts, config changes):

```bash
cd ~/ephem-deploy
```

```bash
git pull
```

```bash
./setup.sh
```

> **Note:** `git pull` will never overwrite your `.env`, `nginx/active.conf`, or `odoo.conf` — these are either git-ignored or only modified by the setup scripts.

### Update the Odoo Base Image

When the ePHEM team announces a system update (security patches, new dependencies):

```bash
cd ~/ephem-deploy
```

```bash
./scripts/backup.sh
```

```bash
docker compose pull
```

```bash
docker compose up -d
```

> **Always back up before updating the base image.**

---

## Backups

### Manual Backup

```bash
./scripts/backup.sh
```

Backups are saved in the `backups/` folder with timestamps.

### Automatic Daily Backups

```bash
crontab -e
```

Add this line (replace the path):

```
0 2 * * * /home/YOUR_USERNAME/ephem-deploy/scripts/backup.sh >> /home/YOUR_USERNAME/ephem-deploy/backups/backup.log 2>&1
```

> **Find your path:** Run `pwd` inside the `ephem-deploy` folder.

Backups older than 14 days are automatically deleted.

> **Important:** Copy backups to a different location (USB drive, another server, cloud storage). If this server fails, local backups are lost too.

### Restore a Backup

```bash
docker compose stop odoo
```

```bash
gunzip < backups/production_20260402_020000.sql.gz | docker compose exec -T db psql -U odoo -d production
```

```bash
tar -xzf backups/filestore_production_20260402_020000.tar.gz -C ./odoo-data/filestore/
```

```bash
docker compose start odoo
```

---

## Day-to-Day Commands

Run these from inside the `ephem-deploy` folder.

| What you want to do | Command |
|---------------------|---------|
| Start the system | `docker compose up -d` |
| Stop the system | `docker compose down` |
| Restart Odoo | `docker compose restart odoo` |
| Restart everything | `docker compose restart` |
| Check status | `docker compose ps` |
| View Odoo logs | `docker compose logs -f odoo` |
| View all logs | `docker compose logs -f` |
| Run a backup | `./scripts/backup.sh` |
| Add a domain | `./scripts/add-domain.sh new.domain.com` |
| Duplicate a database | `./scripts/duplicate-db.sh source-db target-db1 target-db2` |
| Update ePHEM modules | `cd custom-addons && git pull && cd .. && docker compose restart odoo` |

> Press `Ctrl+C` to stop watching logs.

---

## SSL Renewal

Certificates renew automatically via the Certbot container.

To test:

```bash
docker compose run --rm --entrypoint "" certbot certbot renew --dry-run
```

---

## Troubleshooting

### Nothing loads in the browser

```bash
docker compose ps
```

If containers are down:

```bash
docker compose up -d
```

Check your domain points to the server:

```bash
dig +short ephem.health.gov.xx
```

### Odoo errors or blank pages

```bash
docker compose logs --tail=30 odoo
```

Look for lines with `ERROR` or `ValueError`.

### Database errors

```bash
docker compose exec db pg_isready -U odoo
```

### New domain shows wrong database

Make sure `ODOO_DBFILTER=^%d$` is set in `.env`, and the database name **exactly matches** the subdomain:

- `training.health.gov.xx` → database must be named `training`
- `simex.health.gov.xx` → database must be named `simex`

```bash
./setup.sh
```

### Custom modules not showing in Apps

```bash
ls custom-addons/
```

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

Re-run `./scripts/ssl-setup.sh`.

### Need to start completely fresh

> **Warning:** This deletes ALL data.

```bash
docker compose down -v
```

```bash
rm -f nginx/active.conf
```

```bash
./setup.sh
```

Then re-run `./scripts/ssl-setup.sh`.

---

## File Structure

```
ephem-deploy/
│
├── docker-compose.yml       ← Defines the containers
├── .env.example             ← Settings template — copy to .env
├── .env                     ← Your settings (passwords, domain) — never shared
├── odoo.conf                ← Odoo config (synced from .env by setup.sh)
├── setup.sh                 ← Run once to start, run again after updates
│
├── nginx/
│   ├── default.conf         ← HTTP-only template (in Git, never modified)
│   └── active.conf          ← Active NGINX config (git-ignored, created by scripts)
│
├── custom-addons/           ← ePHEM modules (from github.com/borse/ePHEM)
│
├── scripts/
│   ├── backup.sh            ← Backup all databases and filestore
│   ├── ssl-setup.sh         ← Set up SSL certificates (run once)
│   ├── add-domain.sh        ← Add new domains (training, simex, etc.)
│   └── duplicate-db.sh      ← Copy a database into multiple new ones
│
└── backups/                 ← Backup files (git-ignored)
```

**Created automatically by Docker:**

```
postgres-data/               ← Database files
odoo-data/                   ← Uploaded documents and images
```

---

## Security Notes

Built-in security:

- PostgreSQL and Odoo are **hidden from the internet** — only NGINX is exposed
- All traffic is **encrypted with HTTPS** (TLS 1.2+)
- **Security headers** protect against common web attacks
- **Rate limiting** prevents abuse
- Containers run on a **private Docker network**
- SSL certificates **renew automatically**

**Recommended after installation:**

- Disable password-based SSH login (use SSH keys only)
- Install fail2ban:
  ```bash
  sudo apt install -y fail2ban
  ```
- Copy backups to a different location regularly
- Enable **two-factor authentication** for admin users (Settings → General Settings → Permissions)
- Disable the database manager after setup (set `ODOO_LIST_DB=False` in `.env`)

---

## Need Help?

1. Check [Troubleshooting](#troubleshooting) above
2. Run `docker compose logs` and share the output with the ePHEM team
3. Open an issue: [github.com/borse/ephem_deployment_docker/issues](https://github.com/borse/ephem_deployment_docker/issues)