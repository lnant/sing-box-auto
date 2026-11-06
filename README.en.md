# sing-box-auto

One-command, **fully unattended** installers for [sing-box](https://sing-box.sagernet.org/).
No interactive prompts: ports, certificates, UUIDs and keys are generated automatically
with sensible defaults. ([中文说明](README.md))

## Editions

| | `sing-box-auto.sh` (Argo 6-in-1) | `sing-box-vless.sh` (lite) |
|---|---|---|
| Protocols | VLESS+Reality, VMess+WS, VMess+Argo tunnel, Hysteria2, TUIC, AnyTLS | VLESS+Reality only |
| Best for | Multiple fallback routes | A single, simple node |

## Install

Argo 6-in-1 edition:

```bash
curl -fsSL https://raw.githubusercontent.com/lnant/sing-box-auto/main/sing-box-auto.sh | sudo bash
```

Lite edition (VLESS + Reality only):

```bash
curl -fsSL https://raw.githubusercontent.com/lnant/sing-box-auto/main/sing-box-vless.sh | sudo bash
```

Requirements: a Linux server (Debian / Ubuntu / CentOS / Oracle Linux, etc.), **root**,
x86_64 / arm64 / armv7. ≥1 GB RAM recommended (add swap below that). With systemd,
the service and the Argo tunnel are systemd-managed (auto-restart on crash); without
systemd the script falls back to cron `@reboot` entries.

To pin a released version instead of `main`, replace `main` in the URL with a tag,
e.g. `.../sing-box-auto/v1.1.0/sing-box-auto.sh`. Current version: **v1.1.1**
(see [CHANGELOG.md](CHANGELOG.md) and GitHub Releases).

## After install

- All client links (`vless://`, `vmess://`, `hysteria2://`, `tuic://`, `anytls://`)
  are printed in the terminal and saved to **`/root/singbox-links.txt`**.
- Ports are randomly assigned in **10000–60000** on first install (conflict-free) and
  kept on re-runs (idempotent). UUID / Reality keys / ports live in
  `/etc/s-box/auto.env`; the config is `/etc/s-box/sb.json`.
- The systemd unit is `sing-box-auto` (lite: `sing-box-vless`) — it does not clash
  with other sing-box installations on the same machine.
- The script only opens the **OS firewall** (incrementally — it never disables your
  firewall or flushes existing rules). Remember to also allow the same ports in your
  cloud provider's security group / security list.
- Pure-IPv6 servers work (dual-stack listen, ip6tables, bracketed link addresses);
  the installer first probes GitHub reachability (GitHub is IPv4-only) and, on
  IPv6-only / broken-IPv4 hosts, bootstraps DNS64 (nat64.net, with backup and
  auto-restore) before downloading; the client side still needs IPv6
  connectivity, except for the VMess+Argo link,
  which goes through Cloudflare's tunnel.

## Management

The full edition installs an `sbox` shortcut:

```bash
sbox            # open the management menu
sbox <action>   # change-uuid | change-reality | change-cert | change-argo
                # change-ports | show-links | restart | uninstall
                # update-script | update-core | version
```

`update-core` upgrades the sing-box binary to the latest upstream release with
backup + config validation + automatic rollback on failure. `update-script`
upgrades the script itself to the latest GitHub Release.

## Uninstall

```bash
curl -fsSL https://raw.githubusercontent.com/lnant/sing-box-auto/main/sing-box-auto.sh | sudo bash -s -- uninstall
```

Uninstalling removes the binary, config, links file, systemd units, the `sbox`
command and cron entries. It does **not** revert: firewall allow rules added at
install time, the SELinux Permissive setting, or the disabled `dnf-makecache`
timer (all harmless leftovers; remove manually if you care).

## Troubleshooting

1. Nothing connects → check the cloud security group first (see above).
2. `ss -tulnp | grep sing-box` — are the ports actually listening?
3. `journalctl -u sing-box-auto -n 50` (lite: `sing-box-vless`) for service logs.
4. Only Hysteria2/TUIC fail → UDP is likely blocked by the provider; try other
   UDP ports (menu item 4) and make sure the security group allows UDP.
5. Reality suddenly fails → check clock sync with `timedatectl` (Reality is
   clock-sensitive) and, on RHEL-family systems, that SELinux is not Enforcing
   (`getenforce`; install sets it to Permissive).

## Notes

- Do not install both editions on one machine — they share `/etc/s-box/`.
- Links for self-signed-certificate protocols carry `insecure=1` (certificate
  verification skipped; the UUID is the actual credential). Keep links private.
- Features common in similar scripts — WARP routing, subscriptions, Telegram
  notifications — are intentionally left out. Core proxying only.
