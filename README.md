# WebCam Snow Measure

Snow stake reporting service using Vertex AI + SQL Server, designed to run in a Linux Docker container.

Authored by Harrison Kairalla.

## What It Does

1. Loads all active cameras from `dbo.dim_camera`.
2. Fetches all camera images.
3. Calls Vertex AI for each camera image pair (previous + current).
4. Writes observations to SQL Server with change-or-heartbeat logic.
5. Stores per-camera local state under `data/cameras/<camera_code>/`.

## Core Files

- `snow_reporter.py`: main app
- `Dockerfile`: container image
- `docker-compose.yml`: runtime config
- `sql/normalize_snowcam_prm.sql`: normalized schema + catalog metadata
- `sql/add_camera.sql`: helper script to add/update resort/location/camera metadata
- `.env.example`: environment template

## Setup

1. Copy `.env.example` to `.env` and fill values.
2. Apply SQL schema:

```powershell
sqlcmd -S <server> -d ExampleDB -U <user> -P <password> -i sql\normalize_snowcam_prm.sql
```

3. Build image:

```powershell
docker compose build
```

4. Run one cycle (all active cameras):

```powershell
docker compose run --rm snowcam-reporter python snow_reporter.py
```

## Vertex Auth (Docker)

If using a service account key file:

1. Place key at `./secrets/adc.json`
2. Uncomment key mount in `docker-compose.yml`
3. Set in `.env`:

```env
GOOGLE_APPLICATION_CREDENTIALS=/app/secrets/adc.json
```

## Add New Cameras

Use SQL metadata upsert and keep cameras active in `dbo.dim_camera`.

```powershell
sqlcmd -S <server> -d ExampleDB -U <user> -P <password> ^
  -v RESORT_CODE="EXM" RESORT_NAME="Example Resort" TIMEZONE_NAME="America/Denver" ^
     LOCATION_CODE="SNOWSTAKE1" LOCATION_NAME="Main Mountain Snow Stake" ELEVATION_FT="0" ^
     CAMERA_CODE="EXM-CAM1" CAMERA_NAME="example_snowstake1" ^
     IMAGE_URL="https://example.com/cam-images/example_snowstake1.jpg" ^
     POLL_INTERVAL_MINUTES="30" ^
  -i sql\add_camera.sql
```

## Windows Server (Docker + Task Scheduler)

1. Install Docker Desktop and enable Linux containers.
2. Clone/copy repo to `C:\WebCamSnowMeasure`.
3. Create `.env` from `.env.example` with production values.
4. Verify SQL connectivity.
5. Register scheduled task every 30 minutes to run:

```powershell
docker compose run --rm snowcam-reporter python snow_reporter.py
```

6. Confirm rows are inserted in `dbo.snowcam_observations`.

## Notes

- This app is DB-driven and processes all active cameras each run.
- Overlap protection uses `data/snow_reporter.lock`.
- Keep `.env` and `secrets/` out of source control.
