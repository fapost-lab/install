# fapost-install

One-command installer for [FaPost Core](https://github.com/fapost-lab/core).

```bash
sh -c "$(curl -fsSL https://get.fapost.in/install.sh)"
```

It asks what it cannot work out, generates what should never be typed by hand,
and leaves a running stack behind. No clone, no files to create, no passwords to
invent.

## What it does

1. Checks that Docker is present, the daemon is reachable, and the Compose plugin
   is v2.23 or newer — the compose file carries its services' configuration
   inline, which older versions do not understand.
2. Asks for the base domain, the tenant slug, the administrator's email, and
   whether to terminate TLS with the bundled Caddy.
3. Downloads `compose.yaml` and the production environment template from the
   application repository.
4. Generates `APP_KEY` and the database and Redis passwords, and writes a `.env`
   with mode `600` beside the compose file.
5. Starts the stack and waits for the application to answer.
6. Creates the first tenant and its administrator, passing the password on
   standard input so it never reaches a process list.

Everything it writes lives in the installation directory. It installs no
packages, registers no services, and touches nothing under `/etc`.

## Unattended

Every question is also a flag, so the same script installs without a terminal:

```bash
curl -fsSL https://get.fapost.in/install.sh -o install.sh
sh install.sh --yes \
  --domain fapost.example.com \
  --admin-email ops@example.com
```

`--yes` requires `--domain` and `--admin-email`; everything else falls back to a
default. Supply the administrator's password with `FAPOST_ADMIN_PASSWORD` or
`--admin-password-file` — otherwise one is generated and printed once, at the end.

| Option | Default | |
|---|---|---|
| `--domain DOMAIN` | — | Base domain. The panel is served from the tenant slug prefixed to it. |
| `--admin-email EMAIL` | — | First administrator. |
| `--tenant-slug SLUG` | `app` | Slug of the first tenant. |
| `--install-dir PATH` | `./fapost` | Where to install. |
| `--app-version TAG` | `latest` | Image tag to run. |
| `--http-port PORT` | `8000` | Plain-HTTP port, when TLS is off. |
| `--tls` / `--no-tls` | asked | Terminate TLS with the bundled Caddy. |
| `--gateway` | off | Also run the optional Go webhook gateway. |
| `--ref REF` | `main` | Branch or tag to fetch `compose.yaml` from. |
| `--admin-password-file F` | — | Read the password from a file, or `-` for stdin. |
| `-y`, `--yes` | — | Ask nothing. |

## Two hostnames

The base domain carries the welcome page and is reserved for a control plane.
The admin panel and the assistant console are served from the **tenant's own
host** — the slug prefixed to the base domain. With `--domain fapost.example.com`
and the default slug, that is:

| | |
|---|---|
| `fapost.example.com` | welcome page |
| `app.fapost.example.com` | panel, at `/admin` |

Both must resolve to the host you are installing on. With `--tls` Caddy obtains
a certificate for each; DNS has to be in place first, because it proves control
of the names by answering a challenge on port 80.

## Re-running

Safe. Point it at an existing installation directory and it offers to keep the
`.env` it finds, reading the domain and tenant slug back out of it rather than
letting its own defaults contradict the file. Tenant provisioning refuses to run
twice, so a second run of a finished install changes nothing.

If provisioning failed and the stack is up, finish it by hand:

```bash
cd fapost
docker compose exec app php artisan platform:install \
  --tenant-slug=app --admin-email=you@example.com
```

## Why the compose file is not in this repository

It lives in [`fapost-lab/core`](https://github.com/fapost-lab/core/blob/main/docker/compose.yaml),
next to the `Dockerfile` that builds the images it starts. A copy here would
drift from the topology it is supposed to describe, and the first symptom would
be an installation that starts services the application no longer has. This
script fetches it at install time and pins nothing of its own.

## Development

```bash
shellcheck -s sh install.sh
```

To exercise it against a local checkout of the application instead of GitHub:

```bash
FAPOST_RAW_BASE=file:///path/to/fapost-core \
  sh install.sh --ref . --yes --no-tls \
    --domain fapost.test --admin-email ops@fapost.test \
    --install-dir /tmp/fapost-test
```

`curl` reads `file://` URLs, so `--ref .` resolves the two downloads to the
working tree.

## Licence

Apache-2.0. See [LICENSE](LICENSE).
