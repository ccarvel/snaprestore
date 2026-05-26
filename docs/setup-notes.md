# Setup Notes — Operator Observations

Field notes from working through `docs/setup.md`. Captures gotchas,
clarifications, and post-restore steps not fully covered in the main doc.

---

## SSH access after restore

### Root login

Root login works out of the box if the SSH key selected during the restore
wizard was already authorised on the source droplet. The key is injected via
the DigitalOcean API at creation time.

### Non-root users (e.g. `static`)

Non-root users that existed on the source snapshot do **not** automatically
get the injected key. After restoring, pubkey auth for those users will be
rejected unless you manually update their SSH configuration.

Options (pick one):

1. **Copy the root authorized_keys to the user's home directory:**
   ```bash
   cp /root/.ssh/authorized_keys /home/static/.ssh/authorized_keys
   chown static:static /home/static/.ssh/authorized_keys
   chmod 600 /home/static/.ssh/authorized_keys
   ```

2. **Add your public key directly:**
   ```bash
   echo "ssh-ed25519 AAAA... you@host" >> /home/static/.ssh/authorized_keys
   ```

3. **Check `/etc/ssh/sshd_config`** for `AuthorizedKeysFile` overrides or
   `PasswordAuthentication` settings that may affect which key files are
   consulted.

Log in as root first, make the change, then test the non-root login.

---

## Controller droplet provisioning

### Non-ASCII characters in `controller.yml` break cloud-init silently

The `controller.yml` cloud-config must contain only plain ASCII characters. Em dashes (`—`) and box-drawing characters (`─`) in YAML comments cause cloud-init to log `unacceptable character #x0080` and skip the entire config — no users are created, no packages installed, no services configured. `cloud-init status` still reports `done`.

Check for non-ASCII before creating the droplet:

```bash
LC_ALL=C grep -n '[^ -~]' slack-bot/cloud-init/controller.yml
```

No output means the file is clean.

### Use `doctl --user-data-file` instead of the DO console

Pasting `controller.yml` into the DigitalOcean console UI can introduce invisible non-ASCII characters (the browser or OS clipboard encoding can corrupt long base64 strings or Unicode characters in comments). Always pass the file directly:

```bash
doctl compute droplet create do-snap-bot-controller \
  --image ubuntu-22-04-x64 \
  --size s-1vcpu-1gb \
  --region nyc1 \
  --ssh-keys <key-id> \
  --user-data-file slack-bot/cloud-init/controller.yml \
  --wait
```

Get your key ID with `doctl compute ssh-key list`.

### Verify cloud-init before expecting `dosnap` to exist

```bash
ssh -i ~/.ssh/id_m3do root@<controller-ip> "cloud-init status"
# Must print: status: done
ssh -i ~/.ssh/id_m3do dosnap@<controller-ip>
# If this fails, dosnap was not created — check the log above
```

### `/opt/do-snap-bot` permission denied on rsync

If cloud-init ran but the directory wasn't created or chowned, fix it as root before rsync:

```bash
ssh -i ~/.ssh/id_m3do root@<controller-ip> "mkdir -p /opt/do-snap-bot && chown dosnap:dosnap /opt/do-snap-bot"
```

### Destroying and recreating a failed droplet

```bash
doctl compute droplet delete do-snap-bot-controller
# Then recreate with the corrected controller.yml
```

---

## Running the scripts with `op run`

**Do not use `op run --env-file=.env` to invoke `do-restore.sh` or
`do-snapshot.sh` directly.** When `op run` injects `DIGITALOCEAN_ACCESS_TOKEN`
from `.env` into the environment, doctl ignores `--context snaprestore` and
uses that injected token instead of the context's stored credential. If the
`.env` token belongs to a different API key (e.g. the Slack bot token), the
wizard reads will succeed but droplet create/snapshot calls will fail silently.

The scripts authenticate via the named doctl context (`snaprestore`). Run them
without `op run`:

```bash
./do-restore.sh --log restore.log
./do-snapshot.sh --log snapshot.log
```

`op run` is correct for the Slack bot and any service that reads
`DIGITALOCEAN_ACCESS_TOKEN` directly from the environment.
