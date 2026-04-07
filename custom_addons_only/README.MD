# ePHEM — Custom Addons Setup (VM / Bare Metal)

Set up the ePHEM custom modules on any server running Odoo — no Docker required.

This script handles SSH key generation, access requests, cloning, permissions, and updates in one command.

---

## Table of Contents

- [How It Works](#how-it-works)
- [Requirements](#requirements)
- [Installation](#installation)
  - [Step 1 — Download the Script](#step-1--download-the-script)
  - [Step 2 — Run the Script](#step-2--run-the-script)
  - [Step 3 — Request Access](#step-3--request-access)
  - [Step 4 — Run Again After Access is Granted](#step-4--run-again-after-access-is-granted)
  - [Step 5 — Restart Odoo](#step-5--restart-odoo)
- [Updating ePHEM Modules](#updating-ephem-modules)
- [Branches](#branches)
- [Examples](#examples)
- [Troubleshooting](#troubleshooting)

---

## How It Works

The ePHEM custom modules are hosted in a private GitHub repository. This script:

1. Generates an SSH key on your server (one time)
2. You send the key to the ePHEM team — they grant read-only access
3. The script clones the modules into your Odoo addons folder
4. Run the same script again anytime to update to the latest version

```
┌──────────────────────────────────────────────────────────┐
│  Your Server                                             │
│                                                          │
│  ┌────────────────────┐     ┌─────────────────────────┐  │
│  │  Odoo (existing)   │────▶│  custom-addons/         │  │
│  │                    │     │  (ePHEM modules cloned   │  │
│  │                    │     │   by this script)        │  │
│  └────────────────────┘     └─────────────────────────┘  │
│                                                          │
└──────────────────────────────────────────────────────────┘
```

---

## Requirements

- A server with **Odoo already installed** (16, 18, or any version)
- **Git** installed (`sudo apt install -y git` if missing)
- **SSH access** to the server

---

## Installation

### Step 1 — Download the Script

Connect to your server via SSH and install the required tools if missing:

```bash
sudo apt install -y git curl
```

Then download the script:

```bash
git clone https://github.com/borse/ephem_deployment_docker.git ephem-tools
```

```bash
cd ephem-tools/custom_addons_only
```

### Step 2 — Run the Script

**Auto-detect** the addons folder (works if Odoo is in a standard location):

```bash
bash setup_ephem_repo.sh
```

**Or specify the path** to your custom addons folder:

```bash
bash setup_ephem_repo.sh /opt/odoo18/custom-addons
```

> **First run:** The script will generate an SSH key and display it. It will NOT clone the repo yet — you need to request access first.

### Step 3 — Request Access

The script shows your SSH public key at the end:

```
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
  ACTION REQUIRED
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

  Send the following SSH key to the ePHEM team at:

  ephem@who.int

  ╔══════════════════════════════════════════════════════════════╗
  ║  COPY EVERYTHING BETWEEN THE LINES AND PASTE IN YOUR EMAIL  ║
  ╚══════════════════════════════════════════════════════════════╝

  ssh-ed25519 AAAAC3NzaC1... ephem-addons-your-server

  ╔══════════════════════════════════════════════════════════════╗
  ║  END OF KEY                                                 ║
  ╚══════════════════════════════════════════════════════════════╝
```

1. Copy the SSH key line
2. Email it to **`ephem@who.int`**
3. Include your **country or server name** in the email subject
4. Wait for the ePHEM team to confirm

### Step 4 — Run Again After Access is Granted

Once the ePHEM team confirms your access:

```bash
bash setup_ephem_repo.sh
```

The script will detect the key, verify access, and clone the ePHEM modules automatically.

### Step 5 — Restart Odoo

After the modules are downloaded, restart Odoo to load them:

**Systemd service:**

```bash
sudo systemctl restart odoo
```

Or if your service has a different name:

```bash
sudo systemctl restart odoo18-national-master
```

Then open Odoo in your browser, go to **Apps → Update Apps List**, and install the ePHEM modules.

---

## Updating ePHEM Modules

Run the same script to pull the latest changes:

```bash
bash setup_ephem_repo.sh
```

Or specify the path:

```bash
bash setup_ephem_repo.sh /opt/odoo18/custom-addons
```

Then restart Odoo:

```bash
sudo systemctl restart odoo
```

Go to **Apps → Update Apps List** and upgrade the modules.

---

## Branches

The ePHEM repository has branches for different Odoo versions and environments:

| Branch | Odoo Version | Purpose |
|--------|-------------|---------|
| `18_national_dev` | 18 | Development (default) |
| `18_national_master` | 18 | Stable / production |
| `16_national_dev` | 16 | Development |
| `16_national_master` | 16 | Stable / production |

Switch branches with the `--branch` flag:

```bash
bash setup_ephem_repo.sh --branch 16_national_master /opt/odoo16/odca-national-master
```

```bash
bash setup_ephem_repo.sh --branch 18_national_master /opt/odoo18/custom-addons
```

---

## Examples

**Odoo 18 — standard install:**

```bash
bash setup_ephem_repo.sh /opt/odoo18/custom-addons
```

**Odoo 18 — stable branch:**

```bash
bash setup_ephem_repo.sh --branch 18_national_master /opt/odoo18/custom-addons
```

**Odoo 16 — existing server:**

```bash
bash setup_ephem_repo.sh --branch 16_national_master /opt/odoo16/odca-national-master
```

**Auto-detect path:**

```bash
bash setup_ephem_repo.sh
```

The script checks these locations automatically:

- `/opt/odoo18/custom-addons`
- `/opt/odoo/custom-addons`
- `/opt/odoo16/odca-national-master`
- `/opt/odoo16/custom-addons`

If none are found, it asks you to enter the path.

---

## Troubleshooting

### "Access not yet granted"

Your SSH key hasn't been added to the repository. Make sure you:

1. Sent the key to `ephem@who.int`
2. Received confirmation from the ePHEM team
3. Are running the script on the **same server** where the key was generated

To see your key again:

```bash
cat ~/.ssh/ephem_addons_deploy.pub
```

### "Permission denied" when cloning

The SSH key might not be configured correctly. Test it:

```bash
ssh -T git@github-ephem-addons
```

If you see "successfully authenticated", the key works. If not, check:

```bash
cat ~/.ssh/config
```

It should contain a `Host github-ephem-addons` section. If missing, run the script again — it will recreate it.

### "Could not auto-detect addons path"

The script couldn't find a standard Odoo installation. Specify the path manually:

```bash
bash setup_ephem_repo.sh /your/custom/addons/path
```

### Permission errors after cloning

The script auto-detects the Odoo user and sets ownership. If it didn't work:

```bash
sudo chown -R odoo:odoo /opt/odoo18/custom-addons
```

```bash
sudo chmod -R 755 /opt/odoo18/custom-addons
```

Replace `odoo` with your Odoo system user (`odoo16`, `odoo18`, etc.).

### Modules not showing in Odoo

1. Restart Odoo: `sudo systemctl restart odoo`
2. Go to **Apps → Update Apps List**
3. Remove the "Apps" filter in the search bar — search for `eoc` to find ePHEM modules

### Need to start over

Remove the key and SSH config, then run the script again:

```bash
rm -f ~/.ssh/ephem_addons_deploy ~/.ssh/ephem_addons_deploy.pub
```

Edit SSH config and remove the `github-ephem-addons` section:

```bash
nano ~/.ssh/config
```

Then re-run:

```bash
bash setup_ephem_repo.sh
```

---

## Need Help?

1. Check [Troubleshooting](#troubleshooting) above
2. Email the ePHEM team at `ephem@who.int`
3. Open an issue: [github.com/borse/ephem_deployment_docker/issues](https://github.com/borse/ephem_deployment_docker/issues)