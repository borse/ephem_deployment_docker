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

```bash
bash setup-ephem-repo.sh
```

The script will ask you two questions:

**1. Where to install the modules:**

```
Where should the ePHEM modules be installed?

  Detected: /opt/odoo18/custom-addons

Enter path (press Enter to use detected path):
```

If it detects your Odoo installation, just press `Enter`. Otherwise, type the full path.

**2. Which branch to use:**

```
Which branch do you want to use?

  1) 18_national_dev       — Odoo 18 development (recommended)
  2) 18_national_master    — Odoo 18 stable
  3) 16_national_dev       — Odoo 16 development
  4) 16_national_master    — Odoo 16 stable

Choose [1-4] (default: 1):
```

Press `Enter` for the default (Odoo 18 development), or choose another option.

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
bash setup-ephem-repo.sh
```

The script remembers your settings. It will verify access, clone the modules, set permissions, and confirm.

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
bash setup-ephem-repo.sh
```

It will ask for the path and branch again (defaults to your previous choices), then pull the latest code.

Then restart Odoo:

```bash
sudo systemctl restart odoo
```

Go to **Apps → Update Apps List** and upgrade the modules.

---

## Branches

The ePHEM repository has branches for different Odoo versions and environments:

| Option | Branch | Odoo Version | Purpose |
|--------|--------|-------------|---------|
| 1 | `18_national_dev` | 18 | Development (default) |
| 2 | `18_national_master` | 18 | Stable / production |
| 3 | `16_national_dev` | 16 | Development |
| 4 | `16_national_master` | 16 | Stable / production |

The script asks you to choose when you run it.

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
bash setup-ephem-repo.sh /your/custom/addons/path
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
bash setup-ephem-repo.sh
```

---

## Need Help?

1. Check [Troubleshooting](#troubleshooting) above
2. Email the ePHEM team at `ephem@who.int`
3. Open an issue: [github.com/borse/ephem_deployment_docker/issues](https://github.com/borse/ephem_deployment_docker/issues)