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
  - [Step 3 — Download the ePHEM Modules](#step-3--download-the-ephem-modules)
  - [Step 4 — Configure Your Settings](#step-4--configure-your-settings)
  - [Step 5 — Start the System](#step-5--start-the-system)
  - [Step 6 — Set Up SSL (HTTPS)](#step-6--set-up-ssl-https)
  - [Step 7 — Open ePHEM in Your Browser](#step-7--open-ephem-in-your-browser)
- [Updating ePHEM](#updating-ephem)
- [Multiple Databases](#multiple-databases)
- [Backups](#backups)
- [Day-to-Day Commands](#day-to-day-commands)
- [SSL Renewal](#ssl-renewal)
- [Troubleshooting](#troubleshooting)
- [File Structure](#file-structure)
- [Security Notes](#security-notes)
- [Need Help?](#need-help)

---

## How This Works

### What is Docker?

Docker is a tool that runs software in **containers** — pre-packaged boxes that include everything an application needs. Instead of spending hours installing software manually, Docker does it in minutes with a single command.

Think of it like this: instead of building a house brick by brick, Docker places a fully built house on your land.

### What happens when you start ePHEM?

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
│     │                    │                                   │
│  open to             reads from                              │
│  the internet        custom-addons/                          │
│  (ports 80,443)      (your ePHEM modules)                    │
└──────┼───────────────────────────────────────────────────────┘
       │
    Users open ePHEM in their browser
```

| Container | What it does |
|-----------|-------------|
| **NGINX** | The front door. Handles HTTPS and forwards traffic to Odoo. The only part visible from the internet. |
| **Odoo** | The ePHEM application. Runs using a **pre-built image** that already has all system software installed — you don't need to install anything manually. |
| **PostgreSQL** | The database. Stores all your data. Hidden from the internet. |

### Where does the software come from?

| What | Where it comes from | What you do |
|------|-------------------|-------------|
| **Odoo 18 + system packages** | A pre-built Docker image published by the ePHEM team. Already contains everything Odoo needs to run. | Nothing — Docker downloads it automatically when you start the system. |
| **ePHEM modules** | [github.com/borse/ePHEM](https://github.com/borse/ePHEM) | You download them once (Step 3) and update them with `git pull` when new versions are released. |
| **Deployment files** | [github.com/borse/ephem_deployment_docker](https://github.com/borse/ephem_deployment_docker) — this repo | You download them once (Step 2). These tell Docker how to set everything up. |

### How do updates work?

When the ePHEM team releases new features or fixes:

```bash
cd custom-addons
git pull
cd ..
docker compose restart odoo
```

That's it — four commands. No reinstalling, no rebuilding.

---

## What You Need Before Starting

- **A Linux server** — Ubuntu 22.04 or newer, with at least 2 GB RAM
- **A domain name** pointed at your server's IP address (e.g. `ephem.health.gov.xx`). Ask your IT team to create a **DNS A record** that points the domain to the server.
- **SSH access** to the server (PuTTY on Windows, Terminal on Mac/Linux)

> **Check if your domain is set up correctly:**
>
> From your computer, run:
> ```bash
> ping ephem.health.gov.xx
> ```
> If it shows your server's IP address, you're ready. If not, contact your IT team.

---

## Installation

Connect to your server via SSH. Run all commands below on the server.

### Step 1 — Install Docker

```bash
curl -fsSL https://get.docker.com | sh
```

```bash
sudo usermod -aG docker $USER
```

Log out and back in for the change to take effect:

```bash
exit
```

Reconnect via SSH, then check Docker is installed:

```bash
docker --version
```

You should see `Docker version 27.x.x` or similar. If you see "command not found", run the install command again.

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
> Then run the `git clone` command again.

### Step 3 — Download the ePHEM Modules

```bash
rm -rf custom-addons
```

```bash
git clone https://github.com/borse/ePHEM.git custom-addons
```

> The first command removes the placeholder folder. The second downloads the ePHEM modules.

### Step 4 — Configure Your Settings

```bash
cp .env.example .env
```

```bash
nano .env
```

**Change these three values:**

```env
DOMAIN=ephem.health.gov.xx
POSTGRES_PASSWORD=CHANGE_ME
ODOO_ADMIN_PASSWORD=CHANGE_ME
```

Replace `ephem.health.gov.xx` with your actual domain. Replace `CHANGE_ME` with strong passwords.

> **Generate a strong password:**
> ```bash
> openssl rand -base64 24
> ```
> Use a **different** password for each one.

**Save the file:** Press `Ctrl+O`, then `Enter`, then `Ctrl+X`.

### Step 5 — Start the System

```bash
docker compose up -d
```

> **First time:** This takes 2–5 minutes to download the software (~1 GB). Future starts are almost instant.

Check everything is running:

```bash
docker compose ps
```

You should see `ephem-nginx`, `ephem-app`, and `ephem-db` all with status **Up**.

If something shows **Exited** or **Restarting**, check what went wrong:

```bash
docker compose logs
```

### Step 6 — Set Up SSL (HTTPS)

Replace `ephem.health.gov.xx` and `admin@health.gov.xx` with your actual domain and email:

```bash
docker compose exec nginx certbot --nginx -d ephem.health.gov.xx --non-interactive --agree-tos -m admin@health.gov.xx
```

```bash
docker compose restart nginx
```

> **If this fails:**
> - Make sure your domain points to the server: `ping ephem.health.gov.xx`
> - Open the firewall ports:
>   ```bash
>   sudo ufw allow 80
>   ```
>   ```bash
>   sudo ufw allow 443
>   ```

### Step 7 — Open ePHEM in Your Browser

Go to:

```
https://ephem.health.gov.xx
```

You'll see the database creation page:

| Field | What to enter |
|-------|--------------|
| **Master Password** | The `ODOO_ADMIN_PASSWORD` from Step 4 |
| **Database Name** | `production` |
| **Email** | Your admin email |
| **Password** | Choose a password for the admin user |
| **Language** | Your language |
| **Country** | Your country |

Click **Create Database** (takes 1–2 minutes).

After login, go to **Apps → Update Apps List**, then install the ePHEM modules.

🎉 **ePHEM is running!**

---

## Updating ePHEM

When the ePHEM team announces a new release, run these commands on your server:

```bash
cd ephem-deploy/custom-addons
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

> **If the ePHEM team announces a system update** (not just module changes), also run:
> ```bash
> docker compose pull
> ```
> ```bash
> docker compose up -d
> ```
> This downloads the latest version of the base image.

---

## Multiple Databases

You can run multiple databases on the same server — for example production, staging, and training. Each database is completely independent.

### Create additional databases

Go to:

```
https://ephem.health.gov.xx/web/database/manager
```

Enter the master password and create new databases.

| Database Name | Purpose |
|---------------|---------|
| `production` | Live system |
| `staging` | Testing changes |
| `training` | Staff training |

Switch between them from the login screen.

### Route subdomains to databases (optional)

If you want `staging.ephem.health.gov.xx` to go directly to the `staging` database:

**1.** Ask IT to point the subdomains to your server IP.

**2.** Get SSL certificates for all of them:

```bash
docker compose exec nginx certbot --nginx -d ephem.health.gov.xx -d staging.ephem.health.gov.xx -d training.ephem.health.gov.xx --non-interactive --agree-tos -m admin@health.gov.xx
```

**3.** Edit `.env` and set:

```env
ODOO_DBFILTER=^%d$
```

**4.** Restart:

```bash
docker compose restart odoo
```

### Disable the database manager

After creating all databases you need, prevent new ones from being created via the web:

Edit `.env` and set:

```env
ODOO_LIST_DB=False
```

```bash
docker compose restart odoo
```

---

## Backups

### Run a backup now

```bash
./scripts/backup.sh
```

Backups are saved in the `backups/` folder.

### Automatic daily backups

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

### Restore from backup

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
| Update ePHEM modules | `cd custom-addons && git pull && cd .. && docker compose restart odoo` |

> Press `Ctrl+C` to stop watching logs.

---

## SSL Renewal

Certificates renew automatically. To verify:

```bash
docker compose exec nginx certbot renew --dry-run
```

If it says "all simulated renewals succeeded", you're fine.

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
docker compose logs odoo
```

Look for lines with `ERROR`.

### Database errors

```bash
docker compose exec db pg_isready -U odoo
```

### ePHEM modules not showing in Apps

```bash
ls custom-addons/
```

If empty, re-run Step 3. Then:

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

Re-run the Certbot command from [Step 6](#step-6--set-up-ssl-https).

### Start completely fresh

> **Warning:** This deletes ALL data.

```bash
docker compose down -v
```

```bash
docker compose up -d
```

---

## File Structure

```
ephem-deploy/
│
├── docker-compose.yml       ← Defines the containers
├── .env.example             ← Settings template — copy to .env
├── .env                     ← Your settings (never share this)
│
├── nginx/
│   └── default.conf         ← Web server configuration
│
├── custom-addons/           ← ePHEM modules (from github.com/borse/ePHEM)
│
├── scripts/
│   └── backup.sh            ← Backup script
│
└── backups/                 ← Backup files
```

Created automatically by Docker (your data, not in Git):

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
- Containers run on a **private network** inside Docker
- SSL certificates **renew automatically**

**Recommended after installation:**

- Disable password-based SSH login on your server (use SSH keys only)
- Install fail2ban to block brute-force attacks:
  ```bash
  sudo apt install -y fail2ban
  ```
- Copy backups off the server regularly
- Enable **two-factor authentication** in Odoo for admin users (Settings → General Settings → Permissions)
- Disable the database manager after setup (see [Multiple Databases](#disable-the-database-manager))

---

## Need Help?

1. Check [Troubleshooting](#troubleshooting) above
2. Run `docker compose logs` and share the output with the ePHEM team
3. Open an issue: [github.com/borse/ephem_deployment_docker/issues](https://github.com/borse/ephem_deployment_docker/issues)
