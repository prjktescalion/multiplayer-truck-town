# Quick guide: self-hosting on a campus network

Every command, in order, to put this game on a Linux box on a university network and let people
join by scanning a QR code. No cloud accounts, no cost.

If you want to understand *why* any of this is shaped the way it is, the numbered docs beside this
one explain it. This file is the recipe; they are the reasoning.

**Time:** about an hour, most of it downloads.

---

## What you need

- A Linux box on the campus network that stays on, with SSH access
- Phones and the box must be able to reach each other — if you have never tested this, test it
  before anything else
- The box's network interface name and address: `ip -4 addr`
- Roughly 3 GB free (1.3 GB of Godot export templates, ~1 GB of build output and caches)

Throughout, replace:

| Placeholder | Meaning |
|---|---|
| `truck-town` | your DuckDNS subdomain |
| `YOUR_DUCKDNS_TOKEN` | the token from your DuckDNS account page |
| `enp2s0` | your interface name from `ip -4 addr` |
| `10.x.x.x` | your box's address from `ip -4 addr` |
| `youruser` | the account the repo is cloned under |

---

## Step 0 — The go/no-go test

**Do this first.** If it fails, nothing else in this guide works and you need a tunnel instead
(see [01-the-hosting-problem.md](01-the-hosting-problem.md)).

Create a free account at [duckdns.org](https://www.duckdns.org), claim a subdomain, and set its IP
to your box's **private** address (`10.x.x.x`). Then, **from a phone on campus WiFi**, check that
the name resolves to that address.

Some networks run DNS rebinding protection, which strips private addresses out of public DNS
answers. If your phone can't resolve the name, stop here — the certificate approach below cannot
work on that network.

```bash
# from the box, a weaker but instant sanity check
dig +short truck-town.duckdns.org      # expect your 10.x.x.x
```

---

## Step 1 — Godot and export templates

```bash
uname -m          # expect x86_64
sudo apt update && sudo apt install -y unzip wget

cd ~
wget https://github.com/godotengine/godot/releases/download/4.7.1-stable/Godot_v4.7.1-stable_linux.x86_64.zip
unzip Godot_v4.7.1-stable_linux.x86_64.zip
mkdir -p ~/bin && mv Godot_v4.7.1-stable_linux.x86_64 ~/bin/godot && chmod +x ~/bin/godot

wget https://github.com/godotengine/godot/releases/download/4.7.1-stable/Godot_v4.7.1-stable_export_templates.tpz
unzip Godot_v4.7.1-stable_export_templates.tpz
mkdir -p ~/.local/share/godot/export_templates
mv templates ~/.local/share/godot/export_templates/4.7.1.stable
```

The directory name `4.7.1.stable` is matched literally and must equal `godot --version` exactly.

---

## Step 2 — Point the client at the relay, then build

```bash
git clone https://github.com/prjktescalion/multiplayer-truck-town.git
cd ~/multiplayer-truck-town

sed -i 's|DEFAULT_PUBLIC_SERVER_URL := ".*"|DEFAULT_PUBLIC_SERVER_URL := "wss://truck-town.duckdns.org/ws"|' net/net.gd
grep -n DEFAULT_PUBLIC_SERVER_URL net/net.gd

export GODOT=~/bin/godot
~/bin/godot --headless --import --path .     # required on a fresh clone
./scripts/build_web.sh
./scripts/build_server.sh
```

The URL is compiled into the `.pck`, so it must be set **before** the export. Change it later and
you have to rebuild and recopy.

Publish the web build and stage the relay binary:

```bash
sudo mkdir -p /srv/trucktown /srv/trucktown-server
sudo cp -R build/web/. /srv/trucktown/
sudo cp build/server/truck-town-server /srv/trucktown-server/
```

---

## Step 3 — Caddy with DNS-01

```bash
sudo apt install -y debian-keyring debian-archive-keyring apt-transport-https curl
curl -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/gpg.key' \
  | sudo gpg --dearmor -o /usr/share/keyrings/caddy-stable-archive-keyring.gpg
curl -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/debian.deb.txt' \
  | sudo tee /etc/apt/sources.list.d/caddy-stable.list
sudo apt update && sudo apt install -y caddy

sudo caddy add-package github.com/caddy-dns/duckdns
caddy list-modules | grep duckdns          # expect: dns.providers.duckdns
```

Write `/etc/caddy/Caddyfile`:

```caddyfile
truck-town.duckdns.org {
	tls {
		dns duckdns YOUR_DUCKDNS_TOKEN
		propagation_delay 60s
		propagation_timeout -1
	}

	handle_path /ws* {
		reverse_proxy localhost:8910
	}

	handle {
		root * /srv/trucktown
		file_server
	}
}
```

`propagation_timeout -1` is not optional on most campus networks — they block outbound port 53 to
anything but their own resolvers, so Caddy cannot verify its own TXT record. Let's Encrypt reads it
fine from outside.

```bash
sudo chmod 640 /etc/caddy/Caddyfile        # it holds your token
sudo caddy fmt --overwrite /etc/caddy/Caddyfile
sudo systemctl restart caddy               # restart, NOT reload, after add-package
sudo journalctl -u caddy -f
```

Wait for `certificate obtained successfully`. Expect a ~60 second pause first.

---

## Step 4 — The relay as a service

```bash
sudo tee /etc/systemd/system/trucktown.service >/dev/null <<'EOF'
[Unit]
Description=Truck Town relay
After=network.target

[Service]
DynamicUser=yes
ExecStart=/srv/trucktown-server/truck-town-server --headless -- --server --port=8910
Restart=always

NoNewPrivileges=yes
PrivateTmp=yes
PrivateDevices=yes
ProtectSystem=strict
ProtectHome=yes
ProtectKernelTunables=yes
ProtectKernelModules=yes
RestrictNamespaces=yes
RestrictAddressFamilies=AF_INET AF_INET6 AF_UNIX
CapabilityBoundingSet=
LockPersonality=yes
SystemCallArchitectures=native

[Install]
WantedBy=multi-user.target
EOF

sudo systemctl daemon-reload
sudo systemctl enable --now trucktown
journalctl -u trucktown -n 20 --no-pager
```

Expect `Truck Town server listening on port 8910 (max 8 players)`.

`DynamicUser=yes` is why the binary lives in `/srv` — with `ProtectHome=yes` the service cannot read
`/home` at all. If the unit fails to start, drop `RestrictAddressFamilies` first.

---

## Step 5 — Firewall

**Allow 22 before enabling, or you will lock yourself out of a remote box.**

```bash
sudo ufw allow 22/tcp
sudo ufw allow 80/tcp
sudo ufw allow 443/tcp
sudo ufw enable
sudo ufw status verbose
```

Default-deny closes 8910, which the relay otherwise exposes on every interface. Caddy still reaches
it because ufw always permits loopback.

---

## Step 6 — Verify

```bash
sudo ss -lntp                               # expect only 22, 80, 443 on * and 8910 gone from outside
curl -I https://truck-town.duckdns.org      # expect HTTP/2 200

curl -is -H "Connection: Upgrade" -H "Upgrade: websocket" \
     -H "Sec-WebSocket-Version: 13" \
     -H "Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==" \
     https://truck-town.duckdns.org/ws | head -5
```

`101 Switching Protocols` means the proxy hop works. `502` means Caddy can't reach the relay;
`404` or HTML means `handle_path` isn't matching.

There is no test suite. The real verification is **two clients driving at the same time** while you
watch `journalctl -u trucktown -f` for `Peer N joined`.

---

## Step 7 — The QR code

```bash
sudo apt install -y qrencode
qrencode -t ANSIUTF8 "https://truck-town.duckdns.org"
qrencode -o qr.png -s 10 "https://truck-town.duckdns.org"
```

The cap is 8 players (`MAX_PLAYERS` in `net/net.gd`).

---

## Optional — survive a DHCP change

DHCP renewal normally preserves your address, so this is insurance against a reboot or a switch
port change rather than a looming problem.

```bash
sudo tee /etc/systemd/system/duckdns.service >/dev/null <<'EOF'
[Unit]
Description=Update DuckDNS with current LAN IP

[Service]
Type=oneshot
ExecStart=/bin/bash -c 'curl -fsS "https://www.duckdns.org/update?domains=truck-town&token=YOUR_DUCKDNS_TOKEN&ip=$(ip -4 -o addr show enp2s0 | awk "{print \$4}" | cut -d/ -f1)"'
EOF

sudo tee /etc/systemd/system/duckdns.timer >/dev/null <<'EOF'
[Unit]
Description=Refresh DuckDNS every 5 minutes

[Timer]
OnBootSec=1min
OnUnitActiveSec=5min

[Install]
WantedBy=timers.target
EOF

sudo systemctl daemon-reload
sudo systemctl enable --now duckdns.timer
```

The proportionate alternative is a morning-of check:

```bash
ip -4 -o addr show enp2s0 | awk '{print $4}' | cut -d/ -f1
dig +short truck-town.duckdns.org
```

If those two agree, you are fine.

---

## Morning-of checklist

```bash
systemctl is-active caddy trucktown                     # both active
curl -I https://truck-town.duckdns.org                  # 200, valid cert
ip -4 -o addr show enp2s0 | awk '{print $4}'            # matches DuckDNS
dig +short truck-town.duckdns.org
```

Then load the page on a phone on campus WiFi and drive one lap. That single test exercises DNS,
routing, the certificate, the static files, and the relay in one go.

---

## When it doesn't work

[05-troubleshooting.md](05-troubleshooting.md) has every failure we actually hit, with the real
error strings and the fix for each.

To take it all back down: [quick-unhost.md](quick-unhost.md).
