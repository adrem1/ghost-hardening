# Part 2: Ghost

This part hardens the Ghost blog itself: its database credentials, where its secrets live, the web edge that reaches it, the admin login, mail, and its backups. It assumes Part 1 is in place.

**Contents**

- [2.1 Rotate the database password](#21-rotate-the-database-password)
- [2.2 Keep secrets out of the config file](#22-keep-secrets-out-of-the-config-file)
- [2.3 The web edge](#23-the-web-edge)
- [2.4 Cloudflare Access on the admin path](#24-cloudflare-access-on-the-admin-path)
- [2.5 Mail for Ghost](#25-mail-for-ghost)
- [2.6 Staff device verification](#26-staff-device-verification)
- [2.7 Login protection](#27-login-protection)
- [2.8 Ghost-specific AIDE exclusions](#28-ghost-specific-aide-exclusions)
- [2.9 Ghost backups](#29-ghost-backups)
- [2.10 Part 2 checks](#210-part-2-checks)
- [2.11 Gotchas](#211-gotchas)

---

## 2.1 Rotate the database password

Rotate the password Ghost uses to reach its database. A rotation means any old copy of the password, wherever it was once readable, is no longer useful.

Generate a new password. Run the `ALTER USER` through the administrative maintenance account that your distribution provides, which avoids needing the MySQL root password. On Ubuntu that's the `debian.cnf` file, readable only by root:

```bash
export NEWPW=$(openssl rand -hex 24)
sudo mysql --defaults-file=/etc/mysql/debian.cnf -e \
  "ALTER USER '$GHOST_DB_USER'@'$GHOST_DB_HOST' IDENTIFIED BY '$NEWPW'; FLUSH PRIVILEGES;"
```

Then update the password Ghost reads. Section 2.2 moves it into a secret file, so you can do it in this step or the next. Either way, the database login is the test:

```bash
export CFG="$GHOST_DIR/config.production.json"
MYSQL_PWD="<the new password>" mysql -h"$GHOST_DB_HOST" -u"$GHOST_DB_USER" "$GHOST_DB_NAME" -e "SELECT 'OK' AS db_login;"
```

> [!TIP]
> Edit the config **in place**, by writing back to the same file. Writing a temporary file and renaming it creates a new file with default permissions, and Ghost may then be unable to read it. Gotcha 8 in [2.11](#211-gotchas) covers this.

---

## 2.2 Keep secrets out of the config file

Ghost's configuration file holds the database password and, if you send mail over SMTP, the SMTP password. Anything that can read the file can read those secrets. Better is to keep each secret in its own root-only file, and let systemd hand it to Ghost at start-up.

### Store each secret in a root-only file

Choose a root-owned directory for the secrets, then write each secret into a file in it. Don't print the secrets to your terminal.

```bash
sudo install -d -m 700 -o root -g root "$SECRETS_DIR"
python3 -c "import json,os; d=json.load(open(os.environ['CFG'])); print(d['database']['connection']['password'], end='')" \
  | sudo tee "$SECRETS_DIR/db_password" >/dev/null
sudo chmod 600 "$SECRETS_DIR/db_password"
```

Repeat for any SMTP password, reading it from `mail.options.auth.pass` in the same way. Check the key names in your config before you write anything, without printing the values:

```bash
python3 -c "import json,os; d=json.load(open(os.environ['CFG'])); print(list(d['database']['connection'])); print(list(d.get('mail',{}).get('options',{}).get('auth',{})))"
```

### Load them with a systemd drop-in

Create a drop-in for the Ghost unit that loads each secret as a credential. systemd reads the files as root before it drops privileges, so Ghost never needs read access to the secrets directory.

`/etc/systemd/system/<GHOST_UNIT>.service.d/secrets.conf`:

```ini
[Service]
LoadCredential=db_password:<SECRETS_DIR>/db_password
Environment=database__connection__password_FILE=%d/db_password
```

Add `LoadCredential=smtp_password:...` and `Environment=mail__options__auth__pass_FILE=%d/smtp_password` for SMTP. `%d` expands to systemd's private credentials directory.

Ghost reads any environment variable ending in `_FILE` as "the value is in the file this names", and layers those values above the config file. So the migration can go in this order, with the Ghost database login as the test at each step:

1. Write the secret files, as above.
2. Add the drop-in, then `sudo systemctl daemon-reload` and restart Ghost. The passwords are still in the config, so Ghost works either way.
3. Remove the passwords from the config file, restart again, and confirm Ghost still connects. If it does, it's reading the secret files.
4. Make a backup of the config before you start, and keep it until the database login and a test email are both confirmed.

> [!NOTE]
> Setting both the plain variable and the `_FILE` variable is an error, and Ghost won't start. Set only the `_FILE` form.

Once the secrets are out of the config, the file holds no secrets, so its mode can be `644`. That's what `ghost doctor` expects ([2.11](#211-gotchas)).

---

## 2.3 The web edge

Ghost should be reachable only through the Cloudflare Tunnel. The tunnel makes an outbound connection, so the box needs no inbound web port.

Check the tunnel's public hostname: in the Cloudflare Zero Trust dashboard, under Networks → Tunnels, the service for `$PUBLIC_DOMAIN` should be `http://localhost:$GHOST_PORT`.

If nothing else on the box serves web traffic, remove the default web server, rather than leaving its default page on the network. Uninstall it if you don't use it, or disable its site if you do:

```bash
sudo rm /etc/nginx/sites-enabled/default      # disable the default site
sudo apt purge nginx nginx-common              # or uninstall, if nothing else uses it
```

Confirm the public site still responds:

```bash
curl -sI "https://$PUBLIC_DOMAIN/" | head -1
```

---

## 2.4 Cloudflare Access on the admin path

Cloudflare Access puts a login in front of a path before the request reaches the server, so the Ghost admin is unreachable to anyone who isn't on your list. Everything in this section happens in the Cloudflare dashboard, and menu names change between versions.

1. **Add a login method.** Under Zero Trust, find the identity providers section and add **One-time PIN**. Until this is set up, the option never appears in an Access policy.
2. **Create the application.** Under Access → Applications, add a self-hosted application. Set the domain to `$PUBLIC_DOMAIN` and the path to `ghost`. Add `ghost/*` too, so the admin pages and their assets are covered, not only the entry page.
3. **Write the policy.** Allow access to your own email address only, with One-time PIN as the login method.

Test it without a browser cookie, since your browser's Access session would hide a gap:

```bash
curl -s -o /dev/null -w "%{http_code} %{redirect_url}\n" "https://$PUBLIC_DOMAIN/ghost/"
curl -s -o /dev/null -w "%{http_code} %{redirect_url}\n" "https://$PUBLIC_DOMAIN/ghost/api/admin/site/"
```

Both should return `302` to a Cloudflare Access login URL. A `404` or a Ghost JSON error on the second line means the wildcard path is missing.

> [!WARNING]
> Access also blocks any integration that calls `/ghost/api/` without a browser login. Before you add one, check whether it needs the Admin API. If it does, give that path its own bypass rule, and keep the admin pages behind Access.

### A temporary bypass for Ghost backups

Ghost's backup uses the Admin API, which the Access login blocks. Allow it through a temporary bypass, scoped to the one address the backup runs from, and remove the bypass as soon as the backup is done.

The bypass is a policy on the existing `/ghost/*` application, placed above the email policy so it's evaluated first:

1. Find the IPv6 address the backup runs from. It must be fixed: a `/128` only matches while the address stays the same, so check it before you start.
2. Add a policy to the `ghost` application with the action **Bypass**, and an include rule of **IP ranges** set to that address with `/128`.
3. Move the policy to the top, above the email policy.
4. Run the backup (see [2.9](#29-ghost-backups)).
5. Delete the policy as soon as the backup has finished, then confirm `/ghost/` returns `302` again, as in the test above.

Only that one address skips the login while the policy exists. Every other visitor still goes through Access. Keep the window short, and don't leave the policy in place between backups.

---

## 2.5 Mail for Ghost

Ghost sends email for password resets, staff sign-in codes, and member messages. Its `Direct` transport delivers mail straight to the recipient's server. From a self-hosted box, that usually fails, because home and small-hosting connections are often blocked from doing it, and mail servers reject unauthenticated mail from unknown addresses. Use SMTP through a transactional provider instead.

1. Create an account with a transactional mail provider, and verify a sending domain. Publish the SPF and DKIM records the provider gives you, in your DNS.
2. Take the SMTP host, port, username, and password from the provider. Store the password as a secret file, as in [2.2](#22-keep-secrets-out-of-the-config-file).
3. Complete the provider's setup in the Ghost admin. Ghost stores the provider's API key once and then hides it.
4. Test with **Forgot password** on the sign-in page. The email should arrive within a few minutes. Check the spam folder too.

> [!TIP]
> If mail credentials leak, rotate them at the provider. Rotation usually takes seconds, and it doesn't affect the rest of Ghost's settings.

---

## 2.6 Staff device verification

This setting emails a code whenever someone signs in from a new device. It's a useful control, and a real trap if mail isn't working.

> [!CAUTION]
> Enable this only after the mail test in [2.5](#25-mail-for-ghost) passes. Without working mail, you can't sign in from a new browser.

Set the flag in the config file, editing the file in place so its mode and owner don't change:

```bash
python3 -c "import json,os; p=os.environ['CFG']; d=json.load(open(p)); d.setdefault('security',{})['staffDeviceVerification']=True; open(p,'w').write(json.dumps(d, indent=2))"
stat -c '%U:%G %a %n' "$CFG"
cd "$GHOST_DIR" && ghost restart
```

Test from a private browser window. Sign in, and check that the code email arrives.

---

## 2.7 Login protection

Ghost limits sign-in attempts itself. After repeated failed attempts, it blocks further attempts for a period, which is ten minutes on the setup this guide was tested on. That's the main protection, and it doesn't depend on your hosting plan.

The Access policy in [2.4](#24-cloudflare-access-on-the-admin-path) keeps strangers off the login page entirely, so Ghost's lockout is only reached by people already past Access.

An extra Cloudflare rate-limit rule is an optional second layer. On a free plan, the options are limited. A typical rule looks like this:

| Field | Value |
|-------|-------|
| Expression | `(http.request.uri.path contains "/ghost/api/admin/session" and http.request.method eq "POST")` |
| Characteristic | IP |
| Period | the shortest your plan offers |
| Requests | a small number within that period |
| Action | Block, for the shortest duration your plan offers |

Two things to check before you rely on it:

- **The path is the request path, not the page URL.** The browser shows `/ghost/#/signin`, but the part after `#` never reaches the server. The login request goes to `/ghost/api/admin/session/`, with a trailing slash, which `contains` matches. Confirm it in your browser's developer tools (Network tab) during a sign-in.
- **A failed attempt counts too.** A wrong password returns an error code, but it still counts toward the limit.

> [!WARNING]
> A block applies to your own IP, so you can lock yourself out by mistyping repeatedly. Test with a deliberately wrong password, from a device you can afford to lose access on, and keep Ghost's lockout as the fallback.

---

## 2.8 Ghost-specific AIDE exclusions

The AIDE setup in [Part 1](./01-host-hardening.md#15-file-integrity-monitoring-with-aide) watches the whole disk, and excludes the places that change constantly. Ghost adds its own. Put these in a second file, `/etc/aide/aide.conf.d/97_ghost_excludes`, so it loads before the catch-all rule, and before the general excludes from Part 1.

The key idea is to exclude only **data**, and keep **code and configuration** watched:

```
# Ghost data folders: uploads and logs change with use
!<GHOST_DIR>/content/(data|images|media|files|logs)(/.*)?$

# Ghost's package store: changes with every install
!<GHOST_DIR>/\.pnpm-store(/.*)?$
```

Keep these **watched**, since they're code or configuration Ghost runs:

- `<GHOST_DIR>/content/themes`: the theme code
- `<GHOST_DIR>/content/apps`: any custom integrations
- `<GHOST_DIR>/content/settings`: configuration
- `<GHOST_DIR>/content/public`: static assets that Ghost serves, and any login page assets it generates
- `<GHOST_DIR>/config.production.json`: the configuration itself
- `<GHOST_DIR>/versions`: the installed Ghost release

> [!NOTE]
> A Ghost upgrade, a theme edit, or a restart that regenerates a served page will show up as changes in these watched folders. Each of those is expected after the change you made, and you should still review it.

Replace `<GHOST_DIR>` with the directory where Ghost is installed.

---

## 2.9 Ghost backups

Back up the Ghost site before each Ghost update, using Ghost's own backup command, and keep the backup somewhere other than the server. A Ghost backup contains the content and the database, so it restores the site without rebuilding the machine.

> [!CAUTION]
> A Ghost backup contains member and subscriber details. Encrypt it before it leaves the server, and keep the encrypted copy off the server. Don't upload it to a shared or public location.

The backup needs the Admin API, so it runs through the temporary IP-scoped bypass described in [2.4](#24-cloudflare-access-on-the-admin-path). Add the bypass before the backup, and delete it straight after.

Restore the backup once to a scratch database and confirm the site comes back. An untested backup is a guess, and this is the test that proves the backup is worth keeping.

The whole-machine image, which covers the operating system and everything else, is in [Part 1, section 1.7](./01-host-hardening.md#17-whole-machine-backups).

---

## 2.10 Part 2 checks

| Check | Expected |
|-------|----------|
| Database password | Rotated; stored only in a root-only file |
| Config file | No secrets; mode `644`; `ghost doctor` passes |
| Secret files | Root-owned, mode `600`, in the secrets directory |
| Web edge | Tunnel points at `http://localhost:$GHOST_PORT`; no default web server answering |
| Access | `/ghost` and `/ghost/*` return `302` to Access without a cookie |
| Mail | Forgot-password email arrives |
| Staff device verification | Sign-in from a new browser sends a code |
| Login protection | Ghost's lockout works; any Cloudflare rule is in place as you intended |
| Backups | Ghost backup taken before the last update; a restore has been tested once |

---

## 2.11 Gotchas

### `ghost doctor` accepts only `644` or `664`

> `Your installation folder contains a directory or file with incorrect permissions: ./config.production.json`

The check is strict. `640` fails it, and `644` is safe only once the file holds no secrets. Move the secrets out ([2.2](#22-keep-secrets-out-of-the-config-file)), and the mode can then be `644`.

### `ghost update` prompts for input

> `Prompts have been disabled, all options must be provided via command line flags`

Run `ghost update` in an interactive terminal. If you need a temporary `chmod` to let the update read the config, keep that window short, and restore the mode straight after, whether the update succeeded or not.

### Write the config in place

Writing a temporary file and renaming it creates a new file with default permissions. Your mode and group are lost, and Ghost may no longer be able to read its config. Write back into the same file.

### Access needs a login method first

The One-time PIN method must be added under Zero Trust's identity providers before it appears in an Access policy. An empty dropdown means it isn't set up yet.

### `Direct` mail doesn't deliver from home

Ghost's `Direct` transport failed from a self-hosted box, with an `AggregateError` on password reset. SMTP through a transactional provider fixed it. See [2.5](#25-mail-for-ghost).

### Test Access without cookies

Your browser's Access session makes a gap look closed. Test with `curl` and no cookies, as in [2.4](#24-cloudflare-access-on-the-admin-path).

### An empty log search can be a broken filter

Before you trust a search of Ghost's logs, check that the filter returns something known, for example `grep -c 'admin/session'`. A zero count from a broken pattern looks the same as a clean log.
