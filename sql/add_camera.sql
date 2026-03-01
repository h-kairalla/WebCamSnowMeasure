SET NOCOUNT ON;
GO

/*
Usage example:
sqlcmd -S <server> -d ExampleDB -U <user> -P <password> ^
  -v RESORT_CODE="EXM" RESORT_NAME="Example Resort" TIMEZONE_NAME="America/Denver" ^
     LOCATION_CODE="SNOWSTAKE1" LOCATION_NAME="Main Mountain Snow Stake" ELEVATION_FT="0" ^
     CAMERA_CODE="EXM-CAM1" CAMERA_NAME="example_snowstake1" ^
     IMAGE_URL="https://example.com/cam-images/example_snowstake1.jpg" ^
     POLL_INTERVAL_MINUTES="30" ^
     CROP_X="" CROP_Y="" CROP_W="" CROP_H="" ^
     MODEL_NOTES="" ^
  -i sql\add_camera.sql
*/

DECLARE @resort_code NVARCHAR(20) = N'$(RESORT_CODE)';
DECLARE @resort_name NVARCHAR(100) = N'$(RESORT_NAME)';
DECLARE @timezone_name NVARCHAR(64) = N'$(TIMEZONE_NAME)';
DECLARE @location_code NVARCHAR(40) = N'$(LOCATION_CODE)';
DECLARE @location_name NVARCHAR(150) = N'$(LOCATION_NAME)';
DECLARE @camera_code NVARCHAR(60) = N'$(CAMERA_CODE)';
DECLARE @camera_name NVARCHAR(100) = N'$(CAMERA_NAME)';
DECLARE @image_url NVARCHAR(500) = N'$(IMAGE_URL)';
DECLARE @poll_interval_minutes INT = TRY_CAST('$(POLL_INTERVAL_MINUTES)' AS INT);
DECLARE @elevation_ft INT = TRY_CAST('$(ELEVATION_FT)' AS INT);
DECLARE @crop_x INT = TRY_CAST(NULLIF('$(CROP_X)', '') AS INT);
DECLARE @crop_y INT = TRY_CAST(NULLIF('$(CROP_Y)', '') AS INT);
DECLARE @crop_w INT = TRY_CAST(NULLIF('$(CROP_W)', '') AS INT);
DECLARE @crop_h INT = TRY_CAST(NULLIF('$(CROP_H)', '') AS INT);
DECLARE @model_notes NVARCHAR(1000) = NULLIF(N'$(MODEL_NOTES)', N'');

IF @poll_interval_minutes IS NULL
    SET @poll_interval_minutes = 30;

IF NULLIF(@resort_code, N'') IS NULL OR NULLIF(@location_code, N'') IS NULL OR NULLIF(@camera_code, N'') IS NULL
BEGIN
    THROW 50000, 'RESORT_CODE, LOCATION_CODE, and CAMERA_CODE are required.', 1;
END;

IF NULLIF(@resort_name, N'') IS NULL
    SET @resort_name = @resort_code;
IF NULLIF(@timezone_name, N'') IS NULL
    SET @timezone_name = N'America/Denver';
IF NULLIF(@location_name, N'') IS NULL
    SET @location_name = @location_code;
IF NULLIF(@camera_name, N'') IS NULL
    SET @camera_name = @camera_code;
IF NULLIF(@image_url, N'') IS NULL
BEGIN
    THROW 50001, 'IMAGE_URL is required.', 1;
END;

DECLARE @resort_id BIGINT;
DECLARE @location_id BIGINT;

SELECT @resort_id = resort_id FROM dbo.dim_resort WHERE resort_code = @resort_code;
IF @resort_id IS NULL
BEGIN
    INSERT INTO dbo.dim_resort(resort_code, resort_name, timezone_name, is_active)
    VALUES (@resort_code, @resort_name, @timezone_name, 1);
    SET @resort_id = SCOPE_IDENTITY();
END
ELSE
BEGIN
    UPDATE dbo.dim_resort
    SET resort_name = @resort_name,
        timezone_name = @timezone_name,
        is_active = 1
    WHERE resort_id = @resort_id;
END;

SELECT @location_id = location_id
FROM dbo.dim_location
WHERE resort_id = @resort_id
  AND location_code = @location_code;

IF @location_id IS NULL
BEGIN
    INSERT INTO dbo.dim_location(resort_id, location_code, location_name, elevation_ft, is_active)
    VALUES (@resort_id, @location_code, @location_name, @elevation_ft, 1);
    SET @location_id = SCOPE_IDENTITY();
END
ELSE
BEGIN
    UPDATE dbo.dim_location
    SET location_name = @location_name,
        elevation_ft = @elevation_ft,
        is_active = 1
    WHERE location_id = @location_id;
END;

DECLARE @has_crop_columns BIT = CASE
    WHEN COL_LENGTH('dbo.dim_camera', 'crop_x') IS NOT NULL
      AND COL_LENGTH('dbo.dim_camera', 'crop_y') IS NOT NULL
      AND COL_LENGTH('dbo.dim_camera', 'crop_w') IS NOT NULL
      AND COL_LENGTH('dbo.dim_camera', 'crop_h') IS NOT NULL
    THEN 1 ELSE 0 END;
DECLARE @has_model_notes_column BIT = CASE
    WHEN COL_LENGTH('dbo.dim_camera', 'model_notes') IS NOT NULL
    THEN 1 ELSE 0 END;

IF NOT EXISTS (SELECT 1 FROM dbo.dim_camera WHERE camera_code = @camera_code)
BEGIN
    IF @has_crop_columns = 1
    BEGIN
        INSERT INTO dbo.dim_camera
        (
            location_id,
            camera_code,
            camera_name,
            image_url,
            poll_interval_minutes,
            crop_x,
            crop_y,
            crop_w,
            crop_h,
            is_active
        )
        VALUES
        (
            @location_id,
            @camera_code,
            @camera_name,
            @image_url,
            @poll_interval_minutes,
            @crop_x,
            @crop_y,
            @crop_w,
            @crop_h,
            1
        );
    END
    ELSE
    BEGIN
        INSERT INTO dbo.dim_camera
        (
            location_id,
            camera_code,
            camera_name,
            image_url,
            poll_interval_minutes,
            is_active
        )
        VALUES
        (
            @location_id,
            @camera_code,
            @camera_name,
            @image_url,
            @poll_interval_minutes,
            1
        );
    END
END
ELSE
BEGIN
    IF @has_crop_columns = 1
    BEGIN
        UPDATE dbo.dim_camera
        SET location_id = @location_id,
            camera_name = @camera_name,
            image_url = @image_url,
            poll_interval_minutes = @poll_interval_minutes,
            crop_x = @crop_x,
            crop_y = @crop_y,
            crop_w = @crop_w,
            crop_h = @crop_h,
            is_active = 1
        WHERE camera_code = @camera_code;
    END
    ELSE
    BEGIN
        UPDATE dbo.dim_camera
        SET location_id = @location_id,
            camera_name = @camera_name,
            image_url = @image_url,
            poll_interval_minutes = @poll_interval_minutes,
            is_active = 1
        WHERE camera_code = @camera_code;
    END
END;

IF @has_model_notes_column = 1
BEGIN
    UPDATE dbo.dim_camera
    SET model_notes = @model_notes
    WHERE camera_code = @camera_code;
END

IF @has_crop_columns = 1 AND @has_model_notes_column = 1
BEGIN
    SELECT
        r.resort_code,
        r.resort_name,
        l.location_code,
        l.location_name,
        c.camera_code,
        c.camera_name,
        c.image_url,
        c.poll_interval_minutes,
        c.crop_x,
        c.crop_y,
        c.crop_w,
        c.crop_h,
        c.model_notes,
        c.is_active
    FROM dbo.dim_camera c
    JOIN dbo.dim_location l ON c.location_id = l.location_id
    JOIN dbo.dim_resort r ON l.resort_id = r.resort_id
    WHERE c.camera_code = @camera_code;
END
ELSE IF @has_crop_columns = 1
BEGIN
    SELECT
        r.resort_code,
        r.resort_name,
        l.location_code,
        l.location_name,
        c.camera_code,
        c.camera_name,
        c.image_url,
        c.poll_interval_minutes,
        c.crop_x,
        c.crop_y,
        c.crop_w,
        c.crop_h,
        c.is_active
    FROM dbo.dim_camera c
    JOIN dbo.dim_location l ON c.location_id = l.location_id
    JOIN dbo.dim_resort r ON l.resort_id = r.resort_id
    WHERE c.camera_code = @camera_code;
END
ELSE IF @has_model_notes_column = 1
BEGIN
    SELECT
        r.resort_code,
        r.resort_name,
        l.location_code,
        l.location_name,
        c.camera_code,
        c.camera_name,
        c.image_url,
        c.poll_interval_minutes,
        c.model_notes,
        c.is_active
    FROM dbo.dim_camera c
    JOIN dbo.dim_location l ON c.location_id = l.location_id
    JOIN dbo.dim_resort r ON l.resort_id = r.resort_id
    WHERE c.camera_code = @camera_code;
END
ELSE
BEGIN
    SELECT
        r.resort_code,
        r.resort_name,
        l.location_code,
        l.location_name,
        c.camera_code,
        c.camera_name,
        c.image_url,
        c.poll_interval_minutes,
        c.is_active
    FROM dbo.dim_camera c
    JOIN dbo.dim_location l ON c.location_id = l.location_id
    JOIN dbo.dim_resort r ON l.resort_id = r.resort_id
    WHERE c.camera_code = @camera_code;
END
