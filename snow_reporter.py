import argparse
import json
import logging
import os
import smtplib
import sys
import time
from dataclasses import dataclass
from datetime import date, datetime, timedelta, timezone
from email.message import EmailMessage
from pathlib import Path
from typing import Any, Callable, Dict, List, Optional
from zoneinfo import ZoneInfo, ZoneInfoNotFoundError

import pyodbc
import requests
from dotenv import load_dotenv
from google import genai
from google.auth.exceptions import DefaultCredentialsError
from google.genai import types


@dataclass
class Config:
    image_url: str
    project_id: str
    location: str
    model: str
    use_vertex_ai: bool
    timezone_name: str
    interval_minutes: int
    min_increment_in: float
    clear_drop_threshold_in: float
    use_mock_analyzer: bool
    image_verify_tls: bool
    fetch_retry_attempts: int
    vertex_retry_attempts: int
    retry_delay_seconds: int
    camera_code: str
    db_enabled: bool
    db_driver: str
    db_server: str
    db_database: str
    db_username: str
    db_password: str
    heartbeat_hours: int
    change_epsilon_in: float
    lock_stale_minutes: int
    # Email alert settings
    alert_email_enabled: bool
    alert_email_to: str
    alert_email_from: str
    alert_subject_prefix: str
    alert_cooldown_minutes: int
    smtp_host: str
    smtp_port: int
    smtp_username: str
    smtp_password: str
    smtp_starttls: bool
    data_dir: Path


class FileLock:
    """Simple lock file to prevent overlapping scheduler runs."""

    def __init__(self, lock_path: Path, stale_minutes: int) -> None:
        self.lock_path = lock_path
        self.stale_minutes = stale_minutes

    def __enter__(self) -> "FileLock":
        now = datetime.now(timezone.utc)
        if self.lock_path.exists():
            try:
                payload = json.loads(self.lock_path.read_text(encoding="utf-8"))
                created_at = datetime.fromisoformat(payload.get("created_at_utc", "").replace("Z", "+00:00"))
            except Exception:
                created_at = now

            if now - created_at > timedelta(minutes=self.stale_minutes):
                self.lock_path.unlink(missing_ok=True)
            else:
                raise RuntimeError(f"Another run is active. Lock exists at {self.lock_path}")

        self.lock_path.parent.mkdir(parents=True, exist_ok=True)
        fd = os.open(str(self.lock_path), os.O_CREAT | os.O_EXCL | os.O_WRONLY)
        with os.fdopen(fd, "w", encoding="utf-8") as f:
            f.write(
                json.dumps(
                    {
                        "pid": os.getpid(),
                        "created_at_utc": now.replace(microsecond=0).isoformat().replace("+00:00", "Z"),
                    }
                )
            )
        return self

    def __exit__(self, exc_type: Any, exc: Any, tb: Any) -> None:
        self.lock_path.unlink(missing_ok=True)


def load_config(args: argparse.Namespace) -> Config:
    data_dir = Path(args.data_dir).resolve()
    return Config(
        image_url=os.getenv(
            "SNOW_IMAGE_URL",
            "https://example.com/cam-images/example_snowstake1.jpg",
        ),
        project_id=os.getenv("GOOGLE_CLOUD_PROJECT", ""),
        location=os.getenv("GOOGLE_CLOUD_LOCATION", "us-central1"),
        model=os.getenv("VERTEX_MODEL", "gemini-2.5-pro"),
        use_vertex_ai=os.getenv("USE_VERTEX_AI", "true").lower() == "true",
        timezone_name=os.getenv("RESORT_TIMEZONE", "America/Denver"),
        interval_minutes=args.interval_minutes,
        min_increment_in=float(os.getenv("SNOW_MIN_INCREMENT_IN", "0.1")),
        clear_drop_threshold_in=float(os.getenv("SNOW_CLEAR_DROP_IN", "2.0")),
        use_mock_analyzer=os.getenv("SNOW_USE_MOCK_ANALYZER", "false").lower() == "true",
        image_verify_tls=os.getenv("SNOW_IMAGE_VERIFY_TLS", "true").lower() == "true",
        fetch_retry_attempts=int(os.getenv("FETCH_RETRY_ATTEMPTS", "2")),
        vertex_retry_attempts=int(os.getenv("VERTEX_RETRY_ATTEMPTS", "2")),
        retry_delay_seconds=int(os.getenv("RETRY_DELAY_SECONDS", "3")),
        camera_code=os.getenv("CAMERA_CODE", "EXM-CAM1"),
        db_enabled=os.getenv("DB_ENABLED", "true").lower() == "true",
        db_driver=os.getenv("DB_DRIVER", "ODBC Driver 18 for SQL Server"),
        db_server=os.getenv("DB_SERVER", ""),
        db_database=os.getenv("DB_DATABASE", "ExampleDB"),
        db_username=os.getenv("DB_USERNAME", ""),
        db_password=os.getenv("DB_PASSWORD", ""),
        heartbeat_hours=int(os.getenv("DB_HEARTBEAT_HOURS", "12")),
        change_epsilon_in=float(os.getenv("DB_CHANGE_EPSILON_IN", "0.05")),
        lock_stale_minutes=int(os.getenv("LOCK_STALE_MINUTES", "120")),
        alert_email_enabled=os.getenv("ALERT_EMAIL_ENABLED", "false").lower() == "true",
        alert_email_to=os.getenv("ALERT_EMAIL_TO", ""),
        alert_email_from=os.getenv("ALERT_EMAIL_FROM", ""),
        alert_subject_prefix=os.getenv("ALERT_SUBJECT_PREFIX", "SnowCam Alert"),
        alert_cooldown_minutes=int(os.getenv("ALERT_COOLDOWN_MINUTES", "60")),
        smtp_host=os.getenv("SMTP_HOST", ""),
        smtp_port=int(os.getenv("SMTP_PORT", "587")),
        smtp_username=os.getenv("SMTP_USERNAME", ""),
        smtp_password=os.getenv("SMTP_PASSWORD", ""),
        smtp_starttls=os.getenv("SMTP_STARTTLS", "true").lower() == "true",
        data_dir=data_dir,
    )


def ensure_data_paths(data_dir: Path) -> Dict[str, Path]:
    logs_dir = data_dir / "logs"
    daily_summary_dir = data_dir / "daily_summaries"
    data_dir.mkdir(parents=True, exist_ok=True)
    logs_dir.mkdir(parents=True, exist_ok=True)
    daily_summary_dir.mkdir(parents=True, exist_ok=True)
    return {
        "history": data_dir / "history.json",
        "last_image": data_dir / "last_image.jpg",
        "latest_report": data_dir / "latest_report.json",
        "log_file": logs_dir / "snow_reporter.log",
        "lock_file": data_dir / "snow_reporter.lock",
        "daily_summary_dir": daily_summary_dir,
        "email_state": data_dir / "email_state.json",
    }


def setup_logger(log_file: Path) -> logging.Logger:
    logger = logging.getLogger("snow_reporter")
    logger.setLevel(logging.INFO)
    logger.handlers.clear()

    formatter = logging.Formatter("%(asctime)s %(levelname)s %(message)s")

    file_handler = logging.FileHandler(log_file, encoding="utf-8")
    file_handler.setFormatter(formatter)

    stream_handler = logging.StreamHandler(sys.stdout)
    stream_handler.setFormatter(formatter)

    logger.addHandler(file_handler)
    logger.addHandler(stream_handler)
    return logger


def load_history(path: Path) -> List[Dict[str, Any]]:
    if not path.exists():
        return []
    return json.loads(path.read_text(encoding="utf-8"))


def save_history(path: Path, history: List[Dict[str, Any]]) -> None:
    path.write_text(json.dumps(history, indent=2), encoding="utf-8")


def with_retry(
    operation_name: str,
    attempts: int,
    delay_seconds: int,
    func: Callable[[], Any],
    logger: logging.Logger,
) -> Any:
    # Basic retry wrapper for flaky network operations (camera fetch/model call).
    last_error: Optional[Exception] = None
    for i in range(1, max(attempts, 1) + 1):
        try:
            return func()
        except Exception as exc:
            last_error = exc
            if i >= attempts:
                break
            logger.warning("%s failed (attempt %s/%s): %s", operation_name, i, attempts, exc)
            time.sleep(delay_seconds)
    if last_error is None:
        raise RuntimeError(f"{operation_name} failed with unknown error")
    raise last_error


def fetch_image(image_url: str, verify_tls: bool) -> bytes:
    response = requests.get(image_url, timeout=30, verify=verify_tls)
    response.raise_for_status()
    return response.content


def build_prompt() -> str:
    return (
        "You are analyzing a fixed snow stake webcam for a ski resort.\n"
        "Estimate snow depth on the stake in inches.\n"
        "The numbered marks on the stake are inches.\n"
        "Return depth rounded to the nearest 0.5 inch.\n"
        "Return JSON only with this exact schema:\n"
        "{"
        '"current_depth_in": number,'
        '"confidence": number,'
        '"visibility": "good|fair|poor",'
        '"notes": string'
        "}\n"
        "Rules:\n"
        "- confidence is 0 to 1\n"
        "- current_depth_in is inches above the stake base (0-inch level)\n"
        "- if the snow line is at or below the 0-inch level, return 0.0\n"
        "- snow on nearby surfaces that is not touching the stake at the measurement point does not count\n"
        "- shadows, wet pavement reflections, and dark water patches are not snow depth\n"
        "- when uncertain, choose the lower depth estimate\n"
        "- be conservative when visibility is poor\n"
        "- notes must be concise and <= 180 characters\n"
    )


def parse_model_json(raw_text: str) -> Dict[str, Any]:
    start = raw_text.find("{")
    end = raw_text.rfind("}")
    if start == -1 or end == -1 or end <= start:
        raise ValueError(f"Model did not return JSON object: {raw_text}")
    obj = json.loads(raw_text[start : end + 1])
    return {
        "current_depth_in": float(obj["current_depth_in"]),
        "confidence": float(obj.get("confidence", 0.0)),
        "visibility": str(obj.get("visibility", "unknown")),
        "notes": str(obj.get("notes", "")),
    }


def analyze_with_vertex(
    cfg: Config, current_image: bytes, previous_image: Optional[bytes]
) -> Dict[str, Any]:
    if cfg.use_mock_analyzer:
        return {
            "current_depth_in": 24.0,
            "confidence": 0.6,
            "visibility": "fair",
            "notes": "Mock analyzer enabled.",
        }

    if cfg.use_vertex_ai:
        if not cfg.project_id:
            raise ValueError("GOOGLE_CLOUD_PROJECT is required when USE_VERTEX_AI=true.")
        client = genai.Client(vertexai=True, project=cfg.project_id, location=cfg.location)
    else:
        api_key = os.getenv("GEMINI_API_KEY", "")
        if not api_key:
            raise ValueError("GEMINI_API_KEY is required when USE_VERTEX_AI=false.")
        client = genai.Client(api_key=api_key)

    parts = [types.Part.from_text(text=build_prompt())]

    if previous_image:
        parts.append(types.Part.from_text(text="Previous image (earlier in time):"))
        parts.append(types.Part.from_bytes(data=previous_image, mime_type="image/jpeg"))

    parts.append(types.Part.from_text(text="Current image (latest):"))
    parts.append(types.Part.from_bytes(data=current_image, mime_type="image/jpeg"))

    try:
        response = client.models.generate_content(
            model=cfg.model,
            contents=[types.Content(role="user", parts=parts)],
            config=types.GenerateContentConfig(
                temperature=0.0,
                response_mime_type="application/json",
            ),
        )
    except DefaultCredentialsError as exc:
        raise RuntimeError(
            "Vertex AI authentication not configured. Run `gcloud auth application-default login` "
            "or set GOOGLE_APPLICATION_CREDENTIALS to a service-account key file."
        ) from exc
    return parse_model_json(response.text or "")


def compute_interval_snowfall(
    current_depth_in: float,
    previous_depth_in: Optional[float],
    min_increment_in: float,
    clear_drop_threshold_in: float,
) -> Dict[str, Any]:
    if previous_depth_in is None:
        return {"interval_snowfall_in": 0.0, "stake_cleared": False, "delta_in": 0.0}

    delta = current_depth_in - previous_depth_in
    if delta <= -clear_drop_threshold_in:
        return {"interval_snowfall_in": 0.0, "stake_cleared": True, "delta_in": delta}
    if delta >= min_increment_in:
        return {"interval_snowfall_in": round(delta, 2), "stake_cleared": False, "delta_in": delta}
    return {"interval_snowfall_in": 0.0, "stake_cleared": False, "delta_in": delta}


def get_timezone(timezone_name: str) -> timezone:
    try:
        return ZoneInfo(timezone_name)
    except ZoneInfoNotFoundError:
        return timezone.utc


def local_date(utc_iso: str, timezone_name: str) -> str:
    dt = datetime.fromisoformat(utc_iso.replace("Z", "+00:00"))
    return dt.astimezone(get_timezone(timezone_name)).date().isoformat()


def total_for_date(history: List[Dict[str, Any]], date_str: str, timezone_name: str) -> float:
    total = 0.0
    for row in history:
        if local_date(row["timestamp_utc"], timezone_name) == date_str:
            total += float(row.get("interval_snowfall_in", 0.0))
    return round(total, 2)


def count_for_date(history: List[Dict[str, Any]], date_str: str, timezone_name: str) -> int:
    return sum(1 for row in history if local_date(row["timestamp_utc"], timezone_name) == date_str)


def now_utc_iso() -> str:
    return datetime.now(timezone.utc).replace(microsecond=0).isoformat().replace("+00:00", "Z")


def utc_iso_to_datetime(utc_iso: str) -> datetime:
    return datetime.fromisoformat(utc_iso.replace("Z", "+00:00"))


def build_db_conn_str(cfg: Config) -> str:
    return (
        f"DRIVER={{{cfg.db_driver}}};"
        f"SERVER={cfg.db_server};"
        f"DATABASE={cfg.db_database};"
        f"UID={cfg.db_username};"
        f"PWD={cfg.db_password};"
        "Encrypt=yes;"
        "TrustServerCertificate=yes;"
    )


def get_db_connection(cfg: Config) -> pyodbc.Connection:
    if not cfg.db_enabled:
        raise RuntimeError("DB logging is disabled.")
    required = [cfg.db_server, cfg.db_database, cfg.db_username, cfg.db_password]
    if not all(required):
        raise RuntimeError("DB connection settings are incomplete.")
    return pyodbc.connect(build_db_conn_str(cfg), timeout=30)


def check_db_schema(cfg: Config, logger: logging.Logger) -> bool:
    if not cfg.db_enabled:
        return False
    try:
        with get_db_connection(cfg) as conn:
            cur = conn.cursor()
            cur.execute(
                """
                SELECT
                    OBJECT_ID('dbo.snowcam_observations', 'U') AS fact_id,
                    OBJECT_ID('dbo.dim_camera', 'U') AS dim_camera_id,
                    COL_LENGTH('dbo.snowcam_observations', 'camera_id') AS has_camera_id
                """
            )
            # Normalized mode requires both dimension table and fact FK column.
            row = cur.fetchone()
            ready = bool(row and row[0] and row[1] and row[2])
            if not ready:
                # Start-up warning so deployment issues are visible immediately.
                logger.warning(
                    "DB schema check failed. Run sql/normalize_snowcam_prm.sql to apply normalized schema."
                )
            return ready
    except Exception as exc:
        logger.warning("DB schema check failed: %s", exc)
        return False


def resolve_camera_context(cfg: Config) -> Dict[str, Any]:
    with get_db_connection(cfg) as conn:
        cur = conn.cursor()
        cur.execute(
            """
            SELECT
                c.camera_id,
                c.camera_name,
                c.camera_code,
                c.image_url,
                c.is_active,
                l.location_name,
                r.resort_name,
                r.timezone_name
            FROM dbo.dim_camera c
            JOIN dbo.dim_location l ON c.location_id = l.location_id
            JOIN dbo.dim_resort r ON l.resort_id = r.resort_id
            WHERE c.camera_code = ?
            """,
            cfg.camera_code,
        )
        # CAMERA_CODE is the only runtime identity key; all names come from DB dimensions.
        row = cur.fetchone()
        if not row:
            raise RuntimeError(f"CAMERA_CODE '{cfg.camera_code}' was not found in dbo.dim_camera.")
        if not bool(row[4]):
            raise RuntimeError(f"CAMERA_CODE '{cfg.camera_code}' is inactive in dbo.dim_camera.")
        return {
            "camera_id": int(row[0]),
            "camera_name": str(row[1]),
            "camera_code": str(row[2]),
            "image_url": str(row[3]),
            "location_name": str(row[5]),
            "resort_name": str(row[6]),
            "timezone_name": str(row[7]) if row[7] else cfg.timezone_name,
        }


def get_last_db_row(cfg: Config, camera_id: int) -> Optional[Dict[str, Any]]:
    with get_db_connection(cfg) as conn:
        cur = conn.cursor()
        cur.execute(
            """
            SELECT TOP (1)
                observation_utc,
                current_depth_in,
                run_status
            FROM dbo.snowcam_observations
            WHERE camera_id = ?
            ORDER BY observation_utc DESC
            """,
            camera_id,
        )
        row = cur.fetchone()
        if not row:
            return None
        return {
            "observation_utc": row[0],
            "current_depth_in": float(row[1]) if row[1] is not None else None,
            "run_status": str(row[2]),
        }


def should_insert_success(cfg: Config, report: Dict[str, Any], last_db_row: Optional[Dict[str, Any]]) -> bool:
    if last_db_row is None:
        return True

    current_depth = report["current_depth_in"]
    previous_depth = last_db_row.get("current_depth_in")
    depth_changed = False
    if previous_depth is None:
        depth_changed = current_depth is not None
    elif current_depth is not None:
        depth_changed = abs(float(current_depth) - float(previous_depth)) >= cfg.change_epsilon_in

    if depth_changed:
        return True
    if float(report.get("interval_snowfall_in", 0.0)) > 0:
        return True
    if bool(report.get("stake_cleared", False)):
        return True

    last_obs = last_db_row.get("observation_utc")
    if isinstance(last_obs, datetime):
        now_dt = utc_iso_to_datetime(report["timestamp_utc"])
        if now_dt - last_obs >= timedelta(hours=cfg.heartbeat_hours):
            return True
    return False


def insert_db_row(cfg: Config, payload: Dict[str, Any], camera_ctx: Dict[str, Any]) -> None:
    with get_db_connection(cfg) as conn:
        cur = conn.cursor()
        cur.execute(
            """
            INSERT INTO dbo.snowcam_observations
            (
                observation_utc,
                camera_id,
                resort_name,
                location_name,
                camera_name,
                image_url,
                current_depth_in,
                delta_in,
                interval_snowfall_in,
                today_snowfall_total_in,
                yesterday_snowfall_total_in,
                stake_cleared,
                confidence,
                visibility,
                notes,
                run_status,
                error_message
            )
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            """,
            utc_iso_to_datetime(payload["timestamp_utc"]),
            # camera_id is the canonical relational key for observations.
            camera_ctx["camera_id"],
            camera_ctx["resort_name"],
            camera_ctx["location_name"],
            camera_ctx["camera_name"],
            camera_ctx["image_url"],
            payload.get("current_depth_in"),
            payload.get("delta_in"),
            payload.get("interval_snowfall_in"),
            payload.get("today_snowfall_total_in"),
            payload.get("yesterday_snowfall_total_in"),
            1 if payload.get("stake_cleared", False) else 0,
            payload.get("confidence"),
            payload.get("visibility"),
            payload.get("notes"),
            payload.get("run_status", "success"),
            payload.get("error_message"),
        )
        conn.commit()


def maybe_log_report_to_db(
    cfg: Config, report: Dict[str, Any], db_schema_ready: bool, camera_ctx: Dict[str, Any]
) -> str:
    if not cfg.db_enabled:
        return "disabled"
    if not db_schema_ready:
        return "schema_missing"
    try:
        last = get_last_db_row(cfg, camera_ctx["camera_id"])
        if should_insert_success(cfg, report, last):
            insert_db_row(cfg, report, camera_ctx)
            return "inserted"
        return "skipped_no_change"
    except Exception as exc:
        return f"db_error:{exc}"


def log_error_to_db(
    cfg: Config,
    timestamp_utc: str,
    error_message: str,
    db_schema_ready: bool,
    camera_ctx: Dict[str, Any],
) -> str:
    if not cfg.db_enabled:
        return "disabled"
    if not db_schema_ready:
        return "schema_missing"
    payload = {
        "timestamp_utc": timestamp_utc,
        "current_depth_in": None,
        "delta_in": None,
        "interval_snowfall_in": None,
        "today_snowfall_total_in": None,
        "yesterday_snowfall_total_in": None,
        "stake_cleared": False,
        "confidence": None,
        "visibility": "unknown",
        "notes": "",
        "run_status": "error",
        "error_message": error_message[:2000],
    }
    try:
        insert_db_row(cfg, payload, camera_ctx)
        return "inserted_error"
    except Exception as exc:
        return f"db_error:{exc}"


def write_daily_checkpoint(
    history: List[Dict[str, Any]],
    timezone_name: str,
    paths: Dict[str, Path],
    local_today: date,
    local_yesterday: date,
    timestamp_utc: str,
) -> None:
    # Writes one file per completed local day for quick audit/checkpointing.
    yesterday_key = local_yesterday.isoformat()
    yesterday_count = count_for_date(history, yesterday_key, timezone_name)
    if yesterday_count == 0:
        return

    checkpoint_path = paths["daily_summary_dir"] / f"{yesterday_key}.json"
    if checkpoint_path.exists():
        return

    payload = {
        "summary_date": yesterday_key,
        "resort_timezone": timezone_name,
        "final_snowfall_total_in": total_for_date(history, yesterday_key, timezone_name),
        "observation_count": yesterday_count,
        "generated_at_utc": timestamp_utc,
    }
    checkpoint_path.write_text(json.dumps(payload, indent=2), encoding="utf-8")


def read_email_state(path: Path) -> Dict[str, Any]:
    if not path.exists():
        return {}
    try:
        return json.loads(path.read_text(encoding="utf-8"))
    except Exception:
        return {}


def write_email_state(path: Path, state: Dict[str, Any]) -> None:
    path.write_text(json.dumps(state, indent=2), encoding="utf-8")


def maybe_send_error_email(
    cfg: Config,
    paths: Dict[str, Path],
    subject: str,
    body: str,
    timestamp_utc: str,
) -> str:
    if not cfg.alert_email_enabled:
        return "disabled"
    if not (cfg.alert_email_to and cfg.alert_email_from and cfg.smtp_host):
        return "misconfigured"

    state = read_email_state(paths["email_state"])
    last_sent_utc = state.get("last_sent_utc")
    if last_sent_utc:
        # Cooldown avoids spamming inboxes when the same error repeats.
        last_dt = utc_iso_to_datetime(last_sent_utc)
        now_dt = utc_iso_to_datetime(timestamp_utc)
        if now_dt - last_dt < timedelta(minutes=cfg.alert_cooldown_minutes):
            return "cooldown_skipped"

    msg = EmailMessage()
    msg["Subject"] = f"{cfg.alert_subject_prefix}: {subject}"
    msg["From"] = cfg.alert_email_from
    msg["To"] = cfg.alert_email_to
    msg.set_content(body)

    with smtplib.SMTP(cfg.smtp_host, cfg.smtp_port, timeout=30) as server:
        if cfg.smtp_starttls:
            server.starttls()
        if cfg.smtp_username:
            server.login(cfg.smtp_username, cfg.smtp_password)
        server.send_message(msg)

    write_email_state(paths["email_state"], {"last_sent_utc": timestamp_utc})
    return "sent"


def run_once(
    cfg: Config,
    paths: Dict[str, Path],
    logger: logging.Logger,
    camera_ctx: Dict[str, Any],
) -> Dict[str, Any]:
    history = load_history(paths["history"])
    previous_depth = float(history[-1]["current_depth_in"]) if history else None
    previous_image = paths["last_image"].read_bytes() if paths["last_image"].exists() else None

    current_image = with_retry(
        "image_fetch",
        cfg.fetch_retry_attempts,
        cfg.retry_delay_seconds,
        lambda: fetch_image(camera_ctx["image_url"], cfg.image_verify_tls),
        logger,
    )
    model_result = with_retry(
        "vertex_analysis",
        cfg.vertex_retry_attempts,
        cfg.retry_delay_seconds,
        lambda: analyze_with_vertex(cfg, current_image, previous_image),
        logger,
    )

    metrics = compute_interval_snowfall(
        current_depth_in=model_result["current_depth_in"],
        previous_depth_in=previous_depth,
        min_increment_in=cfg.min_increment_in,
        clear_drop_threshold_in=cfg.clear_drop_threshold_in,
    )

    timestamp = now_utc_iso()
    report_timezone = camera_ctx.get("timezone_name", cfg.timezone_name)
    local_today = datetime.now(get_timezone(report_timezone)).date()
    local_yesterday = local_today - timedelta(days=1)

    row = {
        "timestamp_utc": timestamp,
        "image_url": camera_ctx["image_url"],
        "current_depth_in": round(model_result["current_depth_in"], 2),
        "confidence": round(model_result["confidence"], 3),
        "visibility": model_result["visibility"],
        "notes": model_result["notes"],
        "delta_in": round(metrics["delta_in"], 2),
        "interval_snowfall_in": metrics["interval_snowfall_in"],
        "stake_cleared": metrics["stake_cleared"],
    }

    history.append(row)
    save_history(paths["history"], history)
    paths["last_image"].write_bytes(current_image)

    today_total = total_for_date(history, local_today.isoformat(), report_timezone)
    yesterday_total = total_for_date(history, local_yesterday.isoformat(), report_timezone)

    write_daily_checkpoint(history, report_timezone, paths, local_today, local_yesterday, timestamp)

    report = {
        "timestamp_utc": timestamp,
        "resort_timezone": report_timezone,
        "current_depth_in": row["current_depth_in"],
        "delta_in": row["delta_in"],
        "interval_snowfall_in": row["interval_snowfall_in"],
        "today_snowfall_total_in": today_total,
        "yesterday_snowfall_total_in": yesterday_total,
        "stake_cleared": row["stake_cleared"],
        "confidence": row["confidence"],
        "visibility": row["visibility"],
        "notes": row["notes"],
        "run_status": "success",
        "error_message": None,
    }
    paths["latest_report"].write_text(json.dumps(report, indent=2), encoding="utf-8")
    return report


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description="Snow stake reporter using Vertex AI.")
    parser.add_argument("--once", action="store_true", help="Run one cycle and exit.")
    parser.add_argument(
        "--interval-minutes",
        type=int,
        default=30,
        help="Polling interval in minutes for loop mode.",
    )
    parser.add_argument(
        "--data-dir",
        default="data",
        help="Directory for local state and latest report JSON.",
    )
    return parser.parse_args()


def run_cycle(
    cfg: Config,
    paths: Dict[str, Path],
    logger: logging.Logger,
    db_schema_ready: bool,
    camera_ctx: Dict[str, Any],
) -> None:
    try:
        report = run_once(cfg, paths, logger, camera_ctx)
        db_status = maybe_log_report_to_db(cfg, report, db_schema_ready, camera_ctx)
        report["db_log_status"] = db_status

        msg = json.dumps(report, indent=2)
        print(msg)
        logger.info(msg)

        if db_status.startswith("db_error"):
            email_status = maybe_send_error_email(
                cfg,
                paths,
                "Database logging failure",
                f"Timestamp: {report['timestamp_utc']}\n\n{db_status}",
                report["timestamp_utc"],
            )
            logger.warning("Error email status: %s", email_status)
    except Exception as exc:
        timestamp = now_utc_iso()
        db_status = log_error_to_db(cfg, timestamp, str(exc), db_schema_ready, camera_ctx)
        payload = {
            "error": str(exc),
            "timestamp_utc": timestamp,
            "db_log_status": db_status,
        }
        msg = json.dumps(payload, indent=2)
        print(msg)
        logger.error(msg)

        email_status = maybe_send_error_email(
            cfg,
            paths,
            "Snow reporter run failed",
            f"Timestamp: {timestamp}\n\nError: {exc}\n\nDB status: {db_status}",
            timestamp,
        )
        logger.warning("Error email status: %s", email_status)


def main() -> None:
    if sys.version_info < (3, 10):
        raise RuntimeError("Python 3.10+ is required.")

    load_dotenv()
    args = parse_args()
    cfg = load_config(args)
    paths = ensure_data_paths(cfg.data_dir)
    logger = setup_logger(paths["log_file"])

    db_schema_ready = check_db_schema(cfg, logger)
    camera_ctx: Dict[str, Any] = {
        "camera_id": -1,
        "camera_name": "unknown",
        "camera_code": cfg.camera_code,
        "image_url": cfg.image_url,
        "location_name": "unknown",
        "resort_name": "unknown",
        "timezone_name": cfg.timezone_name,
    }
    if cfg.db_enabled:
        camera_ctx = resolve_camera_context(cfg)
        logger.info(
            "Resolved camera_code=%s to camera_id=%s (%s / %s / %s)",
            camera_ctx["camera_code"],
            camera_ctx["camera_id"],
            camera_ctx["resort_name"],
            camera_ctx["location_name"],
            camera_ctx["camera_name"],
        )

    try:
        with FileLock(paths["lock_file"], cfg.lock_stale_minutes):
            if args.once:
                run_cycle(cfg, paths, logger, db_schema_ready, camera_ctx)
                return

            while True:
                run_cycle(cfg, paths, logger, db_schema_ready, camera_ctx)
                time.sleep(cfg.interval_minutes * 60)
    except RuntimeError as exc:
        payload = {"error": str(exc), "timestamp_utc": now_utc_iso(), "run_status": "skipped"}
        msg = json.dumps(payload, indent=2)
        print(msg)
        logger.warning(msg)


if __name__ == "__main__":
    main()
