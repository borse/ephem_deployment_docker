import websocket, ssl, sys, time, resource
resource.setrlimit(resource.RLIMIT_NOFILE, (20000, 20000))
n = int(sys.argv[1]); hold = int(sys.argv[2])
opts = {"cert_reqs": ssl.CERT_NONE, "check_hostname": False}
socks, refused = [], {}
for i in range(n):
    try:
        w = websocket.create_connection("wss://ephem.health.example/websocket", timeout=10, origin="https://ephem.health.example", sslopt=opts)
        socks.append(w)
    except websocket.WebSocketBadStatusException as e:
        refused[e.status_code] = refused.get(e.status_code, 0) + 1
        time.sleep(0.05)
    except Exception as e:
        refused[type(e).__name__] = refused.get(type(e).__name__, 0) + 1
print("asked for %d: %d open, refused %s" % (n, len(socks), refused or "none"), flush=True)
time.sleep(hold)
