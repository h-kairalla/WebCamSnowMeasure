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
- `docker-compose.cameras.yml`: multi-camera compose template
- `sql/normalize_snowcam_prm.sql`: normalized schema + catalog metadata
- `sql/add_camera.sql`: helper script to add/update resort/location/camera metadata
- `.env.example`: environment template
- `.env.camera.example`: per-camera env template

## Setup

1. Copy `.env.example` to `.env` and fill values.
2. Apply SQL schema:

```powershell
sqlcmd -S <server> -d ExampleDB -U <user> -P <password> -i sql\normalize_snowcam_prm.sql
```

3. Build Docker image:

```powershell
docker compose build
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

## Run Modes

1. Production (scheduled, recommended for Windows Server):
   - Use Task Scheduler every 30 minutes.
   - Command:

```powershell
docker compose run --rm snowcam-reporter python snow_reporter.py --once
```

2. Development (optional):
   - Continuous loop in one container:

```powershell
docker compose up -d --build
```

Important: `docker compose run --rm snowcam-reporter` without `--once` will use the compose command loop and is not the scheduled mode.

## Add New Cameras

1. Add/activate camera metadata in SQL:

```powershell
sqlcmd -S <server> -d ExampleDB -U <user> -P <password> ^
  -v RESORT_CODE=\"PRM\" RESORT_NAME=\"Example Resort\" TIMEZONE_NAME=\"America/Denver\" ^
     LOCATION_CODE=\"SNOWSTAKE1\" LOCATION_NAME=\"Main Mountain Snow Stake\" ELEVATION_FT=\"0\" ^
     CAMERA_CODE=\"EXM-CAM1\" CAMERA_NAME=\"example_snowstake1\" ^
     IMAGE_URL=\"https://example.com/cam-images/example_snowstake1.jpg\" ^
     POLL_INTERVAL_MINUTES=\"30\" ^
  -i sql\\add_camera.sql
```

2. Create a per-camera env file from `.env.camera.example` (for example `.env.camera.exm-cam1`) and set `CAMERA_CODE`.
3. Use `docker-compose.cameras.yml` to run one service per camera.
4. Preferred at scale: at ~50 cameras, move to a DB-driven active camera list with one scheduled runner process rather than many long-running camera services.

## Windows Server Checklist

1. Install Docker Desktop and enable Linux containers.
2. Ensure Docker Desktop starts automatically after server reboot.
3. Clone the repo on the server (or pull latest changes).
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

8. Register Task Scheduler job (every 30 minutes) to run:

```powershell
docker compose run --rm snowcam-reporter python snow_reporter.py --once
```

9. Verify:
   - Task history shows successful runs
   - a new row is inserted into `dbo.snowcam_observations`

## Notes

- Runtime camera identity is `CAMERA_CODE`.
- `data/history.json` is required app state for deltas/totals.
- Overlap protection relies on lock/state under `data/` (host bind mount), not ephemeral container filesystem.
- Keep `.env` and `secrets/` out of source control.
