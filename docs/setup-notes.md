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

## 1Password service accounts

### Draft email to IT for org-managed 1Password accounts

If you need IT to configure the service account access, use this draft:

---

**Subject:** 1Password service account — vault access needed

Hi [Name],

I'm working on an internal tool that uses a 1Password service account to
inject secrets into a server process at runtime (no secrets are stored on
disk or in code). I need your help with two things in our Brown University
1Password account:

1. **Create a new vault** named `snaprestore` (or confirm I can use an
   existing one like `CDS_Vault`).

2. **Create a service account** named `do-snap-bot-controller` and grant it
   **read-only** access to that vault. Generate the `ops_…` service account
   token and share it with me securely (1Password or similar).

The secrets I'll store in the vault are: Slack bot tokens, a Slack signing
secret, and a DigitalOcean API token — all for an internal snapshot/restore
automation tool running on a DigitalOcean droplet.

Let me know if you need any additional context or if there's a self-service
process I missed.

Thanks,
[Your name]

---

### Service account must be created in an account you fully control

The controller droplet authenticates to 1Password using a service account token (`OP_SERVICE_ACCOUNT_TOKEN`). Service accounts must be created and vault access must be granted by the account owner.

**If your 1Password account is managed by an organization (e.g. a university IT department), you may not be able to create service accounts or assign vault access yourself.** In that case, use a personal 1Password account where you have full admin control:

1. Create a vault in your personal 1Password account
2. Re-add all `do-snap-bot` secrets to that vault
3. Go to **Developer** → **Service Accounts** → **New Service Account**
4. Grant the service account **read** access to the new vault
5. Update all `op://VaultName/` references in the project to match the new vault name

The vault name used in `op://` paths, `--vault` flags, and `.env.op` must exactly match the vault name in the account the service account belongs to.

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

### `uv` not found when starting the bot service

The original cloud-init installed `uv` to `/root/.local/bin/` and symlinked it to `/usr/local/bin/uv`. The symlink is unreadable by the `dosnap` user because it points inside root's home directory, so `start.sh` exits with `ERROR: uv not found`.

Fix on an existing droplet:

```bash
ssh -i ~/.ssh/id_m3do root@<controller-ip> \
  "curl -LsSf https://astral.sh/uv/install.sh | UV_INSTALL_DIR=/usr/local/bin sh"
```

The `controller.yml` cloud-init has been updated to install directly to `/usr/local/bin` on new droplets.

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
