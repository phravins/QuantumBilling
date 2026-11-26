# Deploying on Coolify

[`docker-compose.coolify.yml`](../docker-compose.coolify.yml) runs the same image and PostgreSQL 16 database as the [Docker Compose](deployment.md#docker-compose) setup, adapted for the Docker Compose build pack of Coolify v4:

- Coolify generates the database login and the three keys.
- Migrations run in the app container before the server starts, so no one-shot container is left exited and the image is built once.
- No host port is published. Coolify's proxy routes the domain to the container and terminates TLS.

Only `PHX_HOST` has to be set by hand. Keep using [`docker-compose.yml`](../docker-compose.yml) on a plain host with your own reverse proxy.

## Create the resource

1. Create a resource from the repository and choose the **Docker Compose** build pack.
2. Set the base directory to `/` and the Docker Compose location to `/docker-compose.coolify.yml`.
3. Under **Advanced**, turn off **Inject Build Args to Dockerfile**. See [Build-time and runtime variables](#build-time-and-runtime-variables).
4. On the `quantum-billing` service, set the domain to `https://billing.example.com:4000`. The `:4000` tells the proxy which container port to use; visitors still open `https://billing.example.com`. Point the DNS record at the server first so the certificate can be issued. `quantum-billing-db` gets no domain.
5. Under **Environment Variables**, set `PHX_HOST` to the bare host name, `billing.example.com`, with no scheme, port or path. Coolify blocks the deploy while it is empty. If it doesn't match the domain, pages load but LiveView refuses the connection and shows "Attempting to reconnect".
6. Optionally, set up [mail](#mail-smtp) and the provider settings in [configuration](configuration.md).
7. Deploy.

The image is built once. `quantum-billing-db` becomes healthy, then `quantum-billing` runs the migrations and starts the server. Both show as healthy. Migrations run once per business, so an installation with many businesses takes longer to start; the health check allows five minutes before failures count.

## Generated values

Coolify creates these on the first deploy, lists them under **Environment Variables** and keeps them across deploys:

| Variable | Becomes |
| --- | --- |
| `SERVICE_USER_POSTGRES` | Database user (16 letters and digits) |
| `SERVICE_PASSWORD_POSTGRES` | Database password (32 letters and digits, safe inside `DATABASE_URL`) |
| `SERVICE_BASE64_64_SECRETKEYBASE` | `SECRET_KEY_BASE` |
| `SERVICE_BASE64_64_TOTPKEY` | `TOTP_ENCRYPTION_KEY` |
| `SERVICE_BASE64_64_SECRETSKEY` | `SECRETS_ENCRYPTION_KEY` |

- **Copy all five to your password manager or secret store after the first deploy.**
  - A database backup can't be read back without the two encryption keys.
  - Deleting the Coolify resource deletes them.
- **Don't regenerate or edit them on a running installation:**
  - A new `SECRET_KEY_BASE` signs everyone out.
  - New encryption keys leave stored secrets and 2FA enrolments unreadable ([database](database.md#7-encryption-hashes-and-secrets)).
  - PostgreSQL reads the user and password only when it creates an empty data volume. A changed login therefore locks the app out of the existing database.

## Build-time and runtime variables

By default Coolify makes every variable available both at build time and at runtime. It passes build-time variables to the image build as build args, and it can add matching `ARG` lines to the Dockerfile, which can leave the values in the image's build history.

The image needs no build args, so:

- Turn off **Inject Build Args to Dockerfile** under **Advanced**.
- On every secret, turn off build-time and leave runtime on. The secrets are:
  - the five generated values;
  - `SMTP_PASSWORD`, `SEED_ADMIN_PASSWORD`;
  - the `RAZORPAY_*` keys;
  - `IRP_CLIENT_SECRET`, `NIC_EWB_API_KEY`, `GOOGLE_CALENDAR_CLIENT_SECRET`.

Coolify stores the values in plain text under `/data/coolify` on the server. Limit who has shell access to it.

## Client IPs (`TRUSTED_PROXIES`)

The audit log and the per-client rate limits use the client's address.

- **How the app finds it:** it reads `x-forwarded-for` only when the request comes from an address in `TRUSTED_PROXIES`, and then takes the rightmost entry that isn't trusted itself. An address added by the client can't win.
- **The default in this file:** the private ranges, `10.0.0.0/8,172.16.0.0/12,192.168.0.0/16,fc00::/7`.
- **Why the default is safe here:** no host port is published, so only containers on the resource's Docker network can reach the app, and the proxy is the one that does.
- **What happens without it:** every request appears to come from the proxy, and all users share one rate-limit bucket.

To narrow it to the resource's network, run this on the server:

```bash
app=$(docker ps -q --filter label=com.docker.compose.service=quantum-billing)
docker inspect "$app" --format '{{range $name, $net := .NetworkSettings.Networks}}{{$name}} {{end}}'
docker network inspect <network name> --format '{{range .IPAM.Config}}{{.Subnet}} {{end}}'
```

- **If several resources run on the server,** add `--filter label=com.docker.compose.project=<resource UUID>` to the first command.
- **Then** set `TRUSTED_PROXIES` to the subnet, for example `10.0.2.0/24`, and redeploy. Use the subnet rather than the proxy's own address, which can change when the proxy restarts.

**To check it,** sign in and open **Settings › Audit log**. Your sign-in should show your public address.

**If IPv6 visitors show up with a private address,** the proxy itself is seeing the Docker gateway rather than the visitor. That happens on older Coolify proxy networks that are IPv4-only; Coolify's [wrong client IP](https://coolify.io/docs/troubleshoot/applications/wrong-client-ip) guide fixes it.

## First admin account

The seed creates the first account from `SEED_ADMIN_EMAIL`, `SEED_ADMIN_USERNAME` and `SEED_ADMIN_PASSWORD` (8–72 characters).

1. Add the three as runtime-only variables and redeploy, because containers read variables when they start.
2. Open **Terminal** on the `quantum-billing` container and run:

   ```bash
   bin/quantum_billing eval 'Application.ensure_all_started(:quantum_billing); QuantumBilling.Release.seed()'
   ```

3. Sign in, then delete the three variables and redeploy, so the password isn't left in Coolify.

## Mail (SMTP)

Without `SMTP_HOST`, the app boots with a warning, and its mail (sign-in links, password resets, invoices) fails with a clear message in the delivery ledger. This lasts until a relay is set here or under **Settings › SMTP**.

DigitalOcean [blocks SMTP ports 25, 465 and 587](https://docs.digitalocean.com/support/why-is-smtp-blocked/) on Droplets by default, so mail times out there. Most relay providers also accept STARTTLS on port 2525:

```bash
SMTP_HOST=smtp.your-provider.example
SMTP_PORT=2525
SMTP_USERNAME=<from your provider>
SMTP_PASSWORD=<from your provider, runtime-only>
SMTP_SSL=
MAILER_FROM_EMAIL=billing@example.com
```

- **`SMTP_SSL`:** leave it empty for ports 587 and 2525, and the app requires STARTTLS. Only port 465, or `SMTP_SSL=true`, uses implicit TLS ([configuration](configuration.md)).
- **Other hosting providers** may block ports too.

## Backups

Coolify's scheduled backups cover databases that Coolify runs as their own resources. This PostgreSQL is part of the app's compose file, so back it up yourself, together with the uploads volume. On the server:

```bash
db=$(docker ps -q --filter label=com.docker.compose.service=quantum-billing-db)
app=$(docker ps -q --filter label=com.docker.compose.service=quantum-billing)
docker exec "$db" sh -c 'pg_dump -U "$POSTGRES_USER" -Fc "$POSTGRES_DB"' > "quantum_billing-$(date +%F).dump"
docker cp "$app":/app/uploads "./uploads-$(date +%F)"
```

- **Schedule it:** put these lines in a script and run it from cron. Copy the files off the server, and treat them as sensitive.
- **Keep the keys with the backups:** a dump can't be restored to a working installation without its [generated keys](#generated-values) ([backups and recovery](deployment.md#backups-and-recovery)).
- **Before deleting the resource,** back it up. Deleting the resource in Coolify can also delete its volumes.

## Upgrades

On each deploy, Coolify builds the new image and replaces the container. The new container migrates the database before it serves requests, so the app is unavailable during the migrations. If a migration fails, the container stops, and the restart policy retries it. The log shows the error.

- **Before each deploy,** take a backup, and read [versions and upgrades](deployment.md#versions-and-upgrades) when the version changes.
- **With automatic deploys turned on,** every push to the branch migrates the database. For production, deploy from a release branch or tag.

## Other platforms

Only the `SERVICE_*` variables in this file are specific to Coolify. On Dokploy, CapRover and similar tools, set them yourself:

```bash
openssl rand -hex 12                        # SERVICE_USER_POSTGRES
openssl rand -hex 24                        # SERVICE_PASSWORD_POSTGRES
openssl rand -base64 48 | tr -d '\n'        # each SERVICE_BASE64_64_* key, separately
```
