# Standalone deployment

The standalone release is a self-extracting executable containing Paseo Relay,
the BEAM application, and the target platform's ERTS. The host does not need
Docker, Elixir, or Erlang. On first start, Burrito extracts the payload into the
current user's platform data directory; later starts reuse that payload.

The standalone artifacts currently certify single-node operation only. Use the
existing Docker/Fly deployment for clustered ownership and provider rerouting.

## Artifacts

Tagged GitHub releases contain these unsigned binaries and `SHA256SUMS.txt`:

- `paseo-relay-vVERSION-linux-x86_64`
- `paseo-relay-vVERSION-linux-aarch64`
- `paseo-relay-vVERSION-windows-x86_64.exe`
- `paseo-relay-vVERSION-macos-x86_64`
- `paseo-relay-vVERSION-macos-aarch64`

Verify the checksum before installation. macOS Gatekeeper and Windows
SmartScreen may require an explicit local exception because the first release
does not include code signing or notarization.
Windows and macOS executables are provided for direct foreground use only;
this release does not include a supported background-service installer for
either platform.

## Direct start

The relay should listen on loopback behind a TLS reverse proxy:

```sh
export PASEO_RELAY_HOST=127.0.0.1
export PASEO_RELAY_PORT=4000
export PASEO_RELAY_MIN_CLUSTER_SIZE=1
./paseo-relay-vVERSION-linux-x86_64 --no-halt
```

The existing `PASEO_RELAY_*` settings documented in the root README remain
available. This standalone path is a single-node entrypoint: `RELEASE_NODE`,
`RELEASE_COOKIE`, and DNS discovery do not turn it into the supported clustered
deployment. Use the standard OTP release or Docker/Fly path for clustering.
`GET /health` checks process liveness and `GET /ready` checks whether the node
accepts new sessions.

## Linux systemd

Create the service account, install the selected binary, and install the unit:

```sh
sudo useradd --system --home /var/lib/paseo-relay --create-home --shell /usr/sbin/nologin paseo-relay
sudo install -m 0755 paseo-relay-vVERSION-linux-x86_64 /usr/local/bin/paseo-relay
sudo install -d -m 0750 /etc/paseo-relay
sudo install -m 0640 deployment/standalone/paseo-relay.env.example /etc/paseo-relay/paseo-relay.env
sudo install -m 0644 deployment/standalone/paseo-relay.service /etc/systemd/system/paseo-relay.service
sudo systemctl daemon-reload
sudo systemctl enable --now paseo-relay
```

Inspect health and logs:

```sh
curl --fail http://127.0.0.1:4000/health
curl --fail http://127.0.0.1:4000/ready
sudo journalctl -u paseo-relay --follow
```

For an upgrade, verify the new checksum, stop the service, atomically replace
`/usr/local/bin/paseo-relay`, then start it and verify both endpoints. The stop
disconnects all sessions owned by this single node.

## Public TLS

Clients always use `/ws` with routing parameters in the query string. The proxy
must preserve that path and query string and pass WebSocket Upgrade headers.

`Caddyfile.example` provides automatic HTTPS and WebSocket proxying. Replace
`relay.example.com`, install the file, and reload Caddy.

`nginx.conf.example` provides the equivalent Nginx configuration. Replace the
hostname and certificate paths before reloading Nginx. Both examples expose:

```text
wss://relay.example.com:443/ws
```

Configure Paseo with `relay.example.com:443` and TLS enabled for the public
device address. A Daemon on the same private network may instead use
`private-relay-address:4000` with TLS disabled, but both addresses must reach
the same relay node.

## Local builds

Build from Linux, macOS, or WSL with Elixir 1.20, OTP 29, Zig 0.16.0, XZ, and
7z/7zz when the Windows target is included:

```sh
bash scripts/build-standalone.sh
BURRITO_TARGET=linux_x86_64 bash scripts/build-standalone.sh
```

Artifacts and checksums are written to `dist/`. Native Windows is not a
supported build host; use WSL for local Windows development.
