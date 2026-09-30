# Homelab certificates

All internal services are served over HTTPS by Traefik using a wildcard certificate signed by our own **Homelab Root CA**. Browsers and phones only trust that certificate after the Root CA is installed on them — **once per device**.

## Domain: `home.arpa` (RFC 8375)

Internal hostnames use the `home.arpa` domain, reserved by [RFC 8375](https://www.rfc-editor.org/rfc/rfc8375) for residential/home networks. It is never delegated on the public Internet, so it can't collide with a real domain (unlike `.local`, which belongs to mDNS, or made-up TLDs like `.lan`/`.home`).

Every service follows the pattern `<service>.home.arpa`:

```text
https://traefik.home.arpa
https://nextcloud.home.arpa
https://ai.home.arpa
https://pihole.home.arpa
```

Name resolution is done by Pi-hole: `*.home.arpa → 192.168.1.4` (Traefik).

## Generating the certificates

```bash
make certs            # or: make traefik-reload (certs + redeploy Traefik)
```

This creates (under `certs/homelab/`, which is git-ignored):

| File | Purpose | Where it goes |
|------|---------|---------------|
| `ca/homelab-root-ca.crt` | Root CA public certificate (10 years) | Installed on every client device |
| `ca/homelab-root-ca.key` | Root CA private key | **Never leaves this machine** |
| `traefik/home.arpa.crt` / `.key` | Certificate with one SAN per Traefik host (825 days) — no `*.home.arpa` wildcard, since `home.arpa` is a public suffix and Apple rejects it; run `make traefik-reload` after adding a service | Deployed to Traefik |

The Root CA is only created if it doesn't exist yet, so re-running the script just renews the Traefik certificate — devices don't need to reinstall anything. The domain comes from `HOMELAB_DOMAIN` in `.env`.

> Only ever share `homelab-root-ca.crt`. Anyone holding `homelab-root-ca.key` can issue certificates your devices will trust.

## Installing the Root CA on devices

### macOS

```bash
sudo security add-trusted-cert -d -r trustRoot \
    -k /Library/Keychains/System.keychain certs/homelab/ca/homelab-root-ca.crt
```

Restart the browser. Firefox uses its own store: **Settings → Privacy & Security → Certificates → View Certificates → Authorities → Import**.

### Linux (Debian/Ubuntu)

```bash
sudo cp homelab-root-ca.crt /usr/local/share/ca-certificates/
sudo update-ca-certificates
```

### Windows

Double-click `homelab-root-ca.crt` → **Install Certificate → Local Machine → Trusted Root Certification Authorities**.

### iPhone / iPad

1. Send `homelab-root-ca.crt` to the device (e.g. AirDrop) and open it — iOS offers to install the profile.
2. **Settings → General → VPN & Device Management** → install the downloaded profile.
3. **Settings → General → About → Certificate Trust Settings** → enable full trust for **Homelab Root CA**.

### Android

1. Transfer `homelab-root-ca.crt` to the device.
2. **Settings → Security → Encryption & credentials → Install a certificate → CA certificate** (exact path varies by vendor/version) and select the file.

Browsers accept user-installed CAs, but some Android apps deliberately ignore them. Browser access to the homelab is not affected.

## DNS: trust is not enough

The certificate only solves HTTPS trust — the device must also use Pi-hole as its DNS to resolve `*.home.arpa`. On the home Wi-Fi this happens automatically, since Pi-hole is the DHCP server.

On Android, **Private DNS** (Settings → Connections → More connection settings → Private DNS) must be **Off**. When it points to a provider such as `dns.adguard.com` or `dns.google`, Android sends every lookup there over DNS-over-TLS, bypassing Pi-hole, and apps report "Could not find host" for `*.home.arpa`.

Outside the home network (4G/5G, other Wi-Fi) `*.home.arpa` does **not** resolve, and that is intentional: these services are internal only. For remote access, the plan is a VPN (WireGuard/Tailscale) that pushes Pi-hole as DNS, instead of exposing Traefik to the Internet.
