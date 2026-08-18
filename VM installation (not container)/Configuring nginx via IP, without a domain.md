# Odoo 18 behind nginx on a local network, without a domain name

> **Purpose.** Serve Odoo from a server that has only a local network address, such as `192.168.50.53`, with no domain name and no certificate. Typing the address in a browser reaches Odoo.
>
> **When to use this.** Internal test, training and demonstration servers on a ministry or office network. It replaces §10, §11 and §12 of the main deployment guide.
>
> **When not to use this.** Anything holding real case data. There is no certificate here, so logins and records travel the network in plain text and anything else on that network can read them. Read the last section before using this for real data.

**Before you start,** sections 1 to 9 of the main guide must be complete, Odoo must be running, and it must be listening on the local interface:

```bash
systemctl is-active odoo18
ss -tlnp | grep 8069        # expect 127.0.0.1:8069
```

---

## 1. Point Odoo at the database

The main guide sets `dbfilter = ^%d$`, which picks the database from the first part of the hostname. An address such as `192.168.50.53` has no such name, so Odoo cannot decide which database to serve and you get sent to a database selector that is blocked.

Set the database name directly instead. The pattern stays anchored, so this server still serves exactly one database and no other:

🔴 **Replace before running:** `yourdb`

```bash
sudo sed -i 's|^dbfilter = .*|dbfilter = ^yourdb$|' /etc/odoo/odoo18.conf
grep -E '^(dbfilter|list_db|proxy_mode)' /etc/odoo/odoo18.conf
sudo systemctl restart odoo18
```

The other two settings should read `list_db = False` and `proxy_mode = True`, both unchanged from §8.2.

---

## 2. Install nginx

```bash
sudo apt-get install -y nginx
```

---

## 3. Shared settings

Two files, both taken from §10.1 and §10.2 of the main guide. The certificate related snippets are not needed here.

```bash
sudo tee /etc/nginx/snippets/odoo-proxy-headers.conf > /dev/null <<'EOF'
proxy_set_header Host $host;
proxy_set_header X-Forwarded-Host $host;
proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
proxy_set_header X-Forwarded-Proto $scheme;
proxy_set_header X-Real-IP $remote_addr;
EOF
```

```bash
sudo tee /etc/nginx/conf.d/odoo-hardening.conf > /dev/null <<'EOF'
server_tokens off;

# Throttle only credential submissions (POST). Requests with an empty limit
# key are not counted, so GET requests for the login page are never limited.
# This matters because a whole office often shares one address.
map $request_method $odoo_login_limit_key {
  default "";
  POST    $binary_remote_addr;
}
limit_req_zone $odoo_login_limit_key zone=odoo_login:10m rate=30r/m;
limit_req_status 429;

# Websocket upgrade map
map $http_upgrade $connection_upgrade {
  default upgrade;
  ''      close;
}
EOF
```

The first file is used by every location that forwards to Odoo. The second provides `$connection_upgrade` for the websocket block and the `odoo_login` zone for the login throttle. Both are referenced by the site file below, so nginx will refuse to start without them.

---

## 4. The site

🔴 **Replace before running:** `192.168.50.53`

```bash
sudo tee /etc/nginx/sites-available/odoo-lan > /dev/null <<'EOF'
upstream odoo_app    { server 127.0.0.1:8069; }
upstream odoo_app_ws { server 127.0.0.1:8072; }

server {
    listen 80 default_server;
    listen [::]:80 default_server;
    server_name 192.168.50.53;

    client_max_body_size 100M;
    proxy_read_timeout    720s;
    proxy_connect_timeout 720s;
    proxy_send_timeout    720s;

    # Database manager: blocked for everyone. list_db = False already
    # disables it inside Odoo. Create databases over SSH with odoo-bin.
    location ~ ^/web/database/(manager|selector|create|duplicate|drop|restore|backup|change_password) {
        deny all;
        proxy_pass http://odoo_app;
        include snippets/odoo-proxy-headers.conf;
    }

    # Remote procedure call endpoints: password authentication with no
    # login page, so a common target. Odoo's own web client does not use
    # them, so blocking them does not affect normal use.
    location ~ ^/(xmlrpc|jsonrpc) {
        deny all;
        proxy_pass http://odoo_app;
        include snippets/odoo-proxy-headers.conf;
    }

    # Slow down repeated login attempts
    location ~ ^/(web/login|web/session/authenticate) {
        limit_req zone=odoo_login burst=20 nodelay;
        proxy_pass http://odoo_app;
        include snippets/odoo-proxy-headers.conf;
    }

    # Live updates
    location /websocket {
        proxy_pass http://odoo_app_ws;
        proxy_set_header Upgrade $http_upgrade;
        proxy_set_header Connection $connection_upgrade;
        include snippets/odoo-proxy-headers.conf;
    }

    location / {
        proxy_redirect off;
        proxy_pass http://odoo_app;
        include snippets/odoo-proxy-headers.conf;
    }

    location ~* /web/static/ {
        proxy_buffering on;
        expires 10d;
        proxy_pass http://odoo_app;
        include snippets/odoo-proxy-headers.conf;
    }

    gzip on;
    gzip_types text/css text/plain text/xml application/xml application/json application/javascript;
}
EOF
```

---

## 5. Turn it on

```bash
sudo rm -f /etc/nginx/sites-enabled/default
sudo ln -sfn /etc/nginx/sites-available/odoo-lan /etc/nginx/sites-enabled/
sudo nginx -t && sudo systemctl reload nginx
```

Writing the file changes nothing on its own. nginx keeps serving whatever it loaded when it started until it is reloaded, and `nginx -t` only checks the files on disk.

---

## 6. Check it

🔴 **Replace before running:** `192.168.50.53`

```bash
curl -sI http://192.168.50.53/web/login | head -1     # expect HTTP/1.1 200 OK
curl -s -o /dev/null -w '%{http_code}\n' http://192.168.50.53/web/database/manager   # expect 403
curl -s -o /dev/null -w '%{http_code}\n' http://192.168.50.53/jsonrpc                # expect 403
```

Then open the address in a browser from another machine on the same network.

If you get `502 Bad Gateway`, nginx is working and Odoo is not. Check `systemctl is-active odoo18` and `sudo tail -50 /var/log/odoo/odoo18.log`.

If you are sent to a database selector, `dbfilter` does not match the database name. Recheck section 1.

---

## 7. What to skip in the main guide

Continue from §13 of the main guide, for the login jail, backups, application hardening and the final checks.

- **Skip §10.3**, the catch all server. It exists to refuse requests that arrive by bare address, which is exactly what you are allowing here. Enabling both would leave two `default_server` entries on port 80 and nginx would refuse to start.
- **Skip §11 and §12** entirely. They cover certificates and per tenant sites, neither of which applies without a domain name.
- Everything from §13 onward applies unchanged.

---

## 8. Moving to encrypted traffic later

Without a certificate, every password and every record crosses the network readable by anything on it. On a small trusted office network that is often accepted for training and testing. It is not suitable for real case data.

You cannot obtain a public certificate for a private address, but you do not need one. Give the machine a name that exists only inside your network, either in your internal DNS or in the `hosts` file of the computers that use it, then issue a certificate for that name and install it on those computers. §6.3 of the two server guide shows the same approach for the database connection and can be followed with the name in place of the address.

Once a name exists, the main guide applies as written: §12's site file with `server_name` set to that name, and `dbfilter = ^%d$` restored so the database is chosen by the name again.
