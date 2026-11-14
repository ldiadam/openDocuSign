# Dokploy deployment notes

## Persistent storage (required)

The app keeps all mutable state under `/data/docuseal`:

- `db.sqlite3` (if you use SQLite)
- `attachments/` (uploaded and signed files)
- `docuseal.env` (auto-generated `SECRET_KEY_BASE` if not provided)

The `VOLUME ["/data"]` line in the Dockerfile is only a declaration. Dokploy applications must attach a **named volume** at `/data`; otherwise every deployment starts with a fresh volume/container filesystem and data appears to reset.

### Application (Dockerfile) deployment

In Dokploy:

1. Open the application.
2. Go to **Advanced → Volumes**.
3. Add a **Volume** (not a Bind to a repo path).
4. Mount path: `/data`.
5. Name it something like `docuseal_data`.
6. Redeploy.

Verify inside the container:

```sh
ls -l /data/docuseal
```

The authoritative check is Dokploy's **Advanced → Volumes** list: there must be a named volume (not an anonymous one) mounted at `/data`. The Dockerfile's `VOLUME` declaration can create an anonymous volume, but Dokploy does not reuse that across deployments — only an explicitly configured named volume persists.

### Docker Compose deployment

Use `docker-compose.dokploy.yml` as the Compose file. It already defines:

```yaml
volumes:
  - docuseal_data:/data
```

Set `APP_URL` and `SECRET_KEY_BASE` in Dokploy's environment. The Compose file requires both.

## Secrets

`SECRET_KEY_BASE` encrypts signing certificates, SMTP credentials, and other configs. Set it once in Dokploy and never change it.

If you leave it unset, the app generates `/data/docuseal/docuseal.env` on first boot. That file must live on the persistent volume. If the volume is lost, the encryption key is lost with it.

## Recovering an old anonymous volume

If data was lost after a redeploy, an old Docker volume may still contain it. On the Dokploy server:

```sh
for v in $(docker volume ls -q); do
  docker run --rm -v "$v":/v alpine sh -c 'test -f /v/docuseal/db.sqlite3 && echo "$v"'
done
```

Copy the found volume into the named volume Dokploy will use:

```sh
docker volume create docuseal_data
docker run --rm -v OLD_VOLUME:/from -v docuseal_data:/to alpine sh -c 'cp -a /from/. /to/'
```

Then attach `docuseal_data` at `/data` and redeploy.

Important: if you set `SECRET_KEY_BASE` in Dokploy, it must match the old value from the old `docuseal.env`. Otherwise encrypted configs (certificate, SMTP) cannot be decrypted.

## Postgres

If you use Postgres, the database persists in the Postgres service's own volume. You still need `/data` for `attachments/` and `docuseal.env`.

## Backups

Use Dokploy's Volume Backups for the named `docuseal_data` volume. Back up Postgres separately if used.
