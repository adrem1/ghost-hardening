# Part 1: Host Hardening

This part covers the base of the server: remote access, the network controls, the services that run on it, file-integrity monitoring, malware scanning, and backups of the whole machine. None of it depends on Ghost.

**Contents**

- [1.1 SSH](#11-ssh)
- [1.2 Tailscale and the tailnet ACL](#12-tailscale-and-the-tailnet-acl)
- [1.3 fail2ban](#13-fail2ban)
- [1.4 Remove what you don't need](#14-remove-what-you-dont-need)
- [1.5 File-integrity monitoring with AIDE](#15-file-integrity-monitoring-with-aide)
- [1.6 Malware scanning with ClamAV](#16-malware-scanning-with-clamav)
- [1.7 Whole-machine backups](#17-whole-machine-backups)
- [1.8 Part 1 checks](#18-part-1-checks)
- [1.9 Gotchas](#19-gotchas)

> [!CAUTION]
> Several steps here change SSH and the firewall. Keep one SSH session open, open a second one to test, and only close the first once the second works.

---

## 1.1 SSH

Put every hardening setting in a single drop-in file. The main configuration includes `sshd_config.d` before its own settings, so the drop-in takes precedence, and the main file can stay as the distribution shipped it. That keeps upgrades from overwriting your changes.

`/etc/ssh/sshd_config.d/99-hardening.conf`:

```
Port <SSH_PORT>
AllowUsers <ADMIN_USER>
PermitRootLogin no
PasswordAuthentication no
KbdInteractiveAuthentication no
PubkeyAuthentication yes
X11Forwarding no
MaxAuthTries 3
LoginGraceTime 30
ClientAliveInterval 300
ClientAliveCountMax 2
```

Replace `<SSH_PORT>` with the port you've chosen and `<ADMIN_USER>` with your admin login. Choosing a non-default port cuts down on log noise from automated scanners. It isn't a security control on its own, so don't rely on it.

If you've already set any of these in `/etc/ssh/sshd_config` itself, move them into the drop-in, then remove them from the main file. Validate the configuration and reload:

```bash
sudo sshd -t && sudo systemctl reload ssh
sudo sshd -T | grep -Ei '^(port|allowusers|permitrootlogin|passwordauthentication|x11forwarding|maxauthtries|logingracetime) '
```

> [!CAUTION]
> If you change the port, update everything that refers to it in the same session: the fail2ban jail (`port = <SSH_PORT>`), the tailnet ACL tests, and any SSH client configuration. Open a **new** session on the new port with your key before you close the old one:
>
> ```bash
> ssh -i <path-to-your-key> -p "$SSH_PORT" "$ADMIN_USER@$TS_IP" 'echo ok'
> ```

---

## 1.2 Tailscale and the tailnet ACL

Tailscale is itself a hardening step: it takes the admin interface off the public internet and puts it behind your identity.

### Understand where the controls really are

> [!WARNING]
> On a Tailscale host, **UFW rules on `tailscale0` don't control tailnet traffic.** Tailscale's `ts-input` chain accepts everything arriving on `tailscale0` before UFW runs. Check with:
>
> ```bash
> sudo iptables -S | grep 'ts-input'
> ```
>
> If you see `-i tailscale0 -j ACCEPT`, the controls that matter are:
> 1. the **tailnet ACL** (admin console, grants), and
> 2. **bind addresses**: a service bound to `127.0.0.1` can't be reached from the tailnet at all.

### Default-deny the public interface

UFW should block everything inbound by default, which also covers the LAN:

```bash
sudo ufw default deny incoming
sudo ufw default allow outgoing
sudo ufw allow in on tailscale0            # only while you're setting up; narrow it below
sudo ufw enable
sudo ufw status verbose
```

Keep the allow rule for `tailscale0` until the ACL is in place, then narrow it. Remember that it does nothing for tailnet traffic on its own, as explained above.

### Narrow the ACL

In the Tailscale admin console, under Access Controls, replace any blanket "all ports" grant with specific ones. The shape of the policy:

```jsonc
{
  "grants": [
    // your own user: full access
    { "src": ["you@example.com"], "dst": ["*"], "ip": ["*"] },

    // peers that really need to talk: specific ports only
    { "src": ["<TAG_PI_PEERS>"], "dst": ["<TAG_PI_PEERS>"], "ip": ["tcp:9100", "tcp:5252"] }
  ],
  "tests": [
    // the save fails if these stop being true
    { "src": "you@example.com", "accept": ["<TS_IP>:<SSH_PORT>"] },
    { "src": "<TAG_PI_PEERS>", "deny": ["<TS_IP>:<SSH_PORT>"] }
  ]
}
```

Tests run every time you save, so a typo or a wrong assumption fails the save instead of silently changing access.

> [!NOTE]
> Tags can be case-sensitive. Use the same spelling in the policy and on the Machines page. Check the tags a machine has with `tailscale status --json`.

Tag peers that talk to each other, and grant only the ports they need. Peers that only receive a request from you shouldn't get a general allow rule.

---

## 1.3 fail2ban

fail2ban bans addresses after repeated failed logins. With key-only SSH it's a second layer, not the main control, but it's cheap.

```bash
sudo apt install -y fail2ban
```

`/etc/fail2ban/jail.local`:

```ini
[DEFAULT]
ignoreip = 127.0.0.1/8 ::1 <ADMIN_TS_IP>
bantime = 1h
findtime = 10m
maxretry = 5

[sshd]
enabled = true
port = <SSH_PORT>
backend = systemd
```

```bash
sudo systemctl enable --now fail2ban
sudo fail2ban-client status sshd
```

> [!NOTE]
> Add your own tailnet address to `ignoreip`. Otherwise a few failed logins from your own laptop could lock you out.

---

## 1.4 Remove what you don't need

Every running service and every group membership is something an attacker can use. Look at what's actually enabled:

```bash
systemctl list-unit-files --state=enabled --no-pager
id "$ADMIN_USER"
```

Candidates that are often unnecessary on a server, depending on your hardware and what you run:

- **Discovery and desktop-style services:** `avahi-daemon` (local name discovery), `ModemManager` (mobile modems), `wpa_supplicant` (Wi-Fi, if you're on ethernet), `apport` (crash reporting).
- **Storage and virtualisation extras:** `multipathd`, `open-vm-tools`, `vgauth`.
- **Snap, if you don't use snaps:** `snapd.socket` and `snapd.service`.

Disable with `--now` so the service stops as well as being prevented from starting at boot:

```bash
sudo systemctl disable --now <service-name>
```

For groups, the question is whether your account needs access to a class of device. Groups like `dialout`, `cdrom`, `audio`, `video`, `games`, `input`, `render`, `netdev`, and the hardware-interface groups `gpio`, `spi`, and `i2c` only matter if such devices are attached. Remove the ones you don't use, one at a time, and keep the ones your attached hardware needs:

```bash
sudo gpasswd -d "$ADMIN_USER" <group>
```

Removal takes effect at your next login. Check with `id "$ADMIN_USER"` after logging in again.

> [!TIP]
> Keep the groups that your hardware actually needs, such as `plugdev` for removable USB storage, and `docker` if you run containers.

---

## 1.5 File-integrity monitoring with AIDE

AIDE records a baseline of the files that matter, then reports every change against it. It catches a modified binary, a planted key, or an edited config, which a firewall won't. It complements access controls; it doesn't replace them.

> [!IMPORTANT]
> A baseline is only as trustworthy as the state it was taken in. Take it after you've verified the machine is clean.

### 1.5.1 Install and check the layout

```bash
sudo apt install -y aide
ls -l /etc/aide/
sudo aide --config /etc/aide/aide.conf --config-check; echo "exit=$?"
```

On Ubuntu 24.04, the main configuration is `/etc/aide/aide.conf`, and the package's rules live in `/etc/aide/aide.conf.d/`. Put your own rules in a new drop-in file. Don't edit `aide.conf` itself, so upgrades don't overwrite your changes.

`--config-check` is silent when the configuration is valid. Check the exit code, not the output.

### 1.5.2 Exclude what changes on purpose

The package's catch-all rule (`99_aide_root`) watches the whole disk. Without exclusions, every check reports databases, caches, logs, and developer tooling, and the reports become noise you stop reading.

Create `/etc/aide/aide.conf.d/98_hardening_excludes`. It loads before the catch-all, and each rule has the form `!/path(/.*)?$`, which excludes the folder and everything inside it:

```
# Volatile runtime state
!/run(/.*)?$
!/tmp(/.*)?$
!/dev(/.*)?$
!/var/spool(/.*)?$
!/var/cache(/.*)?$
!/var/log(/.*)?$

# Databases and service data: these change constantly
!<DATABASE_DATA_DIR>(/.*)?$
!<CONTAINER_DATA_DIR>(/.*)?$
!<MONITORING_DATA_DIR>(/.*)?$

# Package-manager state that changes with every update
!/var/lib/apt/lists(/.*)?$

# Package-owned trees, checked with dpkg -V instead (see 1.5.5)
!/usr/share(/.*)?$
!/usr/include(/.*)?$
!/usr/lib(/.*)?$
!/boot/firmware(/.*)?$

# Home directory: caches, workspaces, and shell history
!/home/<ADMIN_USER>/\.(cache|npm)(/.*)?$
!/home/<ADMIN_USER>/<WORKSPACE_DIR>(/.*)?$
!/home/<ADMIN_USER>/\.bash_history$
```

AIDE doesn't read shell variables, so replace each placeholder with its real value before saving.

- `<DATABASE_DATA_DIR>`, `<CONTAINER_DATA_DIR>`, `<MONITORING_DATA_DIR>`: the directories where databases, container volumes, and time-series data live. Typical examples are the MySQL or PostgreSQL data directory, `/var/lib/docker`, and the Prometheus and Grafana data directories.
- `<WORKSPACE_DIR>`: any folder under your home directory where you work on code that changes daily.

### 1.5.3 Keep the watched set honest

**Don't exclude your whole home directory.** Login scripts, SSH keys, and user service units all live there, and they're exactly what an attacker would change. Watch these, and exclude only the churn:

- `~/.ssh` (authorised keys)
- `~/.bashrc` and `~/.profile` (run at every login)
- `~/.config` (user services and autostart entries)
- `~/.local/bin` (executables you'd notice being replaced)

Decide which developer tools and their data directories to exclude. Tools that update themselves, or that store settings which run commands automatically, should stay watched. Check what a tool keeps before you exclude it.

Watch the **settings and hook files** of any tool that can run commands on your behalf, even if you exclude the rest of its data directory.

> [!NOTE]
> A rule like `!/path/.*` excludes what's inside a folder, but not the folder entry itself. The folder's timestamp changes whenever its contents do, so the folder still appears as changed. The `(/.*)?$` form excludes both. Use it everywhere.

### 1.5.4 Build the baseline

```bash
sudo aide --config /etc/aide/aide.conf --init 2>&1 | grep -E 'WARNING|Number of entries|written to|End timestamp'
```

This takes around 15 minutes on a USB-attached SSD. Leave it running.

Any `WARNING` line means a file was changing during the scan. Exclude that path, then rebuild.

Activate the new database. AIDE writes it compressed when `gzip_dbout=yes`, and its report hashes are of the **uncompressed** contents, so a plain `sha256sum` of the file won't match the report. Read the file name from the `written to` line, then:

```bash
sudo mv /var/lib/aide/aide.db.new /var/lib/aide/aide.db      # use the name from your output
```

### 1.5.5 Prove it works

Create one file in a watched path and one in an excluded path, check, then remove both:

```bash
sudo touch /etc/aide-test-watched
sudo touch <EXCLUDED_PATH>/aide-test-excluded
sudo aide --config /etc/aide/aide.conf --check 2>&1 | grep -E 'aide-test|Total number|found differences|No differences'
sudo rm -f /etc/aide-test-watched <EXCLUDED_PATH>/aide-test-excluded
```

Expected: the watched file is reported, and the excluded one isn't. If that's reversed, the exclusions are in the wrong order.

### 1.5.6 Keep a copy off the box

An attacker with root could rewrite the database on the machine and hide their changes. Keep a copy somewhere else. The file is root-owned, so copy it to your home directory first:

```bash
sudo install -m 600 -o "$ADMIN_USER" -g "$ADMIN_USER" /var/lib/aide/aide.db ~/aide-baseline.db
```

From your other machine:

```bash
scp -P "$SSH_PORT" "$ADMIN_USER@$TS_IP:aide-baseline.db" ~/aide-baseline/
```

Remove the copy on the machine (`rm ~/aide-baseline.db`) and compare the two files with plain `sha256sum`. Those hashes should match. Re-check the box's copy against your off-box copy before every review.

### 1.5.7 Check every day, after upgrades run

Ubuntu's `aide-common` package enables its own nightly check, `dailyaidecheck.timer`. It runs `aide --update` and writes the result to `aide.db.new`, so whatever changed overnight is written into the file you'd later promote. Turn it off, so the only check is yours:

```bash
sudo systemctl disable --now dailyaidecheck.timer
```

Schedule your own. Run it after the apt upgrade window, so each report covers one night's changes and the check doesn't run during an upgrade. Check the window on your own system first:

```bash
systemctl list-timers 'apt-daily*' --no-pager
```

Ubuntu's upgrade timers add a random delay, so the window can move around. Pick a time that's safely after it.

`/usr/local/sbin/aide-daily-check` (then `chmod 755`):

```bash
#!/bin/sh
# Daily AIDE check. Writes a dated report and returns AIDE's exit code.
set -u
LOGDIR=/var/log/aide
mkdir -p "$LOGDIR" && chmod 750 "$LOGDIR"
LOG="$LOGDIR/check-$(date +%F).log"
/usr/bin/aide --config /etc/aide/aide.conf --check >"$LOG" 2>&1
RC=$?
echo "exit=$RC" >> "$LOG"
exit $RC
```

`/etc/systemd/system/aide-check.service`:

```ini
[Unit]
Description=AIDE integrity check

[Service]
Type=oneshot
ExecStart=/usr/local/sbin/aide-daily-check
Nice=10
IOSchedulingClass=idle
```

`/etc/systemd/system/aide-check.timer`, with `<HH:MM>` replaced by a time that suits your window, in UTC:

```ini
[Unit]
Description=Run AIDE check daily, after the apt upgrade window

[Timer]
OnCalendar=*-*-* <HH:MM>:00
Persistent=true

[Install]
WantedBy=timers.target
```

```bash
sudo systemctl daemon-reload
sudo systemctl enable --now aide-check.timer
systemctl list-timers aide-check.timer --no-pager
```

A run that finds changes exits non-zero, so it shows as failed in `systemctl --failed`. That's the signal to read the day's report. A clean run shows nothing.

### 1.5.8 Review, then re-baseline

Changes are expected after package upgrades and key rotations. The rule is: **review before you re-baseline.** If you re-baseline first, an unauthorised change becomes the new normal.

Before you start, check the database on the machine against your off-box copy, with plain `sha256sum` on both ends. If they differ, something has changed the database. Stop and investigate.

1. Read the day's report: `less /var/log/aide/check-<DATE>.log`
2. Match each change to a known action: an upgrade, a key rotation, or a deliberate config change. `sudo dpkg -V` cross-checks package-owned files.
3. Anything unexplained is an incident. Investigate before going on.
4. Once everything is explained, run the update with the full output saved to a file. Don't pipe it through `grep`, since that throws away the change list you're about to review:

```bash
sudo sh -c 'aide --config /etc/aide/aide.conf --update > /var/log/aide/update-$(date +%F).log 2>&1'; echo "exit=$?"
```

5. Review the full log, then activate the new database and copy it off the machine again as in 1.5.6:

```bash
sudo mv /var/lib/aide/aide.db.new /var/lib/aide/aide.db
```

Exit code `7` means entries were added, removed, and changed. That's normal after an upgrade, and it still needs the review.

### 1.5.9 Verify package files with `dpkg -V`

`dpkg -V` compares installed package files with the checksums recorded when they were installed, so it's the right cross-check for the package trees we excluded from AIDE. Run it with `sudo`. Without it, files you can't read show as `?????????` or `missing`, which looks like damage but isn't.

```bash
sudo dpkg -V
```

Lines beginning with `c` are configuration files, which you're expected to edit. Anything else needs a look.

---

## 1.6 Malware scanning with ClamAV

ClamAV finds known malicious content, by signature, in the places a bad file would land: uploads, downloads, your home directory, and the temporary folders. It won't catch a skilled attacker, but it's a cheap scheduled tripwire.

> [!NOTE]
> ClamAV says nothing about tampering with your own files. That's AIDE's job.

### 1.6.1 Install and keep the definitions current

```bash
sudo apt install -y clamav clamav-freshclam
sudo systemctl enable --now clamav-freshclam
journalctl -u clamav-freshclam --no-pager -n 20
```

`clamav-freshclam` is installed but not enabled by default, so enabling it is what keeps the definitions updated. The log should end with the databases being up to date.

> [!TIP]
> The first update can fail with an `unlink failure` while it clears a temporary folder. Restart the service (`sudo systemctl restart clamav-freshclam`) and check the log again. The retry normally succeeds.

### 1.6.2 Turn off the daemon

The package also installs `clamav-daemon`, which keeps the definitions in memory for on-access scanning. A scheduled scan runs `clamscan` directly and doesn't need the daemon, so turning it off leaves one fewer listening service:

```bash
sudo systemctl disable --now clamav-daemon.service
sudo systemctl disable --now clamav-daemon.socket 2>/dev/null || true
```

### 1.6.3 The scan script

`/usr/local/sbin/clamav-weekly-scan` (then `chmod 755`):

```bash
#!/bin/sh
# Scheduled ClamAV scan of the places a malicious file is most likely to land.
# clamscan exits 0 (clean), 1 (infected), or 2 (error). A non-zero exit shows
# the unit as failed in systemctl --failed, which is the signal to read the report.
set -u
LOGDIR=/var/log/clamav-scan
mkdir -p "$LOGDIR" && chmod 750 "$LOGDIR"
LOG="$LOGDIR/scan-$(date +%F).log"
nice -n 10 ionice -c3 clamscan --recursive --infected --log="$LOG" \
  --exclude-dir='\.pnpm|node_modules' \
  <SCAN_DIR_1> <SCAN_DIR_2> /tmp /var/tmp /dev/shm
RC=$?
echo "exit=$RC" >> "$LOG"
exit $RC
```

Replace `<SCAN_DIR_1>` and `<SCAN_DIR_2>` with the places where files arrive: an uploads folder, a downloads folder, or your home directory. Add or remove paths to suit your system.

### 1.6.4 The service and the timer

`/etc/systemd/system/clamav-weekly-scan.service`:

```ini
[Unit]
Description=Scheduled ClamAV scan

[Service]
Type=oneshot
ExecStart=/usr/local/sbin/clamav-weekly-scan
Nice=10
IOSchedulingClass=idle
```

`/etc/systemd/system/clamav-weekly-scan.timer`, with `<DAY>` and `<HH:MM>` set to a quiet period, in UTC:

```ini
[Unit]
Description=Run the ClamAV scan weekly, at a quiet time

[Timer]
OnCalendar=<DAY> *-*-* <HH:MM>:00
Persistent=true

[Install]
WantedBy=timers.target
```

Pick a time away from the apt upgrade window and from the AIDE check. `Persistent=true` runs a missed scan at the next boot.

```bash
sudo systemctl daemon-reload
sudo systemctl enable --now clamav-weekly-scan.timer
systemctl list-timers clamav-weekly-scan.timer --no-pager
```

### 1.6.5 Prove detection works

Use the standard EICAR test string, which every scanner flags. It's harmless, and the file is removed straight after:

```bash
echo 'X5O!P%@AP[4\PZX54(P^)7CC)7}$EICAR-STANDARD-ANTIVIRUS-TEST-FILE!$H+H*' > /tmp/eicar-test.txt
sudo clamscan --infected /tmp/eicar-test.txt; echo "exit=$?"
rm -f /tmp/eicar-test.txt
```

Expect `Eicar-Signature FOUND` and `exit=1`. Anything else means the scanner isn't detecting, so don't rely on the timer until this passes.

### 1.6.6 The first full run

Run the scan once by hand, to see how long it takes and that it's clean:

```bash
time sudo systemctl start clamav-weekly-scan.service
sudo tail -n 15 /var/log/clamav-scan/scan-$(date +%F).log
systemctl is-failed clamav-weekly-scan.service
```

A clean run ends with `exit=0` and `inactive`. If something is found, the unit shows as failed and the log names the file. Don't delete it straight away. Work out where it came from first: an upload, a download, or something that appeared in AIDE's report. Then decide.

The script, service, and timer are themselves in AIDE's scope, so they'll appear in the first report after they're added. The definitions and the scan logs are excluded.

---

## 1.7 Whole-machine backups

Two things make a backup: the copy, and the proof that you can restore from it. Part 2 covers backups of the Ghost site. This section covers the whole machine.

**Take a whole-machine image after every major change** to the system: an OS release upgrade, a new disk, or a significant change to the hardening. A block-level copy of the boot drive is the simplest kind. It includes the operating system, the secrets, the configuration, the databases, and the monitoring data.

- **Stop the services first.** Copying a disk while MySQL and Ghost are running can capture a half-written database. Shut the machine down, or stop the services that write data, before you image it.
- **Image the whole device,** not one partition, so the partition table comes with it.
- **Encrypt the image** before it leaves your control. It holds secrets. Keep the key separate from the image.
- **Store a checksum** alongside the image, and verify it before you rely on the image.
- **Restore once, to a spare drive.** Boot the restored drive and check it. An untested image is a guess.

> [!NOTE]
> Two identical drives carry the same filesystem and partition UUIDs. Keep only one of them connected when you boot, so the system doesn't mount the wrong one.

After booting from a restored image, the AIDE check against your baseline is a good test. A clean result, apart from boot-time files, means the image matches what you verified.

---

## 1.8 Part 1 checks

| Check | Expected |
|-------|----------|
| Remote login | Key-only; root login off; only `$ADMIN_USER` allowed |
| Firewall | Default deny inbound; LAN closed; tailnet ACL narrowed to the ports you need |
| fail2ban | `sshd` jail active, your tailnet address in `ignoreip` |
| Services | Only the services you need are enabled |
| AIDE | Baseline present; daily check on a timer after the upgrade window; off-box copy matches |
| ClamAV | `clamav-freshclam` active; definitions current; weekly timer scheduled; EICAR test gives `FOUND` |
| Backups | Whole-machine image taken; restore tested |

---

## 1.9 Gotchas

### sudo through a non-terminal shell

> `sudo: a terminal is required to read the password`

Run privileged commands in a real terminal. Automated shells can't answer a password prompt.

### UFW doesn't control tailnet traffic

UFW rules on `tailscale0` appear to work, but they don't. Tailscale's `ts-input` accepts that traffic first. Use the ACL and the bind addresses instead ([1.2](#12-tailscale-and-the-tailnet-acl)).

### `scp` can't read root-owned files

> `scp: /var/lib/aide/aide.db: Permission denied`

Copy the file to your home directory with `sudo install -o "$ADMIN_USER"`, then scp it from there.

### Package upgrades look like tampering

Every `apt` run changes files under `/usr` and `/etc`, so AIDE reports them. Review each change against `dpkg -V` before you re-baseline ([1.5.9](#159-verify-package-files-with-dpkg--v)).

### The first baseline reports files that are still changing

Log files and systemd timer stamps change during the scan. Each one shows as `WARNING: hash calculation … has been changed`. Exclude the path, then rebuild.

### `--config-check` is silent on success

Check the exit code (`echo $?`), not the output.

### The mail prompt in `aide-common` installs Postfix

Choosing "local only" in the mail prompt pulls in `bsd-mailx` and `postfix`. Postfix then listens on localhost port 25, and most setups don't need it. Purge it after installing AIDE with `sudo apt purge postfix`.

### Ubuntu runs its own nightly AIDE update

`aide-common` enables `dailyaidecheck.timer`. It runs `aide --update` every night and rewrites `aide.db.new`. Disable it, as in [1.5.7](#157-check-every-day-after-upgrades-run).

### `!/path/.*` leaves the folder entry visible

See the note in [1.5.3](#153-keep-the-watched-set-honest). Use `!/path(/.*)?$` to exclude the folder and its contents together.

### `dpkg -V` without `sudo` reports the wrong things

Without `sudo`, `dpkg -V` can't read root-owned files, and reports them as `?????????` or `missing ... (Permission denied)`. Always run it with `sudo`.

### Identical drives share UUIDs

See the note in [1.7](#17-whole-machine-backups).
