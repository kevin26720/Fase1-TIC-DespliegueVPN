# Hardened OpenVPN Container Image
# Based on minimal Alpine Linux to reduce vulnerability footprint
FROM alpine:3.20

# Maintainer metadata
LABEL maintainer="DevSecOps Team" \
      description="Hardened OpenVPN image supporting active-active configurations and DCO"

# Install necessary packages, perform security upgrades, and clean caches immediately
RUN apk update && apk upgrade --no-cache && apk add --no-cache \
        openvpn \
        iptables \
        bash \
        openssl \
    && rm -rf /var/cache/apk/* /tmp/*

# Create directory structure for OpenVPN configurations, PKI keys, and CRLs
RUN mkdir -p /etc/openvpn /etc/openvpn/crl /run /var/log/openvpn \
    && chmod 750 /etc/openvpn \
    && chmod 700 /etc/openvpn/crl

# Copy entrypoint script
COPY entrypoint.sh /usr/local/bin/entrypoint.sh
RUN chmod +x /usr/local/bin/entrypoint.sh

# Expose default OpenVPN port (can be TCP or UDP)
EXPOSE 1194/udp
EXPOSE 1194/tcp

# Healthcheck to verify the openvpn process is running
HEALTHCHECK --interval=30s --timeout=5s --start-period=10s --retries=3 \
  CMD pgrep openvpn || exit 1

ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
