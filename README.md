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
- `sql/normalize_snowcam_example.sql`: normalized schema + catalog metadata
- `sql/add_camera.sql`: helper script to add/update resort/location/camera metadata
- `sql/add_camera_crop_columns.sql`: adds per-camera crop columns + metadata
- `sql/set_camera_crops.sql`: applies crop settings for existing cameras
- `sql/add_camera_model_notes.sql`: adds per-camera prompt notes column + metadata
- `sql/set_camera_model_notes.sql`: applies prompt notes for existing cameras
- `.env.example`: environment template

## Setup

1. Copy `.env.example` to `.env` and fill values.
2. Apply SQL schema:

```powershell
sqlcmd -S <server> -d <database> -U <user> -P <password> -i sql\normalize_snowcam_example.sql
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
sqlcmd -S <server> -d <database> -U <user> -P <password> ^
  -v RESORT_CODE="EXM" RESORT_NAME="Example Resort" TIMEZONE_NAME="America/Denver" ^
     LOCATION_CODE="SNOWSTAKE1" LOCATION_NAME="Main Mountain Snow Stake" ELEVATION_FT="0" ^
     CAMERA_CODE="EXM-CAM1" CAMERA_NAME="example_snowstake1" ^
     IMAGE_URL="https://example.com/cam-images/snowstake1.jpg" ^
     POLL_INTERVAL_MINUTES="30" ^
     CROP_X="" CROP_Y="" CROP_W="" CROP_H="" ^
     MODEL_NOTES="" ^
  -i sql\add_camera.sql
```

## Camera Tuning Fields

`dbo.dim_camera` supports per-camera image and prompt tuning:

- `crop_x`, `crop_y`, `crop_w`, `crop_h`: optional crop rectangle in source-image pixels
  - All four must be set together, or all null.
- `model_notes`: optional camera-specific instructions appended to the global model prompt.

These settings are useful for handling camera-specific quirks (fixed objects, logos, framing differences, etc.).

## Snowfall Guardrails

Additional guardrails are configurable in `.env`:

- `SNOW_MIN_CONFIDENCE_FOR_VALID_DEPTH` (default `0.6`)
- `SNOW_FORCE_UNREADABLE_ON_POOR_VISIBILITY` (default `true`)
- `SNOW_MIN_CONFIDENCE_FOR_INCREMENT` (default `0.85`)
- `SNOW_REQUIRE_GOOD_VISIBILITY_FOR_INCREMENT` (default `true`)
- `SNOW_MAX_INCREMENT_IN` (default `3.0`)

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
