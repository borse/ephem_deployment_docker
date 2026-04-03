# Odoo 18 — Docker Deployment Guide

![Odoo](https://img.shields.io/badge/Odoo-18.0-714B67?logo=odoo&logoColor=white)
![Docker](https://img.shields.io/badge/Docker-Compose-2496ED?logo=docker&logoColor=white)
![NGINX](https://img.shields.io/badge/NGINX-reverse--proxy-009639?logo=nginx&logoColor=white)
![Let's Encrypt](https://img.shields.io/badge/SSL-Let's%20Encrypt-003A70?logo=letsencrypt&logoColor=white)

Deploy a production-ready Odoo 18 instance with a single command. This setup supports **multiple databases** (production, staging, training) from the same installation.

---

## Table of Contents

- [Overview](#overview)
- [What You Get](#what-you-get)
- [Prerequisites](#prerequisites)
- [Quick Start](#quick-start)
  - [1. Install Docker](#1-install-docker)
  - [2. Clone This Repo](#2-clone-this-repo)
  - [3. Configure Your Environment](#3-configure-your-environment)
  - [4. Start Everything](#4-start-everything)
  - [5. Set Up SSL](#5-set-up-ssl)
  - [6. Access Odoo](#6-access-odoo)
- [Multiple Databases](#multiple-databases)
  - [Creating Databases](#creating-databases)
  - [Domain Routing](#domain-routing)
  - [Locking It Down](#locking-it-down)
- [Custom Addons](#custom-addons)
- [Backups](#backups)
  - [Manual Backup](#manual-backup)
  - [Automatic Daily Backups](#automatic-daily-backups)
  - [Restore a Backup](#restore-a-backup)
- [Common Commands](#common-commands)
- [Updating Odoo](#updating-odoo)
- [SSL Renewal](#ssl-renewal)
- [Troubleshooting](#troubleshooting)
- [File Structure](#file-structure)
- [Security Notes](#security-notes)

---

## Overview

This deployment uses three containers managed by Docker Compose:

| Container | Role | Exposed |
|-----------|------|---------|
| `nginx` | Reverse proxy, SSL termination | Ports 80, 443 |
| `odoo` | Odoo 18 application | Internal only |
| `db` | PostgreSQL 16 database | Internal only |

PostgreSQL and Odoo are **never exposed** to the internet. All traffic goes through NGINX.

---

## What You Get

- Odoo 18 with PostgreSQL 16
- NGINX reverse proxy with SSL (Let's Encrypt)
- Support for multiple databases (production, staging, training)
- Automated daily backups with 14-day retention
- Custom addons via a mounted folder
- Persistent data (survives container restarts and updates)
- Hardened configuration out of the box

---

## Prerequisites

- A Linux server (Ubuntu 22.04+ recommended) with at least 2 GB RAM
- A domain name pointed at your server's IP address
- SSH access to the server

---

## Quick Start

### 1. Install Docker

```bash
curl -fsSL https://get.docker.com | sh
```

```bash
sudo usermod -aG docker $USER
```

Log out and back in for the group change to take effect:

```bash
exit
```

Then reconnect via SSH and verify:

```bash
docker --version
```

### 2. Clone This Repo

```bash
git clone https://github.com/YOUR_ORG/YOUR_REPO.git odoo-deploy
```

```bash
cd odoo-deploy
```

### 3. Configure Your Environment

Copy the example environment file:

```bash
cp .env.example .env
```

Edit it with your values:

```bash
nano .env
```

You **must** change these three values:

```env
# Your domain name (no www, no https)
DOMAIN=ephem.health.gov.xx

# Database password — generate a strong one
POSTGRES_PASSWORD=CHANGE_ME_TO_SOMETHING_STRONG

# Odoo master password — used to create/delete databases
ODOO_ADMIN_PASSWORD=CHANGE_ME_TO_SOMETHING_STRONG
```

> **Tip:** Generate strong passwords with:
> ```bash
> openssl rand -base64 24
> ```

Save and exit (`Ctrl+O`, `Enter`, `Ctrl+X`).

### 4. Start Everything

```bash
docker compose up -d
```

Check that all three containers are running:

```bash
docker compose ps
```

You should see `nginx`, `odoo`, and `db` all with status `Up`.

### 5. Set Up SSL

Get a certificate for your domain:

```bash
docker compose exec nginx certbot --nginx -d ephem.health.gov.xx --non-interactive --agree-tos -m admin@health.gov.xx
```

> **Replace** `ephem.health.gov.xx` with your actual domain and `admin@health.gov.xx` with your email.

Restart NGINX to apply:

```bash
docker compose restart nginx
```

### 6. Access Odoo

Open your browser and go to:

```
https://ephem.health.gov.xx
```

You will see the database creation page. Fill in:

- **Master Password:** the `ODOO_ADMIN_PASSWORD` you set in `.env`
- **Database Name:** e.g. `production`
- **Email:** your admin email
- **Password:** your Odoo admin password
- **Language:** your preferred language
- **Country:** your country

Click **Create Database** and wait. This can take a minute.

---

## Multiple Databases

One Odoo installation can serve multiple independent databases. Each database is a completely separate Odoo instance with its own users, modules, and data.

### Creating Databases

Go to:

```
https://ephem.health.gov.xx/web/database/manager
```

Enter the master password and create additional databases. For example:

| Database Name | Purpose |
|---------------|---------|
| `production` | Live data |
| `staging` | Testing before changes go live |
| `training` | Staff training with sample data |

You can switch between databases from the login screen.

### Domain Routing

If you have multiple subdomains, you can route each one to a specific database automatically.

Point your DNS records:

```
ephem.health.gov.xx       → your server IP
staging.ephem.health.gov.xx    → your server IP
training.ephem.health.gov.xx   → your server IP
```

Get SSL certificates for all domains:

```bash
docker compose exec nginx certbot --nginx -d ephem.health.gov.xx -d staging.ephem.health.gov.xx -d training.ephem.health.gov.xx --non-interactive --agree-tos -m admin@health.gov.xx
```

Then in your `.env` file, set:

```env
ODOO_DBFILTER=^%d$
```

This tells Odoo to match the subdomain to the database name. So `staging.ephem.health.gov.xx` will automatically connect to the `staging` database.

Restart Odoo to apply:

```bash
docker compose restart odoo
```

### Locking It Down

After creating all the databases you need, disable the database manager page to prevent unauthorized database creation:

In `.env`, set:

```env
ODOO_LIST_DB=False
```

```bash
docker compose restart odoo
```

---

## Custom Addons

Place your custom addon modules in the `custom-addons/` folder:

```bash
ls custom-addons/
```

If you're cloning from a Git repository:

```bash
git clone git@github.com:YOUR_ORG/YOUR_ADDONS.git custom-addons
```

After adding new addons, restart Odoo:

```bash
docker compose restart odoo
```

Then in Odoo, go to **Apps → Update Apps List** and install your modules.

---

## Backups

### Manual Backup

Run the backup script:

```bash
./scripts/backup.sh
```

This creates a timestamped database dump and filestore archive in the `backups/` folder.

### Automatic Daily Backups

Set up a daily cron job:

```bash
crontab -e
```

Add:

```
0 2 * * * /path/to/odoo-deploy/scripts/backup.sh >> /path/to/odoo-deploy/backups/backup.log 2>&1
```

> **Replace** `/path/to/odoo-deploy` with the actual path where you cloned the repo.

Backups older than 14 days are automatically deleted.

### Restore a Backup

Stop Odoo first:

```bash
docker compose stop odoo
```

Restore the database:

```bash
gunzip < backups/production_20260402_020000.sql.gz | docker compose exec -T db psql -U odoo -d production
```

Restore the filestore:

```bash
tar -xzf backups/filestore_production_20260402_020000.tar.gz -C ./odoo-data/filestore/
```

Start Odoo again:

```bash
docker compose start odoo
```

---

## Common Commands

| Action | Command |
|--------|---------|
| Start all services | `docker compose up -d` |
| Stop all services | `docker compose down` |
| Restart Odoo | `docker compose restart odoo` |
| View Odoo logs | `docker compose logs -f odoo` |
| View all logs | `docker compose logs -f` |
| Open a shell in the Odoo container | `docker compose exec odoo bash` |
| Open a PostgreSQL prompt | `docker compose exec db psql -U odoo` |
| Check container status | `docker compose ps` |

---

## Updating Odoo

Pull the latest Odoo 18 image:

```bash
docker compose pull odoo
```

Restart with the new image:

```bash
docker compose up -d
```

> **Important:** Always back up your databases before updating.

---

## SSL Renewal

Certificates auto-renew via a cron inside the NGINX container. Verify it's working:

```bash
docker compose exec nginx certbot renew --dry-run
```

If auto-renewal is not set up, add a host-level cron:

```bash
crontab -e
```

```
0 3 * * * cd /path/to/odoo-deploy && docker compose exec -T nginx certbot renew --quiet && docker compose restart nginx
```

---

## Troubleshooting

**Odoo won't start**

```bash
docker compose logs odoo
```

Look for Python errors or database connection issues.

**Can't reach the site**

Check that all containers are running:

```bash
docker compose ps
```

Check that your domain points to the server:

```bash
dig +short ephem.health.gov.xx
```

Check NGINX logs:

```bash
docker compose logs nginx
```

**Database connection errors**

Verify the database container is healthy:

```bash
docker compose exec db pg_isready -U odoo
```

**Permission errors on custom addons**

Make sure the folder is readable:

```bash
chmod -R 755 custom-addons/
```

**SSL certificate errors**

Make sure port 80 is open (Certbot needs it for verification):

```bash
sudo ufw allow 80
```

```bash
sudo ufw allow 443
```

---

## File Structure

```
odoo-deploy/
├── docker-compose.yml          # Container definitions
├── .env.example                # Template — copy to .env
├── .env                        # Your config (git-ignored)
├── nginx/
│   └── default.conf            # NGINX reverse proxy config
├── odoo.conf                   # Odoo server configuration
├── custom-addons/              # Your custom Odoo modules
├── scripts/
│   └── backup.sh               # Backup script
├── backups/                    # Backup files (git-ignored)
├── odoo-data/                  # Odoo filestore (git-ignored)
├── postgres-data/              # PostgreSQL data (git-ignored)
└── README.md                   # This file
```

---

## Security Notes

This deployment includes the following security measures out of the box:

- PostgreSQL and Odoo are **never exposed** to the internet — only NGINX is public
- NGINX uses **TLS 1.2+ only** with strong cipher suites
- Security headers are set: `HSTS`, `X-Frame-Options`, `X-Content-Type-Options`, `Referrer-Policy`
- The database manager page can be disabled via `.env`
- Odoo binds to an internal Docker network, not to `0.0.0.0`
- Backup script included with automatic retention

**Recommended additional steps:**

- Change the default SSH port and disable password login on your server
- Install `fail2ban` on the host server
- Set up off-site backup copies (S3, rsync, etc.)
- Enable Odoo's built-in two-factor authentication for admin users
- Review the [full hardening guide](README.md) for server-level security
