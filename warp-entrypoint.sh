#!/bin/bash
set -e

# create a tun device if not exist
if [ ! -e /dev/net/tun ]; then
    mkdir -p /dev/net
    mknod /dev/net/tun c 10 200
    chmod 600 /dev/net/tun
fi

# start dbus
mkdir -p /run/dbus
rm -f /run/dbus/pid
dbus-daemon --config-file=/usr/share/dbus-1/system.conf

# start the warp daemon
warp-svc --accept-tos &

# wait for warp-svc socket to be ready
echo "[warp-init] Waiting for warp-svc IPC socket..."
for i in $(seq 1 30); do
    if [ -S /run/cloudflare-warp/warp_service ]; then
        echo "[warp-init] warp-svc IPC socket is ready."
        break
    fi
    sleep 1
done

# if reg.json does not exist, register new warp client
if [ ! -f /var/lib/cloudflare-warp/reg.json ]; then
    if [ ! -f /var/lib/cloudflare-warp/mdm.xml ] || [ -n "$REGISTER_WHEN_MDM_EXISTS" ]; then
        warp-cli --accept-tos registration new && echo "Warp client registered!" || true
        if [ -n "$WARP_LICENSE_KEY" ]; then
            echo "License key found, registering license..."
            warp-cli --accept-tos registration license "$WARP_LICENSE_KEY" && echo "Warp license registered!" || true
        fi
    fi
    warp-cli --accept-tos connect 2>/dev/null || true
else
    echo "Warp client already registered, skip registration"
fi

# disable qlog safely
warp-cli --accept-tos debug qlog disable 2>/dev/null || true

# background auto-connect loop to ensure warp stays connected
(
  for i in $(seq 1 30); do
    sleep 2
    if warp-cli --accept-tos status 2>/dev/null | grep -q "Status update: Connected"; then
      echo "[warp-auto-connect] WARP is connected."
      break
    fi
    echo "[warp-auto-connect] Attempting WARP connect (attempt $i)..."
    warp-cli --accept-tos connect 2>/dev/null || true
  done
) &

# if WARP_ENABLE_NAT is provided, enable NAT and forwarding
if [ -n "$WARP_ENABLE_NAT" ]; then
    echo "[NAT] Switching to warp mode..."
    warp-cli --accept-tos mode warp 2>/dev/null || true
    warp-cli --accept-tos connect 2>/dev/null || true
    sleep 2
    echo "[NAT] Enabling NAT..."
    nft add table ip nat 2>/dev/null || true
    nft add chain ip nat WARP_NAT { type nat hook postrouting priority 100 \; } 2>/dev/null || true
    nft add rule ip nat WARP_NAT oifname "CloudflareWARP" masquerade 2>/dev/null || true
    nft add table ip mangle 2>/dev/null || true
    nft add chain ip mangle forward { type filter hook forward priority mangle \; } 2>/dev/null || true
    nft add rule ip mangle forward tcp flags syn tcp option maxseg size set rt mtu 2>/dev/null || true

    nft add table ip6 nat 2>/dev/null || true
    nft add chain ip6 nat WARP_NAT { type nat hook postrouting priority 100 \; } 2>/dev/null || true
    nft add rule ip6 nat WARP_NAT oifname "CloudflareWARP" masquerade 2>/dev/null || true
    nft add table ip6 mangle 2>/dev/null || true
    nft add chain ip6 mangle forward { type filter hook forward priority mangle \; } 2>/dev/null || true
    nft add rule ip6 mangle forward tcp flags syn tcp option maxseg size set rt mtu 2>/dev/null || true
fi

# execute proxy or passed arguments
if [ $# -gt 0 ]; then
    exec "$@"
else
    exec gost ${GOST_ARGS:--L :1080}
fi
