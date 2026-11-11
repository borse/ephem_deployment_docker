#!/usr/bin/env python3
"""What a server set up by ephem-deploy must refuse, asked from outside.

Run it from ANOTHER machine (a laptop), against a server with nginx and HTTPS:

    python3 probe.py ephem.health.gov.xx
    python3 probe.py ephem.health.gov.xx --ip 203.0.113.10 --insecure --burst

It only asks; nothing is changed and no password is tried. Python 3.8 or
later, no package to install. Exit status 0 when every line is a pass.

  --ip ADDR    connect to this address instead of resolving the name (a server
               whose DNS record is not there yet, a test rig)
  --insecure   accept a certificate this machine does not trust (a test rig)
  --burst      also send 40 empty login POSTs and 15 database manager POSTs,
               to see the throttles answer 429 (noisy: leave it out on a
               server people are working on)

The list is the one in HARDENING.md, section 7, plus the ways round it that
were found in November 2026 (a language code in front of the path).
"""
import argparse
import http.client
import socket
import ssl
import sys
import warnings

# Asking for TLS 1.0 and 1.1 on purpose, to see them refused.
warnings.filterwarnings("ignore", category=DeprecationWarning)

PASS = FAIL = 0


def line(ok, text, detail=""):
    global PASS, FAIL
    if ok:
        PASS += 1
    else:
        FAIL += 1
    mark = "\033[0;32m✓\033[0m" if ok else "\033[0;31m✗\033[0m"
    print("  %s %s%s" % (mark, text, (" (" + detail + ")") if detail else ""))


class Target:
    def __init__(self, name, ip, insecure):
        self.name, self.ip = name, ip or name
        self.ctx = ssl.create_default_context()
        if insecure:
            self.ctx.check_hostname = False
            self.ctx.verify_mode = ssl.CERT_NONE

    def request(self, method, path, body=None, headers=None, tls=True, host=None, sni=True):
        """(status, headers, body), or (None, {}, error text) when nothing answered."""
        try:
            raw = socket.create_connection((self.ip, 443 if tls else 80), timeout=15)
            if tls:
                raw = self.ctx.wrap_socket(raw, server_hostname=self.name if sni else None)
            conn = http.client.HTTPSConnection(self.name) if tls else http.client.HTTPConnection(self.name)
            conn.sock = raw
            hdrs = {"Host": host or self.name, "User-Agent": "ephem-deploy-probe"}
            hdrs.update(headers or {})
            conn.request(method, path, body=body, headers=hdrs)
            resp = conn.getresponse()
            data = resp.read(200000)
            out = (resp.status, resp.getheaders(), data.decode("utf-8", "replace"))
            conn.close()
            return out
        except Exception as exc:  # refused handshake, dropped connection, timeout
            return (None, [], "%s: %s" % (type(exc).__name__, exc))


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("domain")
    ap.add_argument("--ip")
    ap.add_argument("--insecure", action="store_true")
    ap.add_argument("--burst", action="store_true")
    args = ap.parse_args()
    t = Target(args.domain, args.ip, args.insecure)

    status, headers, body = t.request("GET", "/web/login")
    if status is None:
        print("No HTTPS answer from %s (%s): %s" % (args.domain, t.ip, body))
        return 2
    print("%s (%s)" % (args.domain, t.ip))

    print("\nRPC endpoints (blocked unless opened on purpose in manage.sh)")
    xml = "<?xml version='1.0'?><methodCall><methodName>version</methodName></methodCall>"
    for path in ("/xmlrpc/2/common", "/en/xmlrpc/2/common", "/fr/xmlrpc/2/object", "/en/xmlrpc/2/db",
                 "/jsonrpc", "/en/jsonrpc", "/ar/jsonrpc", "/en%2Fxmlrpc/2/common", "/x/../en/xmlrpc/2/common"):
        st, _, b = t.request("POST", path, body=xml, headers={"Content-Type": "text/xml"})
        line(st in (403, 404) and "server_version" not in b, "POST %s refused" % path, "HTTP %s" % st)

    print("\nDatabase manager")
    st, _, b = t.request("GET", "/web/database/manager")
    if st == 403:
        line(True, "disabled and refused by nginx")
        for path in ("/en/web/database/manager", "/web/database/selector", "/fr/web/database/backup"):
            st2, _, _ = t.request("GET", path)
            line(st2 in (403, 429), "%s refused" % path, "HTTP %s" % st2)
    else:
        line(False, "/web/database/manager answers", "HTTP %s: disable it, bash manage.sh" % st)
    st, _, b = t.request("POST", "/web/database/list", body='{"jsonrpc":"2.0","params":{}}',
                         headers={"Content-Type": "application/json"})
    line('"result"' not in b, "the list of databases is not handed out", "HTTP %s" % st)

    print("\nPages that tell too much")
    for path in ("/website/info", "/en/website/info"):
        st, _, _ = t.request("GET", path)
        line(st == 404, "%s hidden" % path, "HTTP %s" % st)

    print("\nHeaders and cookies on /web/login")
    names = {}
    for k, v in headers:
        names.setdefault(k.lower(), []).append(v)
    for h in ("strict-transport-security", "x-frame-options", "x-content-type-options",
              "referrer-policy", "content-security-policy", "permissions-policy"):
        line(len(names.get(h, [])) == 1, "%s sent once" % h, "%d times" % len(names.get(h, [])))
    line(names.get("server", [""])[0].strip().lower() == "nginx", "Server header carries no version",
         names.get("server", ["(none)"])[0])
    for cookie in names.get("set-cookie", []):
        name = cookie.split("=", 1)[0]
        low = cookie.lower()
        line("secure" in low and "samesite=lax" in low, "cookie %s is Secure and SameSite=Lax" % name)
        if name == "session_id":
            line("httponly" in low, "cookie session_id is HttpOnly")

    print("\nNames that are not ours")
    st, _, b = t.request("GET", "/", sni=False)
    line(st is None, "HTTPS by IP address (no name): handshake refused", "HTTP %s" % st if st else "")
    st, _, b = t.request("GET", "/", host="not-ours.example.net")
    line(st in (None, 421), "HTTPS with another Host header: not passed on to Odoo", "HTTP %s" % st if st else "no answer")
    st, hd, _ = t.request("GET", "/web/login?x=1", tls=False)
    loc = dict((k.lower(), v) for k, v in hd).get("location", "")
    line(st == 301 and loc == "https://%s/web/login?x=1" % args.domain, "port 80, our name: on to HTTPS, same name", loc or "HTTP %s" % st)
    st, hd, _ = t.request("GET", "/x", tls=False, host="not-ours.example.net")
    loc = dict((k.lower(), v) for k, v in hd).get("location", "")
    line(st is None, "port 80, another name: no answer, no redirect to it", loc or ("HTTP %s" % st if st else ""))

    print("\nTLS")
    for label, version in (("TLS 1.0", ssl.TLSVersion.TLSv1), ("TLS 1.1", ssl.TLSVersion.TLSv1_1)):
        try:
            ctx = ssl.SSLContext(ssl.PROTOCOL_TLS_CLIENT)
            ctx.check_hostname = False
            ctx.verify_mode = ssl.CERT_NONE
            ctx.set_ciphers("ALL:@SECLEVEL=0")
            ctx.minimum_version = ctx.maximum_version = version
            with socket.create_connection((t.ip, 443), timeout=10) as raw:
                with ctx.wrap_socket(raw, server_hostname=args.domain):
                    line(False, "%s refused" % label, "the server accepted it")
        except (ssl.SSLError, OSError, ValueError):
            line(True, "%s refused" % label)
    try:
        ctx = ssl.SSLContext(ssl.PROTOCOL_TLS_CLIENT)
        ctx.check_hostname = False
        ctx.verify_mode = ssl.CERT_NONE
        with socket.create_connection((t.ip, 443), timeout=10) as raw:
            with ctx.wrap_socket(raw, server_hostname=args.domain) as tls:
                line(tls.version() in ("TLSv1.2", "TLSv1.3"), "negotiates %s, %s" % (tls.version(), tls.cipher()[0]))
    except Exception as exc:
        line(False, "TLS handshake", str(exc))

    if args.burst:
        print("\nThrottles (--burst)")
        for path, count, label in (("/web/login", 40, "login POSTs"), ("/en/web/login", 40, "login POSTs under a language code")):
            refused = sum(1 for _ in range(count) if t.request("POST", path, body="x=1", headers={
                "Content-Type": "application/x-www-form-urlencoded"})[0] == 429)
            line(refused > 0, "%d %s: %d answered 429" % (count, label, refused))

    print("\n%d passed, %d failed" % (PASS, FAIL))
    return 0 if FAIL == 0 else 1


if __name__ == "__main__":
    sys.exit(main())
