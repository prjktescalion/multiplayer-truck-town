# Teardown: what you are undoing, and why the order matters

The companion to [quick-unhost.md](quick-unhost.md). That file is the command sequence for when you
already know what you are doing. This one explains what each removal step is actually undoing, what
to check afterwards, and which parts of the setup you genuinely cannot take back.

Read [04-serving-the-box.md](04-serving-the-box.md) first if you want the mirror image — this
document assumes you followed that one and now want the box back.

The guiding idea: **hosting a service is not one change, it is about a dozen small ones scattered
across the filesystem.** Most guides tell you how to set something up and never mention that
`apt remove` leaves behind config, state, keyrings, and a firewall you didn't have before. Knowing
the full inventory is the difference between "removed" and "actually gone".

## The inventory

Everything the hosting process created or modified, by category.

### Packages and apt configuration

| Path | What it is |
|---|---|
| `caddy` package | Installed from Cloudsmith, not from Debian/Ubuntu's own repos |
| `/etc/apt/sources.list.d/caddy-stable.list` | The extra apt source that made that possible |
| `/usr/share/keyrings/caddy-stable-archive-keyring.gpg` | The GPG key apt uses to trust that source |
| `ufw`, `fail2ban` | Optional, only if you added them |

Removing the `caddy` package does **not** remove the apt source or the keyring. They are separate
files that apt will keep consulting on every `apt update` forever, quietly, until you delete them.
This is the single most commonly forgotten leftover.

### The Caddy binary, which is not the packaged one

`sudo caddy add-package github.com/caddy-dns/duckdns` replaces `/usr/bin/caddy` in place with a
freshly compiled binary that includes the DuckDNS DNS provider module. The apt package metadata
still claims ownership of that path, but the file on disk no longer matches what apt installed.

Practically this means `apt remove caddy` will still delete the file, so it does get cleaned up. But
it is worth understanding that between `add-package` and removal, your system had a binary at a
package-managed path that the package manager could not verify. That is also why
`systemctl reload caddy` failed for us and `restart` was needed — see
[05-troubleshooting.md](05-troubleshooting.md).

### Configuration

| Path | Notes |
|---|---|
| `/etc/caddy/Caddyfile` | **Contains your DuckDNS API token in plaintext** |

`apt remove` leaves this file behind. `apt purge` removes it. That distinction matters here more
than usual precisely because of the token.

### systemd units you wrote

| Path | Purpose |
|---|---|
| `/etc/systemd/system/trucktown.service` | Runs the relay binary |
| `/etc/systemd/system/duckdns.service` | Optional. Pushes the current IP to DuckDNS |
| `/etc/systemd/system/duckdns.timer` | Optional. Fires the above every 5 minutes |

`duckdns.service` also contains the token, if you created it.

Deleting a unit file is not enough on its own. `systemctl enable` creates a symlink in
`/etc/systemd/system/multi-user.target.wants/` (or `timers.target.wants/` for the timer), and
leaving a dangling symlink there produces warnings on every boot. `systemctl disable` before
deleting, or `systemctl daemon-reload` afterwards, resolves it.

### State Caddy wrote on its own

| Path | What it holds |
|---|---|
| `/var/lib/caddy/.local/share/caddy/acme/` | Your ACME account private keys, per CA |
| `/var/lib/caddy/.local/share/caddy/certificates/` | Issued certificates and their private keys |
| `/var/lib/caddy/.local/share/caddy/ocsp/` | Cached OCSP staples |
| `/var/lib/caddy/.config/caddy/autosave.json` | The last config Caddy loaded, as JSON |

This directory is the one people forget exists. You never created it and never edited it, so it does
not feel like yours — but it contains private key material. It survives `apt remove` and it survives
`apt purge`, because it lives under `/var/lib` and belongs to the `caddy` system user rather than to
the package.

### Content you placed

| Path | What it is |
|---|---|
| `/srv/trucktown/` | The exported web build (~52 MB) |
| `/srv/trucktown-server/` | Optional. The relay binary, if you moved it out of `$HOME` for `DynamicUser` |

### The Godot toolchain in your home directory

| Path | Size |
|---|---|
| `~/bin/godot` | ~100 MB |
| `~/.local/share/godot/export_templates/4.7.1.stable/` | **~1.3 GB** |
| `~/Godot_v4.7.1-stable_linux.x86_64.zip` | The download, if you never deleted it |
| `~/Godot_v4.7.1-stable_export_templates.tpz` | Likewise |
| `~/multiplayer-truck-town/.godot/` | Import cache, regenerated on demand |
| `~/multiplayer-truck-town/build/` | Export output, gitignored |

None of this is exposed to the network and none of it is a security concern. It is purely a
disk-space question, which is why it comes last in the teardown and why leaving it is entirely
reasonable.

### The firewall

If you ran `ufw enable`, that is itself a change of system state, independent of the individual
rules. A box with an active default-deny firewall behaves differently from one without, and other
services you run later will be affected. Disabling ufw restores the previous behaviour; removing the
package removes the rules too.

### The dynamic user that leaves nothing behind

`DynamicUser=yes` in `trucktown.service` creates a transient UID that exists only while the service
is running. There is no entry in `/etc/passwd`, no home directory, and nothing to clean up. When the
service stops, the user ceases to exist.

This is worth calling out because it is the one part of the setup with **no teardown step at all**,
and that is a feature. Contrast it with the conventional approach of `useradd trucktown`, which
leaves a permanent account behind that you then have to remember to remove.

### State that is not on the box at all

Two things live elsewhere and cannot be removed by any command you run on the machine:

- **The DuckDNS subdomain and its token.** These belong to your DuckDNS account. Deleting
  `/etc/caddy/Caddyfile` does not invalidate the token, and stopping Caddy does not remove the DNS
  record. The record will keep resolving to `10.x.x.x` until you change or delete it on
  duckdns.org.
- **A Let's Encrypt ACME account**, registered during the first certificate request and identified
  by the key in `/var/lib/caddy/.local/share/caddy/acme/`. Deleting that directory orphans the
  account rather than closing it.

## Teardown order, and why

The order is not arbitrary. Each step below depends on the one before it.

**1. Stop the services before removing their units.**
A running service holds an open socket and, in the relay's case, connected players. Deleting
`trucktown.service` while it runs leaves an orphaned process that systemd no longer tracks — you
would then have to find and kill it by PID. Stop first, then remove.

**2. Disable before deleting unit files.**
As above: `disable` removes the `*.wants/` symlink. Deleting the unit file first leaves the symlink
dangling and systemd complains on every boot about a unit it cannot find.

**3. Remove units before deleting the binaries they point at.**
If `/srv/trucktown-server/truck-town-server` disappears while an enabled service still references
it, the service enters a restart loop, failing every few seconds and filling the journal. Harmless
but noisy, and confusing to whoever finds it later.

**4. Deal with certificates before discarding the ACME state.**
The account key in `/var/lib/caddy/.local/share/caddy/acme/` is what authorises you to revoke a
certificate you were issued. Delete that directory and you lose the ability to revoke — the
certificate stays valid until it expires (90 days) with no way for you to shorten that. If you care
about revocation, do it first. For a campus demo on a private IP you almost certainly do not, but
the ordering constraint is real and worth understanding.

**5. Remove the apt source and keyring when you remove the package.**
Otherwise every future `apt update` keeps hitting Cloudsmith for a package you no longer use.

**6. Touch the firewall last.**
Tearing down with the firewall still up means nothing is exposed during the intermediate states.
Disable it once the services are already gone, not before. And if you are working over SSH, remember
that firewall changes are the classic way to lock yourself out — verify port 22 is still permitted
before every `ufw` command you run.

## What is safe — and sensible — to leave

Not everything should come off. Being opinionated about this:

**Keep `ufw`.** You almost certainly should have had a firewall before this project, and now you do.
Removing it makes the box less safe than when you started, which is a strange outcome for a cleanup.
Leave it enabled with just port 22 allowed.

**Keep `fail2ban`.** Same reasoning. It needs no configuration, costs nothing, and its value is
entirely independent of this project.

**Keep the DuckDNS subdomain.** It costs nothing, occupies no resources, and you will want it again
the next time you demo something. Repointing it later is one HTTP request. The only reason to delete
it is if you would rather the name stopped resolving to an internal address.

**Keep the Godot toolchain** unless you need the 1.3 GB. It is inert. If you plan to rebuild the
project on this box ever again, re-downloading export templates is slow and annoying.

**Remove the Caddyfile and rotate the token**, though. That one is not optional — see below.

## What you cannot undo

**Every certificate ever issued for your hostname is in the public record, permanently.**

Certificate Transparency requires every CA to publish every certificate it issues to append-only
public logs. Anyone can search those logs — [crt.sh](https://crt.sh) is the usual tool — and find
that `truck-town.duckdns.org` existed, when it was issued, when it was renewed, and which CA signed
it.

Revoking a certificate marks it invalid. It does not remove the log entry. Nothing removes the log
entry; that is the entire point of an append-only log.

This is normal and applies to every HTTPS site on the internet. It is worth knowing for two reasons:

- The **hostname** is public knowledge forever, even after you stop using it. The private IP behind
  it is not in the certificate, so that part is not disclosed — but the name is.
- If you ever pick a hostname you would not want associated with you, that decision is permanent at
  the moment of issuance, not at the moment of deployment.

Use a boring name. `truck-town` is a fine choice for exactly this reason.

## Verifying the teardown actually worked

Four checks. Run all of them; each catches a different class of leftover.

**Nothing is listening that should not be:**

```bash
sudo ss -lntp
```

Neither `8910` nor Caddy on `80`/`443` should appear. What remains should look like the box did
before you started — loopback-bound services and SSH.

**No units remain, running or otherwise:**

```bash
systemctl list-units --all | grep -E 'caddy|trucktown|duckdns'
```

Empty output. The `--all` matters: without it, stopped-but-still-present units are hidden, which is
exactly the leftover you are checking for.

**DNS behaves as you expect:**

```bash
dig +short truck-town.duckdns.org
```

If you kept the subdomain, this still returns `10.x.x.x` — correctly, since the record is unchanged
and the box is simply no longer answering on it. If you deleted the subdomain, expect empty output.
A stale answer here is not a teardown failure; it is DNS doing its job on state that lives on
DuckDNS, not on your machine.

**The repository is clean:**

```bash
cd ~/multiplayer-truck-town && git status --short
```

The one edit made during setup was `DEFAULT_PUBLIC_SERVER_URL` in `net/net.gd`. Decide deliberately
whether to keep or revert it — `git checkout net/net.gd` reverts, but if the change was committed,
that is a commit to undo rather than a working-tree change.

**Bonus — confirm the apt source is gone:**

```bash
sudo apt update 2>&1 | grep -i caddy
```

Silence means the Cloudsmith source is genuinely removed rather than merely unused.

## Credential hygiene

The DuckDNS token is the one piece of this that is a real secret, and it ends up in more places than
you would expect:

- `/etc/caddy/Caddyfile`
- `/etc/systemd/system/duckdns.service`, if you created it
- `~/.bash_history`, from any `curl` you ran by hand to test the update endpoint
- Terminal scrollback, screenshots, and anywhere you pasted a config while debugging

**Deleting those files is not revocation.** A token that has been exposed stays valid until you
rotate it on duckdns.org, regardless of what you delete locally. Anyone holding it can repoint your
subdomain at an address of their choosing — which, for a name people have been told to trust and
scan a QR code for, is worth taking seriously.

So the actual revocation step is: log into duckdns.org and regenerate the token. Everything else is
tidying.

If you want the history entries gone too:

```bash
history -c && history -w
```

Though note this clears your entire shell history, and does nothing about other sessions' files.

## Where to go next

- [quick-unhost.md](quick-unhost.md) — the bare command sequence
- [quick-guide.md](quick-guide.md) — the setup equivalent, if you are putting it back
- [04-serving-the-box.md](04-serving-the-box.md) — what each piece was doing while it ran
- [05-troubleshooting.md](05-troubleshooting.md) — the errors hit along the way, including the ones
  whose fixes left extra state behind
