# Throwaway client machine for the security test: scanners and a Python with
# the usual HTTP libraries.
FROM python:3.12-slim
RUN apt-get update && apt-get install -y --no-install-recommends \
      curl nmap ncat openssl iproute2 iputils-ping dnsutils git ca-certificates \
      bsdextrautils procps perl libnet-ssleay-perl libio-socket-ssl-perl libjson-perl \
      libxml-writer-perl iptables \
 && pip install --no-cache-dir requests websocket-client "httpx[http2]" \
 && git clone -q --depth 1 https://github.com/testssl/testssl.sh /opt/testssl \
 && git clone -q --depth 1 https://github.com/sullo/nikto /opt/nikto \
 && apt-get clean && rm -rf /var/lib/apt/lists/*
CMD ["sleep", "infinity"]
