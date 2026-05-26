# Setup Notes — Operator Observations

Field notes from working through `docs/setup-cc.md`. Captures gotchas,
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
