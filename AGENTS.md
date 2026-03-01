# AGENTS.md

## Purpose
Operational runbook and session guardrails for `WebCamSnowMeasure`.
Use this file in future sessions to avoid re-discovery work.

## Environment
- Project path (server): `C:\WebCamSnowMeasure`
- Runtime: Docker Compose service `snowcam-reporter`
- Primary DB: `ExampleDB` on `db-host` (from `.env`)

## Core Commands
- Pull latest:
```powershell
cd C:\WebCamSnowMeasure
git pull origin main
```
- Build image:
```powershell
docker compose build --no-cache snowcam-reporter
```
- Run one cycle:
```powershell
docker compose run --rm snowcam-reporter python snow_reporter.py
```

## DB Migration Order
Apply in this order when provisioning/updating camera tuning schema:
1. `sql/add_camera_crop_columns.sql`
2. `sql/set_camera_crops.sql`
3. `sql/add_camera_model_notes.sql`
4. `sql/set_camera_model_notes.sql`

If `sqlcmd` is not installed, run SQL through container Python + `pyodbc`.

## Camera Tuning Conventions
Per-camera settings live in `dbo.dim_camera`:
- `crop_x`, `crop_y`, `crop_w`, `crop_h`:
  - Pixel crop rectangle for the source image.
  - Must be all null or all populated.
- `model_notes`:
  - Camera-specific prompt instructions appended to the base prompt.
  - Use for fixed objects, stake quirks, and scene-specific exclusions.

Local per-camera files:
- `data/cameras/<camera_code_lower>/day_reference.jpg`
  - Daytime reference image used as context only (not measurement source).
- `history.json`, `latest_report.json`, `last_image.jpg`

## Reliability Guardrails
Configured in `.env`:
- `SNOW_MIN_CONFIDENCE_FOR_VALID_DEPTH` (default `0.6`)
- `SNOW_FORCE_UNREADABLE_ON_POOR_VISIBILITY` (default `true`)
- `SNOW_MIN_CONFIDENCE_FOR_INCREMENT` (default `0.85`)
- `SNOW_REQUIRE_GOOD_VISIBILITY_FOR_INCREMENT` (default `true`)
- `SNOW_MAX_INCREMENT_IN` (default `3.0`)

## Blank-Slate Reset
Reset local totals/history:
```powershell
Remove-Item .\data\cameras\*\history.json -Force -ErrorAction SilentlyContinue
Remove-Item .\data\cameras\*\daily_summaries\*.json -Force -ErrorAction SilentlyContinue
Remove-Item .\data\cameras\*\latest_report.json -Force -ErrorAction SilentlyContinue
```

Optional DB cleanup (keep latest row per camera) should be run manually and carefully.

## Security Rules
- Never commit `.env`, credentials, PATs, API keys, or service-account JSON.
- If any secret is exposed in chat/logs, rotate it.
- Keep `secrets/` and local reference images out of source control unless explicitly intended.

## Skills
Session-level skills currently available and verified:
- `skill-creator` at `C:\Users\hskai\.codex\skills\.system\skill-creator\SKILL.md`
- `skill-installer` at `C:\Users\hskai\.codex\skills\.system\skill-installer\SKILL.md`

Use these when a request explicitly asks to create/update/install skills.
