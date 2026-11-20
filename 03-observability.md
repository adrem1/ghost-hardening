# Part 3: Observability

This part runs a monitoring stack, Prometheus with its exporters and Grafana, and hardens it. The point is to see what the server is doing without leaving the monitoring open to anyone else. It assumes Part 1 is in place, and that Prometheus, the exporters, and Grafana are already installed.

**Contents**

- [3.1 Run Prometheus as its own user](#31-run-prometheus-as-its-own-user)
- [3.2 Bind the exporters and Grafana to loopback](#32-bind-the-exporters-and-grafana-to-loopback)
- [3.3 Publish Grafana through Tailscale Serve](#33-publish-grafana-through-tailscale-serve)
- [3.4 Check what the monitoring exposes](#34-check-what-the-monitoring-exposes)
- [3.5 Alerts](#35-alerts)
- [3.6 Part 3 checks](#36-part-3-checks)
- [3.7 Gotchas](#37-gotchas)

---

## 3.1 Run Prometheus as its own user

Many stock installs run Prometheus as root, from a script in a user's home directory. Anyone who can edit that script, or the binary next to it, can run code as root. Give Prometheus its own account, and keep its binaries and configuration root-owned.

### Create the user and directories

```bash
sudo useradd --system --no-create-home --shell /usr/sbin/nologin "$PROM_USER"
sudo install -d -o root -g root -m 755 "$PROM_BIN_DIR" "$PROM_CONF_DIR"
sudo install -d -o "$PROM_USER" -g "$PROM_USER" -m 750 "$PROM_DATA_DIR"
```

### Copy the binaries and configuration into root-owned paths

Set `OLD` to wherever your current installation lives:

```bash
OLD=<CURRENT_PROMETHEUS_DIR>
sudo install -m 755 -o root -g root "$OLD/prometheus" "$OLD/promtool" "$PROM_BIN_DIR/"
sudo install -m 644 -o root -g root "$OLD/prometheus.yml" "$PROM_CONF_DIR/prometheus.yml"
"$PROM_BIN_DIR/promtool" check config "$PROM_CONF_DIR/prometheus.yml"    # must say SUCCESS
```

### Move the data, then start under the new user

Stop the old service first, so the data is copied in a consistent state:

```bash
sudo systemctl stop <OLD_PROMETHEUS_UNIT>
sudo cp -a "$OLD/data/." "$PROM_DATA_DIR/"
sudo chown -R "$PROM_USER:$PROM_USER" "$PROM_DATA_DIR"
```

### Write the unit

> [!CAUTION]
> systemd doesn't expand shell variables in unit files. Write the real paths in, replacing each placeholder with the value from `env.local`. A literal `$PROM_BIN_DIR` stays literal, and the service fails to start.

`/etc/systemd/system/prometheus.service`:

```ini
[Unit]
Description=Prometheus
Wants=network-online.target
After=network-online.target

[Service]
Type=simple
User=<PROM_USER>
Group=<PROM_USER>
ExecStart=<PROM_BIN_DIR>/prometheus \
  --config.file=<PROM_CONF_DIR>/prometheus.yml \
  --storage.tsdb.path=<PROM_DATA_DIR> \
  --storage.tsdb.retention.time=<PROM_RETENTION> \
  --web.listen-address=127.0.0.1:<PROM_PORT>
Restart=on-failure
NoNewPrivileges=true
ProtectSystem=strict
ProtectHome=true
PrivateTmp=true
ReadWritePaths=<PROM_DATA_DIR>

[Install]
WantedBy=multi-user.target
```

```bash
sudo systemctl daemon-reload
sudo systemctl enable --now prometheus
ps -o user=,args= -C prometheus          # the first column must be <PROM_USER>, not root
```

The listen address is `127.0.0.1`, so Prometheus is reachable only from this machine. See [3.3](#33-publish-grafana-through-tailscale-serve) for how Grafana reaches it.

---

## 3.2 Bind the exporters and Grafana to loopback

Only the local Prometheus needs to scrape the exporters on this machine, so each one can listen on loopback. Use a drop-in for each unit, so the distribution's unit files stay as they are. The empty `ExecStart=` line clears the original command. Without it, systemd refuses to start the service because it sees two.

Check the binary path first, since it differs between installs:

```bash
command -v node_exporter
command -v nut-exporter
```

`sudo systemctl edit node_exporter`:

```ini
[Service]
ExecStart=
ExecStart=<NODE_EXPORTER_PATH> --web.listen-address=127.0.0.1:<NODE_EXPORTER_PORT>
```

`sudo systemctl edit nut_exporter`, if you run a UPS and its exporter, with the listen flag from `nut-exporter --help`:

```ini
[Service]
ExecStart=
ExecStart=<NUT_EXPORTER_PATH> --web.listen-address=127.0.0.1:<NUT_EXPORTER_PORT>
```

Grafana stays reachable through Tailscale Serve, which forwards to `localhost`. Set its bind address in `/etc/grafana/grafana.ini`, under `[server]`:

```ini
http_addr = 127.0.0.1
```

Restart the services and confirm each one listens on loopback only:

```bash
sudo systemctl restart node_exporter nut_exporter grafana-server prometheus
ss -tlnp | grep -E ":($NODE_EXPORTER_PORT|$NUT_EXPORTER_PORT|3000|$PROM_PORT)\b"
```

Every line should show `127.0.0.1`.

---

## 3.3 Publish Grafana through Tailscale Serve

Tailscale Serve publishes a local service on your tailnet, under a name you choose, with the connection encrypted and authenticated by your tailnet identity. Grafana, bound to loopback, is reached through it, so the dashboard is available to tailnet devices your ACL allows and to nobody else.

Check what's already configured, then point the service at Grafana:

```bash
tailscale serve status
```

Point the service at `http://localhost:3000`. Once it's running, Grafana is available at `https://$GRAFANA_HOST`. Only tailnet devices that the ACL in [Part 1, section 1.2](./01-host-hardening.md#12-tailscale-and-the-tailnet-acl) allows can open it.

---

## 3.4 Check what the monitoring exposes

Two settings change what an outsider could learn or do through the monitoring. Confirm both on your own system.

**Grafana's anonymous access.** It should be off, so the API and dashboards need a login. Check that an unauthenticated request is refused:

```bash
curl -s -o /dev/null -w "%{http_code}\n" "http://127.0.0.1:3000/api/search"
```

Expect `401`.

**Prometheus's admin and lifecycle APIs.** They let someone reload or change Prometheus. Keep them off, which is the default. Check the flags:

```bash
curl -s "http://127.0.0.1:$PROM_PORT/api/v1/status/flags" | python3 -c "import json,sys; d=json.load(sys.stdin)['data']; print({k: d.get(k) for k in ['web.enable-lifecycle','web.enable-admin-api']})"
```

Both should be `false`.

Prometheus also serves its configuration at `/api/v1/status/config`, which lists your scrape targets. Keep the listener on loopback, as in [3.1](#31-run-prometheus-as-its-own-user), so this endpoint isn't reachable from the network.

> [!TIP]
> To use the Prometheus interface from another machine, tunnel it over SSH rather than opening the port: `ssh -L <LOCAL_PORT>:127.0.0.1:$PROM_PORT -p "$SSH_PORT" "$ADMIN_USER@$TS_IP"`.

---

## 3.5 Alerts

A dashboard is only useful if someone looks at it. An alert on a metric you care about tells you when something's wrong. Start with one or two:

- **The host is up**: the exporter's metric is present, and the target is `up`.
- **A disk is filling**: free space on the disk that holds your data.
- **The service is down**: the Ghost or Grafana target is `down`.

Alert rules can treat missing data as a state of their own. Decide how that state should behave for each rule. A planned restart or a disk swap will look like "no data", and that's expected, not a fault.

---

## 3.6 Part 3 checks

| Check | Expected |
|-------|----------|
| Prometheus user | Runs as `$PROM_USER`, not root |
| Prometheus binaries and config | Root-owned; not writable by the admin account |
| Listeners | Prometheus, exporters, and Grafana all on `127.0.0.1` |
| Grafana | Reachable through Tailscale Serve on your tailnet; anonymous API access refused |
| Prometheus flags | Admin and lifecycle APIs disabled |
| Scrape targets | All targets `up`, or a `down` target you can account for |

---

## 3.7 Gotchas

### systemd doesn't expand variables

A `$VARIABLE` written into a unit file stays literal, and the service fails to start. Write the real paths in.

### The empty `ExecStart=` line is required

In a drop-in, the first `ExecStart=` must be empty to clear the original command. Without it, systemd refuses to start the service because it sees two.

### A `down` target can be expected

If a scrape target is a machine that isn't exporting metrics yet, it shows as `down`. That's not a fault in this stack. Account for it, and fix it when that machine is ready.

### Missing data during downtime

Planned restarts, image copies, and hardware swaps leave gaps in the metrics. Grafana shows those gaps correctly. Alert rules that treat missing data as a problem will fire during them, so decide how each rule should behave.
