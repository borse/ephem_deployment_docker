# ePHEM — Docker Deployment Guide

![Odoo](https://img.shields.io/badge/Odoo-18.0-714B67?logo=odoo&logoColor=white)
![Docker](https://img.shields.io/badge/Docker-Compose-2496ED?logo=docker&logoColor=white)
![NGINX](https://img.shields.io/badge/NGINX-reverse--proxy-009639?logo=nginx&logoColor=white)
![Let's Encrypt](https://img.shields.io/badge/SSL-Let's%20Encrypt-003A70?logo=letsencrypt&logoColor=white)

This guide will help you deploy ePHEM (built on Odoo 18) on your server. No prior Docker experience is required — just follow the steps in order.

---

## Table of Contents

- [How This Works](#how-this-works)
- [What You Need Before Starting](#what-you-need-before-starting)
- [Step-by-Step Installation](#step-by-step-installation)
  - [Step 1 — Install Docker](#step-1--install-docker)
  - [Step 2 — Download the Deployment Files](#step-2--download-the-deployment-files)
  - [Step 3 — Download the ePHEM Custom Modules](#step-3--download-the-ephem-custom-modules)
  - [Step 4 — Configure Your Settings](#step-4--configure-your-settings)
  - [Step 5 — Start the System](#step-5--start-the-system)
  - [Step 6 — Set Up SSL (HTTPS)](#step-6--set-up-ssl-https)
  - [Step 7 — Open ePHEM in Your Browser](#step-7--open-ephem-in-your-browser)
- [Multiple Databases](#multiple-databases)
  - [Creating Databases](#creating-databases)
  - [Domain Routing (Optional)](#domain-routing-optional)
  - [Locking It Down](#locking-it-down)
- [Backups](#backups)
  - [Manual Backup](#manual-backup)
  - [Automatic Daily Backups](#automatic-daily-backups)
  - [Restore a Backup](#restore-a-backup)
- [Day-to-Day Commands](#day-to-day-commands)
- [Updating](#updating)
- [SSL Renewal](#ssl-renewal)
- [Troubleshooting](#troubleshooting)
- [File Structure](#file-structure)
- [Security Notes](#security-notes)
- [Need Help?](#need-help)

---

## How This Works

Before you start, here's a simple explanation of what's happening behind the scenes.

### What is Docker?

Docker is a tool that packages software into **containers** — self-contained boxes that include everything an application needs to run. Instead of manually installing Odoo, PostgreSQL, and NGINX on your server (which can take hours and is error-prone), Docker does it all for you in minutes.

Think of it like this: instead of building a house brick by brick, you're placing a pre-built house on your land.

### What gets installed?

When you run `docker compose up -d`, Docker automatically downloads and starts **three containers** that work together:

```
┌─────────────────────────────────────────────────────────────┐
│  Your Server                                                │
│                                                             │
│  ┌─────────────┐    ┌─────────────┐    ┌─────────────────┐  │
│  │   NGINX     │───▶│   Odoo 18   │───▶│  PostgreSQL 16  │  │
│  │  (web gate) │    │   (ePHEM)   │    │   (database)    │  │
│  └─────────────┘    └─────────────┘    └─────────────────┘  │
│     ▲                                                       │
│     │ ports 80 & 443 (only these are open to the internet)  │
└─────┼───────────────────────────────────────────────────────┘
      │
   Users access ePHEM through their browser
```

| Container | What it does |
|-----------|-------------|
| **NGINX** | The front door. Receives all web traffic, handles HTTPS encryption, and forwards requests to Odoo. This is the only container visible to the internet. |
| **Odoo** | The ePHEM application itself. Runs the Odoo 18 software with your custom ePHEM modules. Not directly accessible from the internet — only NGINX can talk to it. |
| **PostgreSQL** | The database. Stores all your data (users, records, settings). Also not accessible from the internet — only Odoo can talk to it. |

### Where does the code come from?

There are **three separate repositories** (code storage locations) involved. You don't need to understand Git in detail — just follow the clone commands in the steps below.

| Repository | What's inside | Do I download it manually? |
|-----------|--------------|---------------------------|
| **This repo** — [borse/ephem_deployment_docker](https://github.com/borse/ephem_deployment_docker) | Docker configuration, NGINX config, backup scripts, this README. These are the "instructions" that tell Docker how to set everything up. | **Yes** — Step 2 |
| **ePHEM addons** — [borse/ePHEM](https://github.com/borse/ePHEM) | The custom ePHEM modules that add health emergency management features to Odoo. | **Yes** — Step 3 |
| **Odoo 18** — [odoo/odoo](https://github.com/odoo/odoo) | The core Odoo software. | **No** — Docker downloads this automatically. You never need to touch this. |

---

## What You Need Before Starting

Before you begin, make sure you have:

- **A Linux server** — Ubuntu 22.04 or newer is recommended, with at least 2 GB of RAM
- **A domain name** — for example `ephem.health.gov.xx` — already pointed at your server's IP address (ask your IT team to create a DNS A record)
- **SSH access** — the ability to connect to your server via terminal (PuTTY on Windows, Terminal on Mac/Linux)

> **How to check if your domain is pointed correctly:**
>
> From your local computer, run:
> ```bash
> ping ephem.health.gov.xx
> ```
> If it shows your server's IP address, you're good to go. If not, contact your IT team to set up the DNS record.

---

## Step-by-Step Installation

Connect to your server via SSH. All commands below are run on the server.

### Step 1 — Install Docker

This installs Docker (the container engine) on your server:

```bash
curl -fsSL https://get.docker.com | sh
```

Add your user to the Docker group so you can run Docker commands without `sudo`:

```bash
sudo usermod -aG docker $USER
```

**Important:** You must log out and log back in for this to take effect:

```bash
exit
```

Reconnect to your server via SSH, then verify Docker is installed:

```bash
docker --version
```

You should see something like `Docker version 27.x.x`. If you see "command not found", the installation failed — try running the install command again.

### Step 2 — Download the Deployment Files

This downloads the Docker configuration files to your server:

```bash
git clone https://github.com/borse/ephem_deployment_docker.git ephem-deploy
```

Enter the folder:

```bash
cd ephem-deploy
```

> **If you see "git: command not found"**, install Git first:
> ```bash
> sudo apt install -y git
> ```
> Then run the `git clone` command again.

### Step 3 — Download the ePHEM Custom Modules

This downloads the ePHEM modules into the `custom-addons` folder:

```bash
rm -rf custom-addons
```

```bash
git clone https://github.com/borse/ePHEM.git custom-addons
```

> **What just happened?** The first command removes the placeholder folder that came with the deployment files. The second command downloads the actual ePHEM code into its place.

### Step 4 — Configure Your Settings

Copy the example settings file to create your own:

```bash
cp .env.example .env
```

Open it for editing:

```bash
nano .env
```

You will see a file with several settings. **You must change these three values:**

```env
# Replace with your actual domain name (no www, no https)
DOMAIN=ephem.health.gov.xx

# Replace with a strong password for the database
POSTGRES_PASSWORD=CHANGE_ME_TO_SOMETHING_STRONG

# Replace with a strong master password for Odoo
ODOO_ADMIN_PASSWORD=CHANGE_ME_TO_SOMETHING_STRONG
```

> **How to generate a strong password:**
>
> Run this command in a separate terminal and copy the output:
> ```bash
> openssl rand -base64 24
> ```
> Use a **different** password for `POSTGRES_PASSWORD` and `ODOO_ADMIN_PASSWORD`.

**How to save the file in nano:**

1. Press `Ctrl+O` (the letter O, not zero)
2. Press `Enter` to confirm the filename
3. Press `Ctrl+X` to exit the editor

### Step 5 — Start the System

This single command downloads Odoo 18, PostgreSQL, and NGINX, then starts everything:

```bash
docker compose up -d
```

> **First time only:** This will take 2–5 minutes as Docker downloads the required software (~1 GB). Future starts will be almost instant since the downloads are cached.

Check that everything is running:

```bash
docker compose ps
```

You should see three containers (`odoo-nginx`, `odoo-app`, `odoo-db`) all with status **Up** or **running**.

If any container shows **Exited** or **Restarting**, something went wrong. Check the logs:

```bash
docker compose logs
```

### Step 6 — Set Up SSL (HTTPS)

This gives your site a security certificate so browsers show the padlock icon and the connection is encrypted.

**Replace `ephem.health.gov.xx` with your actual domain** and **replace `admin@health.gov.xx` with your email** in the command below:

```bash
docker compose exec nginx certbot --nginx -d ephem.health.gov.xx --non-interactive --agree-tos -m admin@health.gov.xx
```

If successful, restart NGINX to apply the certificate:

```bash
docker compose restart nginx
```

> **If this fails**, make sure:
>
> - Your domain actually points to this server (run `ping ephem.health.gov.xx` — it should show your server IP)
> - Ports 80 and 443 are open on your firewall:
>   ```bash
>   sudo ufw allow 80
>   ```
>   ```bash
>   sudo ufw allow 443
>   ```

### Step 7 — Open ePHEM in Your Browser

Open your web browser and go to:

```
https://ephem.health.gov.xx
```

You will see the Odoo database creation page. Fill in the form:

| Field | What to enter |
|-------|--------------|
| **Master Password** | The `ODOO_ADMIN_PASSWORD` you set in Step 4 |
| **Database Name** | `production` (or any name you prefer) |
| **Email** | Your admin email address |
| **Password** | Choose a password for the Odoo admin user |
| **Language** | Your preferred language |
| **Country** | Your country |

Click **Create Database** and wait — this takes 1–2 minutes.

Once complete, you'll be logged into ePHEM. Go to **Apps → Update Apps List**, then search for and install the ePHEM modules.

🎉 **Congratulations — ePHEM is now running!**

---

## Multiple Databases

You can run multiple independent databases on the same installation. Each database is completely separate — it has its own users, data, and installed modules.

This is useful for having production, staging, and training environments **without needing multiple servers**.

### Creating Databases

Go to:

```
https://ephem.health.gov.xx/web/database/manager
```

Enter the master password (`ODOO_ADMIN_PASSWORD` from your `.env` file) and create additional databases:

| Database Name | Purpose |
|---------------|---------|
| `production` | Live data — the real system |
| `staging` | For testing changes before applying them to production |
| `training` | For staff training with sample data |

You can switch between databases from the Odoo login screen.

### Domain Routing (Optional)

If you have multiple subdomains, you can make each one go directly to a specific database. For example:

| URL | Goes to database |
|-----|-----------------|
| `ephem.health.gov.xx` | `production` |
| `staging.ephem.health.gov.xx` | `staging` |
| `training.ephem.health.gov.xx` | `training` |

**To set this up:**

**1.** Ask your IT team to create DNS A records pointing all subdomains to your server IP:

```
ephem.health.gov.xx            → your server IP
staging.ephem.health.gov.xx    → your server IP
training.ephem.health.gov.xx   → your server IP
```

**2.** Get SSL certificates for all domains (replace with your actual domains and email):

```bash
docker compose exec nginx certbot --nginx -d ephem.health.gov.xx -d staging.ephem.health.gov.xx -d training.ephem.health.gov.xx --non-interactive --agree-tos -m admin@health.gov.xx
```

**3.** Open your `.env` file:

```bash
nano .env
```

Find the `ODOO_DBFILTER` line and change it to:

```env
ODOO_DBFILTER=^%d$
```

Save and exit (`Ctrl+O`, `Enter`, `Ctrl+X`).

**4.** Restart Odoo:

```bash
docker compose restart odoo
```

Now each subdomain automatically connects to the database that matches its name.

### Locking It Down

After creating all the databases you need, **disable the database manager page** to prevent anyone from creating or deleting databases through the web.

Open your `.env` file:

```bash
nano .env
```

Find the `ODOO_LIST_DB` line and change it to:

```env
ODOO_LIST_DB=False
```

Save the file and restart:

```bash
docker compose restart odoo
```

---

## Backups

### Manual Backup

Run the backup script from inside the `ephem-deploy` folder:

```bash
./scripts/backup.sh
```

This creates a timestamped backup of all databases and the filestore in the `backups/` folder.

### Automatic Daily Backups

To back up automatically every night at 2 AM:

```bash
crontab -e
```

If asked which editor to use, choose `nano` (usually option 1).

Add this line at the bottom (replace the path with your actual path):

```
0 2 * * * /home/YOUR_USERNAME/ephem-deploy/scripts/backup.sh >> /home/YOUR_USERNAME/ephem-deploy/backups/backup.log 2>&1
```

> **How to find your actual path:** Run `pwd` inside the `ephem-deploy` folder and use that path.

Save and exit (`Ctrl+O`, `Enter`, `Ctrl+X`).

Backups older than 14 days are automatically deleted to save disk space.

> **Important:** These backups are stored on the same server. If the server dies, the backups are lost too. We strongly recommend copying backups to another location (a different server, USB drive, or cloud storage).

### Restore a Backup

If you need to restore from a backup:

Stop Odoo:

```bash
docker compose stop odoo
```

Restore the database (replace the filename with your actual backup file):

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

## Day-to-Day Commands

Here are the commands you'll use most often. **Run these from inside the `ephem-deploy` folder.**

| What you want to do | Command |
|---------------------|---------|
| **Start** the system | `docker compose up -d` |
| **Stop** the system | `docker compose down` |
| **Restart** Odoo (after config changes) | `docker compose restart odoo` |
| **Restart** everything | `docker compose restart` |
| **Check** if everything is running | `docker compose ps` |
| **View** Odoo logs (to diagnose problems) | `docker compose logs -f odoo` |
| **View** all logs | `docker compose logs -f` |
| **Run** a manual backup | `./scripts/backup.sh` |

> **Tip:** When viewing logs with `docker compose logs -f`, new log lines appear in real time. Press `Ctrl+C` to stop watching and return to the command prompt.

---

## Updating

### Update ePHEM Modules

When new ePHEM features or fixes are released:

```bash
cd custom-addons
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

### Update Odoo 18

To get the latest Odoo 18 security patches and bug fixes:

> **Always run a backup before updating:**
> ```bash
> ./scripts/backup.sh
> ```

```bash
docker compose pull odoo
```

```bash
docker compose up -d
```

---

## SSL Renewal

SSL certificates from Let's Encrypt expire every 90 days. The Certbot container in this setup **automatically renews them** — you don't need to do anything.

To verify auto-renewal is working:

```bash
docker compose exec nginx certbot renew --dry-run
```

If you see "Congratulations, all simulated renewals succeeded", you're all set.

If auto-renewal is not working, set up a manual renewal cron:

```bash
crontab -e
```

Add this line (replace the path with your actual path):

```
0 3 * * * cd /home/YOUR_USERNAME/ephem-deploy && docker compose exec -T nginx certbot renew --quiet && docker compose restart nginx
```

---

## Troubleshooting

### ePHEM shows a blank page or error

Check the Odoo logs for error messages:

```bash
docker compose logs odoo
```

Look for lines containing `ERROR` or `Traceback`. These will tell you what went wrong.

### Can't reach the site at all

First, check if the containers are running:

```bash
docker compose ps
```

If any container is not running, check its logs:

```bash
docker compose logs nginx
```

```bash
docker compose logs odoo
```

```bash
docker compose logs db
```

Check that your domain points to this server:

```bash
dig +short ephem.health.gov.xx
```

This should print your server's IP address. If it doesn't, your DNS is not set up correctly — contact your IT team.

### "Database connection error"

Check if the database container is running and healthy:

```bash
docker compose exec db pg_isready -U odoo
```

If it says "accepting connections", the database is fine — check Odoo logs for the real error.

### Custom ePHEM modules not showing up in Apps

Make sure the `custom-addons` folder has the modules:

```bash
ls custom-addons/
```

You should see folders with names like `ephem_core`, `ephem_base`, etc. If the folder is empty, re-run Step 3.

Fix permissions if needed:

```bash
chmod -R 755 custom-addons/
```

Restart Odoo:

```bash
docker compose restart odoo
```

Then in your browser, go to **Apps → Update Apps List**.

### SSL certificate errors

Make sure ports 80 and 443 are open:

```bash
sudo ufw allow 80
```

```bash
sudo ufw allow 443
```

Re-run the Certbot command from [Step 6](#step-6--set-up-ssl-https).

### Need to start over completely

If something is badly broken and you want to start fresh:

> **Warning:** This will delete ALL data including databases. Run a backup first if you have any important data.

```bash
docker compose down -v
```

```bash
docker compose up -d
```

Then repeat from [Step 7](#step-7--open-ephem-in-your-browser).

---

## File Structure

Here's what each file and folder does:

```
ephem-deploy/
│
├── docker-compose.yml       ← Tells Docker which containers to run and how they connect
├── .env.example             ← Template for your settings — copy this to .env
├── .env                     ← YOUR settings (passwords, domain) — never share this file
│
├── odoo.conf                ← Odoo server settings (performance tuning)
│
├── nginx/
│   └── default.conf         ← Web server settings (HTTPS, security headers)
│
├── custom-addons/           ← ePHEM modules (from github.com/borse/ePHEM)
│
├── scripts/
│   └── backup.sh            ← Backup script for databases and files
│
├── backups/                 ← Backup files are stored here (not uploaded to GitHub)
│
└── README.md                ← This guide
```

These folders are **created automatically** by Docker when you first start the system. They store your actual data and are never uploaded to GitHub:

```
postgres-data/               ← Your database files
odoo-data/                   ← Uploaded documents, images, and attachments
```

---

## Security Notes

This deployment includes these security measures out of the box:

- **PostgreSQL and Odoo are never exposed to the internet** — only NGINX is publicly accessible on ports 80 and 443
- **HTTPS with TLS 1.2+** — all traffic between users and the server is encrypted
- **Security headers** — the server sends headers that protect against common web attacks
- **Internal Docker network** — containers talk to each other privately, not over the public internet
- **Automatic SSL renewal** — certificates are renewed before they expire
- **Backup script** — included with automatic 14-day cleanup

**After installation, we recommend these additional steps:**

- Change the default SSH port and disable password login on your server
- Install `fail2ban` on the host to block brute-force login attempts:
  ```bash
  sudo apt install -y fail2ban
  ```
- Copy backups to another location (different server, USB drive, or cloud storage)
- Enable **two-factor authentication** for all admin users in Odoo (Settings → General Settings → Permissions)
- Disable the database manager page after setup (see [Locking It Down](#locking-it-down))

---

## Need Help?

If you run into problems:

1. Check the [Troubleshooting](#troubleshooting) section above
2. Run `docker compose logs` and share the output with the ePHEM support team
3. Open an issue on GitHub: [github.com/borse/ephem_deployment_docker/issues](https://github.com/borse/ephem_deployment_docker/issues)