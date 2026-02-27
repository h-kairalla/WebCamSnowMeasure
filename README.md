# WebCam Snow Measure

Snow stake reporting service using Vertex AI + SQL Server, designed to run in a Linux Docker container.

Authored by Harrison Kairalla.

## What It Does

1. Polls the configured snow camera and compares current vs previous image.
2. Uses Vertex AI to estimate depth and return structured JSON.
3. Calculates interval snowfall, today total, and yesterday total.
4. Logs to SQL Server in change-or-heartbeat mode.
5. Writes local state/logs under `data/`.

## Core Files

- `snow_reporter.py`: main app
- `Dockerfile`: container image
- `docker-compose.yml`: runtime config
- `sql/normalize_snowcam_prm.sql`: normalized schema + catalog metadata
- `.env.example`: environment template

## Setup

1. Copy `.env.example` to `.env` and fill values.
2. Apply SQL schema:

```powershell
sqlcmd -S <server> -d ExampleDB -U <user> -P <password> -i sql\normalize_snowcam_prm.sql
```

3. Build and run with Docker:

```powershell
docker compose up -d --build
```

4. Check logs:

```powershell
docker compose logs -f snowcam-reporter
```

## Vertex Auth (Docker)

If using a service account key file:

1. Place key at `./secrets/adc.json`
2. Uncomment the key mount in `docker-compose.yml`
3. Set in `.env`:

```env
GOOGLE_APPLICATION_CREDENTIALS=/app/secrets/adc.json
```

## One-Shot Test

```powershell
docker compose run --rm snowcam-reporter python snow_reporter.py --once
```

## Windows Server Checklist

1. Install Docker Desktop and enable Linux containers.
2. Ensure Docker Desktop starts automatically after server reboot.
3. Copy project folder to server.
4. Create `.env` from `.env.example` with production values.
5. If using service-account JSON auth:
   - place key at `secrets/adc.json`
   - set `GOOGLE_APPLICATION_CREDENTIALS=/app/secrets/adc.json`
   - ensure the mount is enabled in `docker-compose.yml`
6. Confirm SQL Server is reachable from server (`DB_SERVER`, firewall, routing).
7. Run schema migration:

```powershell
sqlcmd -S <server> -d ExampleDB -U <user> -P <password> -i sql\normalize_snowcam_prm.sql
```

8. Start service:

```powershell
docker compose up -d --build
```

9. Verify:
   - `docker compose logs -f snowcam-reporter`
   - a new row is inserted into `dbo.snowcam_observations`

## Notes

- Runtime camera identity is `CAMERA_CODE`.
- `data/history.json` is required app state for deltas/totals.
- Keep `.env` and `secrets/` out of source control.
