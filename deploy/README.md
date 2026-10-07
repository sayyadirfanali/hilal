# Deploying Hilal

Hilal runs at `hilal.irfanali.org`, on the Fedora VPS, behind Nginx.
Run these as your own user, with sudo, from the Hilal repository on the VPS.

## Once

1. **DNS.** Point `hilal.irfanali.org` at the VPS, with an A record (and AAAA, if the VPS has IPv6).

2. **Brevo.** Sign up, then:
   - Under Senders, Domains & Dedicated IPs → Domains, add `irfanali.org` and add the DNS records Brevo shows.
     If `irfanali.org` already has an SPF record and Brevo asks for one, add Brevo's `include:` to the existing record:
     a domain must have only one SPF record.
   - Add `hilal@irfanali.org` as a sender.
   - Under SMTP & API → API keys, create a key for Hilal.

3. **Build tools.** Install ghcup, and the same GHC and cabal versions as on your computer (`ghc --version` there):
   ```sh
   sudo dnf install -y gcc gcc-c++ make gmp-devel zlib-devel ncurses-devel xz perl git curl python3-pip
   curl --proto '=https' --tlsv1.2 -sSf https://get-ghcup.haskell.org | sh
   pip install --user fonttools brotli
   ```
   The first build needs about 4 GB of memory. If `free -h` shows less, add swap first:
   ```sh
   sudo fallocate -l 4G /swapfile && sudo chmod 600 /swapfile && sudo mkswap /swapfile && sudo swapon /swapfile
   ```
   (On a btrfs root, make the file with `sudo btrfs filesystem mkswapfile --size 4g /swapfile` instead, then `sudo swapon /swapfile`.)

4. **Build.**
   ```sh
   ./install_vendor.sh && ./build_css.sh && cabal update && cabal build exe:hilal
   ```

5. **Install and start.**
   ```sh
   sudo useradd --system --home-dir /var/lib/hilal --create-home --shell /sbin/nologin hilal
   sudo install -m 755 "$(cabal list-bin hilal)" /usr/local/bin/hilal
   sudo install -m 644 deploy/hilal.service /etc/systemd/system/hilal.service
   sudo mkdir -p /etc/hilal && sudo install -m 600 /dev/null /etc/hilal/env
   sudoedit /etc/hilal/env
   ```
   Put these two lines in `/etc/hilal/env`, with the key from Brevo:
   ```
   BREVO_API_KEY=xkeysib-...
   HILAL_MAIL_FROM=hilal@irfanali.org
   ```
   Then:
   ```sh
   sudo systemctl daemon-reload && sudo systemctl enable --now hilal
   curl http://127.0.0.1:8080/health
   ```
   It should print `ok`. If not, `journalctl -u hilal` shows why.

6. **Nginx and HTTPS.**
   ```sh
   sudo install -m 644 deploy/hilal.nginx.conf /etc/nginx/conf.d/hilal.conf
   sudo nginx -t && sudo systemctl reload nginx
   sudo dnf install -y certbot python3-certbot-nginx
   sudo certbot --nginx -d hilal.irfanali.org
   ```
   Let certbot redirect HTTP to HTTPS. Port 8080 stays closed: `sudo firewall-cmd --list-all` must not list it.

7. **Check.** Open `https://hilal.irfanali.org`, sign in with `irfan@irfanali.org`, and the code should arrive by email.
   The Account page shows "Superadmin" for that address.

## Updating

```sh
git pull && ./build_css.sh && cabal build exe:hilal \
  && sudo install -m 755 "$(cabal list-bin hilal)" /usr/local/bin/hilal && sudo systemctl restart hilal
```

Run `./install_vendor.sh` again only when it changes.

Until launch, a schema change means starting with a new database, losing its data:

```sh
sudo systemctl stop hilal && sudo rm -f /var/lib/hilal/hilal.db* && sudo systemctl start hilal
```
