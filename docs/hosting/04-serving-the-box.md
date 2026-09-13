# Serving the box

The annotated version of what actually runs on the Linux box. The bare commands live in
[quick-guide.md](quick-guide.md) — this file explains why each piece is there, and what breaks if
you leave it out.

## The shape

Everything comes from one machine, on one origin:

```
phone ──https──> Caddy :443 ──> /srv/trucktown      static page + wasm
      ──wss────> Caddy :443 ──> localhost:8910      the relay
```

That single-origin property is worth noticing, because it is the main practical difference from the
Vercel + Fly shape described in [../04-web-export-and-hosting.md](../04-web-export-and-hosting.md).
There, the page and the relay live on different hosts, so the page has to be told where the relay
is and an HTTPS page opening a `ws://` connection is a mixed-content failure waiting to happen.
Here one certificate covers both, and the 50-odd MB of wasm arrives at LAN speed instead of
crossing the internet twice.

What it costs: the box needs a real certificate for a name that resolves to a private address.
That is the whole subject of [03-dns-01-and-duckdns.md](03-dns-01-and-duckdns.md), and it is the
only genuinely hard part of this setup.

## 1. Godot on the box

```bash
cd ~
wget https://github.com/godotengine/godot/releases/download/4.7.1-stable/Godot_v4.7.1-stable_linux.x86_64.zip
unzip Godot_v4.7.1-stable_linux.x86_64.zip
mkdir -p ~/bin && mv Godot_v4.7.1-stable_linux.x86_64 ~/bin/godot && chmod +x ~/bin/godot

wget https://github.com/godotengine/godot/releases/download/4.7.1-stable/Godot_v4.7.1-stable_export_templates.tpz
unzip Godot_v4.7.1-stable_export_templates.tpz
mkdir -p ~/.local/share/godot/export_templates
mv templates ~/.local/share/godot/export_templates/4.7.1.stable
```

Two things to be careful about.

**The release URL pattern is stable and predictable.** `Godot_v<version>-stable_linux.x86_64.zip`
and `Godot_v<version>-stable_export_templates.tpz` under the `<version>-stable` tag. That matters
more than it sounds — it means you never need to click through a download page, and the same two
lines work in a CI job.

**The template directory name is matched literally.** It must be exactly `4.7.1.stable`, with the
dots, matching `config/features=PackedStringArray("4.7")` in `project.godot` and the editor build
you exported with. A directory called `4.7.1` or `4.7.1-stable` produces "export templates not
found" and no hint about why.

### Why build on the box at all

You could build on a laptop and copy the artifacts over. Building on the box is nicer for one
practical reason: **export templates are a 1.28 GB download and about 1.9 GB installed**, and a
permanently-powered box is a much better place to keep that than a laptop you carry around. The
repo is already cloned there, you are already SSHed in to manage the services, and a rebuild after
a code change becomes three lines in the shell you already have open.

The tradeoff is that you now edit code over SSH. For a demo that is fine.

## 2. Import before you export

```bash
~/bin/godot --headless --import --path .
```

A fresh clone has no `.godot/` directory, which means no imported assets — every `.png`, `.gltf`,
`.ogg` and `.wav` is still just a source file with a `.import` sidecar. `--export-release` on that
state fails, because the exporter goes looking for `res://.godot/imported/...` files that were
never generated.

Run the import once after cloning. It takes a minute and prints a progress bar. After that,
exports work, and you only need to re-import if you add new assets.

This is the single most common first-run failure when building a Godot project on a machine that
has never opened it in the editor.

## 3. Point the client at the relay, before you build it

`net/net.gd`, around line 20:

```gdscript
const DEFAULT_PUBLIC_SERVER_URL := "wss://truck-town.duckdns.org/ws"
```

**This is compiled into the pck.** It is a `const` read at runtime from inside the exported game,
not a config file sitting next to it. Editing it after the web export changes nothing until you
export again and copy the result into place — which is exactly the trap described in
[05-troubleshooting.md](05-troubleshooting.md), because the page keeps loading fine and only the
connection fails.

So the order is: edit the constant, *then* `build_web.sh`, *then* copy to `/srv/trucktown`.

### The alternative that needs no rebuild

`Net.default_server_url()` resolves in priority order, and the first thing it checks is a query
parameter:

```gdscript
var override := _query_value(query, "server")
if not override.is_empty():
    return override
```

So this works against an unmodified build:

```
https://truck-town.duckdns.org/?server=wss://truck-town.duckdns.org/ws
```

Which one to use is a real choice:

| | Baked-in constant | `?server=` parameter |
|---|---|---|
| QR code | short and clean | long and ugly |
| Changing the relay | requires a rebuild | edit the URL |
| Pointing one build at several relays | no | yes |

For a QR code on a table, bake it in. For testing a deployed page against a local relay, use the
parameter. They coexist — the parameter always wins.

## 4. The two export presets

```bash
export GODOT=~/bin/godot
./scripts/build_web.sh      # -> build/web
./scripts/build_server.sh   # -> build/server/truck-town-server
```

Both scripts honour `$GODOT`, which is why they work unchanged on Linux despite defaulting to a
macOS path.

They pass preset names to `--export-release` as **literal strings**: `"Web"` and `"Linux Server"`.
Renaming a preset in the Godot editor silently breaks the build scripts, and the error ("no such
preset") is clear but easy to cause by accident.

The `Linux Server` preset matters here in a way it does not in the Fly deployment:

```ini
dedicated_server=true
binary_format/embed_pck=true
binary_format/architecture="x86_64"
```

`embed_pck=true` produces **one self-contained 82 MB file**. No `.pck` next to it, no resource
directory, no Docker image, no container runtime. You copy that single file onto the box, point a
systemd unit at it, and it runs. For a deployment that is just "a box I have SSH to", this is a
significantly simpler story than the container path, and the repo's `Dockerfile` and `fly.toml`
become dead weight you can ignore.

`dedicated_server=true` adds the feature tag that `net.gd` checks:

```gdscript
if "--server" in args or OS.has_feature("dedicated_server"):
```

So the binary would self-start as a relay with no arguments at all. We pass `-- --server` in the
systemd unit anyway — belt and braces, and it makes the unit file self-documenting.

## 5. Caddy

```bash
sudo apt install -y caddy                                  # official apt repo
sudo caddy add-package github.com/caddy-dns/duckdns
```

Caddy is the right tool here because it does three jobs that would otherwise be three programs:
terminates TLS, serves static files, and reverse-proxies the WebSocket. It also obtains and renews
the certificate itself, which removes an entire category of "the demo broke because a cron job
didn't run" failure.

The stock apt binary cannot do DNS-01 challenges — it has no DNS provider modules compiled in.
`caddy add-package` downloads a replacement binary with the module baked in, keeping the apt
package's systemd unit, `caddy` user, and `CAP_NET_BIND_SERVICE` setup. That combination is why
you get a hardened service without writing a unit file.

**`add-package` replaces the binary on disk but does not restart the running process.** This is
worth internalising now because it produces a genuinely confusing failure later; see
[05-troubleshooting.md](05-troubleshooting.md).

### The Caddyfile, line by line

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

**`truck-town.duckdns.org {`** — the site address. Caddy matches incoming requests by SNI against
this. A request for any other name gets no certificate at all, which surfaces as a TLS handshake
failure rather than a 404. This is the hyphen-mismatch trap in the troubleshooting doc.

**`dns duckdns YOUR_DUCKDNS_TOKEN`** — switches certificate issuance from the default HTTP-01/
TLS-ALPN-01 challenges to DNS-01. Mandatory here: the default challenges require Let's Encrypt to
connect *inbound* to your server, and nothing on the public internet can reach a `10.x.x.x`
address. DNS-01 proves control by publishing a TXT record instead, so the box's reachability never
enters into it.

**`propagation_delay 60s` / `propagation_timeout -1`** — after publishing the TXT record, Caddy
normally polls DNS to confirm the record is visible before telling Let's Encrypt to validate. On a
campus network that check cannot work, because outbound DNS to anything except the university's own
resolvers is blocked, and the check queries DuckDNS's authoritative nameservers directly.
`propagation_timeout -1` disables the check; `propagation_delay 60s` replaces it with a fixed wait.
Full explanation in [03-dns-01-and-duckdns.md](03-dns-01-and-duckdns.md) — this is the single line
that took the longest to arrive at.

**`handle_path /ws*`** — routes the WebSocket. `handle_path` **strips the matched prefix** before
proxying, so Godot's server receives a request for `/` rather than `/ws`. The plain `handle`
directive would forward the path intact.

The stripping is deliberate defensive design. `WebSocketMultiplayerPeer` does not route by path —
it accepts any upgrade request on its port — but "does not route by path" and "definitely ignores
an unexpected path" are different claims, and verifying the second one costs more than just not
depending on it. `handle_path` makes the question moot.

**`handle { root * /srv/trucktown; file_server }`** — everything else is the exported web build.
The bare `handle` acts as the fallback branch; because `handle` blocks are mutually exclusive, a
request for `/ws` can never fall through into the file server and vice versa.

`/srv/trucktown` rather than serving straight out of the repo checkout: Caddy runs as the `caddy`
user, home directories are commonly `750`, and a permissions failure here looks like a 403 with no
obvious cause. Copying to `/srv` costs one command and removes the question.

## 6. systemd

### The relay unit

```ini
[Unit]
Description=Truck Town relay
After=network.target

[Service]
User=YOU
ExecStart=/home/YOU/multiplayer-truck-town/build/server/truck-town-server --headless -- --server --port=8910
Restart=always

[Install]
WantedBy=multi-user.target
```

Note the bare `--` separating engine arguments from the game's own, which is the convention
described in [../00-godot-multiplayer-for-dummies.md](../00-godot-multiplayer-for-dummies.md).
`--headless` is Godot's; `--server --port=8910` are read by `net.gd` out of
`OS.get_cmdline_user_args()`.

`Restart=always` matters more than it looks. There is no supervision otherwise, and a relay that
dies mid-demo with nobody watching the journal is indistinguishable from a network problem.

This unit works. It is also the version worth replacing before you put it in front of a room.

### Hardening it

```ini
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
```

The reasoning is worth stating plainly, because it is the one security decision in this setup that
actually changes an outcome.

The relay is a **C++ binary parsing untrusted input from anyone who can reach port 8910**. The game
protocol itself cannot give anyone a shell — the RPCs are strongly typed, `_register(String, int)`
deserializes into exactly those types, and nothing in the relay writes to disk or spawns a process
based on network input. But "no logical path to code execution" is a different claim from "no
memory-safety bug anywhere in Godot's WebSocket stack", and only the first one is something you
can verify by reading the code.

So the question is not *whether* it gets exploited — realistically it won't — but what it costs if
it does. Running as your own user, the answer is your SSH keys, your files, and your sudo access.
With the block above:

| Directive | What it buys |
|---|---|
| `DynamicUser=yes` | A transient UID that exists only while the service runs. Nothing owned by it, nothing to escalate from. |
| `ProtectHome=yes` | `/home` is invisible to the process. Your `.ssh` directory does not exist from its point of view. |
| `ProtectSystem=strict` | The entire filesystem is read-only to it. The relay writes nothing, so it loses nothing. |
| `NoNewPrivileges=yes` | No setuid binary can raise privileges, ever. |
| `CapabilityBoundingSet=` | Empty — no capabilities at all. |
| `PrivateTmp` / `PrivateDevices` | Its own `/tmp`, no device access. |

**`DynamicUser` requires the binary to live outside `/home`**, because `ProtectHome=yes` hides it
from the very process trying to execute it. Copy it to `/srv/trucktown-server/` first. Getting this
backwards produces a service that fails to start with a permissions error pointing at a file that
is plainly readable when you check by hand.

Check the result:

```bash
systemd-analyze security trucktown
```

Under about 4.0 is solid. If the service fails to start, remove `RestrictAddressFamilies` first —
it is the line most likely to collide with something the engine wants.

## 7. Keeping DNS honest

Optional, and worth being honest about the actual risk.

```ini
# duckdns.service
[Service]
Type=oneshot
ExecStart=/bin/bash -c 'curl -fsS "https://www.duckdns.org/update?domains=truck-town&token=YOUR_DUCKDNS_TOKEN&ip=$(ip -4 -o addr show enp2s0 | awk "{print \$4}" | cut -d/ -f1)"'
```

```ini
# duckdns.timer
[Timer]
OnBootSec=1min
OnUnitActiveSec=5min
```

A `dynamic` address with a `valid_lft` countdown looks alarming, and it is easy to conclude the IP
is about to change. It isn't. `valid_lft` is a **renewal** countdown, not an eviction notice: the
DHCP client renews at roughly half the lease, the server looks the client up by MAC address, and
hands back the same binding. A box that stays powered and stays in the same switch port typically
holds its address for months.

What would actually change it:

- The box is off long enough for the lease to expire *and* the address gets reassigned
- Network maintenance, a VLAN change, or a different switch port
- A new NIC, so a new MAC

None of those happen spontaneously. So the timer is **insurance against a reboot or a port change**,
not a fix for a looming problem — it makes the record self-heal within five minutes instead of you
discovering the breakage at the table.

The proportionate alternative, if you would rather not run a timer, is a morning-of check:

```bash
ip -4 -o addr show enp2s0 | awk '{print $4}' | cut -d/ -f1
dig +short truck-town.duckdns.org
```

If those two agree, you are fine. If not, one curl fixes it.

Note that the updater uses **HTTPS on 443**, not DNS on 53 — which is why it works on a network
that blocks outbound DNS, the same network that breaks Caddy's propagation check.

## 8. Firewall

```bash
sudo ufw allow 22/tcp
sudo ufw allow 80/tcp
sudo ufw allow 443/tcp
sudo ufw enable
```

> **Allow 22 before you enable.** `ufw enable` applies default-deny immediately. On a box you
> administer over SSH, enabling the firewall without an SSH rule in place drops your session and
> locks you out, and recovering means physical access to the machine. Run the rules in the order
> above, in one go.

Port 8910 is deliberately absent. Default-deny handles it, and that matters because the relay is
directly exposed without it:

```gdscript
_peer.create_server(_server_port, "*")
```

The `"*"` is the **bind address**, not a wildcard for allowed clients — it means all interfaces. So
`ws://10.x.x.x:8910` is reachable from the whole network, bypassing Caddy and TLS entirely. Nothing
catastrophic follows from that (it is the same game either way), but there is no reason to offer a
plaintext path to a service that already has an encrypted one.

Caddy still reaches it, because **ufw always permits loopback traffic** — its default rules accept
everything on `lo` before any other rule is consulted. The proxy hop is `localhost:8910`, so it is
unaffected. Confirm the game still works after enabling, so you learn about a mistake now rather
than at the table.

## 9. Verification

There is no test suite. Verification is running things and reading logs, exactly as in
[../05-gotchas-and-verification.md](../05-gotchas-and-verification.md).

**The certificate and static serving:**

```bash
curl -I https://truck-town.duckdns.org
```

`HTTP/2 200` with no TLS error means the certificate is valid and the file server is working.

**The WebSocket path:**

```bash
curl -is -H "Connection: Upgrade" -H "Upgrade: websocket" \
     -H "Sec-WebSocket-Version: 13" \
     -H "Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==" \
     https://truck-town.duckdns.org/ws | head -5
```

| Response | Meaning |
|---|---|
| `101 Switching Protocols` | Proxy and relay are both fine |
| `502` | Caddy cannot reach 8910 — relay is down |
| `404` or HTML | `handle_path` is not matching; you hit the file server |

**The services:**

```bash
journalctl -u caddy -f
journalctl -u trucktown -f
```

The relay prints on startup:

```
Truck Town server listening on port 8910 (max 8 players)
```

and on each join:

```
Peer 1234567890 joined as Player (truck 0). Players: 1
```

**The real test** is still two clients driving at once. A single client proves TLS, static serving,
and that the relay accepts a connection — but a client happily rendering its own truck alone looks
identical to working multiplayer. Two phones, two trucks, each visible on the other's screen, is
the only thing that proves replication end to end.

---

**Next:** [05-troubleshooting.md](05-troubleshooting.md) for everything that went wrong on the way
here. [quick-unhost.md](quick-unhost.md) to take it all back down.
