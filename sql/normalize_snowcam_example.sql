SET NOCOUNT ON;
GO

/* 1) Dimension tables */
IF OBJECT_ID('dbo.dim_resort', 'U') IS NULL
BEGIN
    CREATE TABLE dbo.dim_resort
    (
        resort_id BIGINT IDENTITY(1,1) NOT NULL PRIMARY KEY,
        resort_code NVARCHAR(20) NOT NULL,
        resort_name NVARCHAR(100) NOT NULL,
        timezone_name NVARCHAR(64) NOT NULL,
        is_active BIT NOT NULL CONSTRAINT DF_dim_resort_is_active DEFAULT (1),
        created_at DATETIME2(0) NOT NULL CONSTRAINT DF_dim_resort_created_at DEFAULT (SYSUTCDATETIME())
    );
END
GO

IF NOT EXISTS (
    SELECT 1 FROM sys.indexes
    WHERE object_id = OBJECT_ID('dbo.dim_resort') AND name = 'UX_dim_resort_resort_code'
)
BEGIN
    CREATE UNIQUE INDEX UX_dim_resort_resort_code ON dbo.dim_resort(resort_code);
END
GO

IF OBJECT_ID('dbo.dim_location', 'U') IS NULL
BEGIN
    CREATE TABLE dbo.dim_location
    (
        location_id BIGINT IDENTITY(1,1) NOT NULL PRIMARY KEY,
        resort_id BIGINT NOT NULL,
        location_code NVARCHAR(40) NOT NULL,
        location_name NVARCHAR(150) NOT NULL,
        elevation_ft INT NULL,
        is_active BIT NOT NULL CONSTRAINT DF_dim_location_is_active DEFAULT (1),
        created_at DATETIME2(0) NOT NULL CONSTRAINT DF_dim_location_created_at DEFAULT (SYSUTCDATETIME())
    );
END
GO

IF NOT EXISTS (
    SELECT 1 FROM sys.foreign_keys WHERE name = 'FK_dim_location_resort'
)
BEGIN
    ALTER TABLE dbo.dim_location
    ADD CONSTRAINT FK_dim_location_resort
    FOREIGN KEY (resort_id) REFERENCES dbo.dim_resort(resort_id);
END
GO

IF NOT EXISTS (
    SELECT 1 FROM sys.indexes
    WHERE object_id = OBJECT_ID('dbo.dim_location') AND name = 'UX_dim_location_resort_location_code'
)
BEGIN
    CREATE UNIQUE INDEX UX_dim_location_resort_location_code
    ON dbo.dim_location(resort_id, location_code);
END
GO

IF OBJECT_ID('dbo.dim_camera', 'U') IS NULL
BEGIN
    CREATE TABLE dbo.dim_camera
    (
        camera_id BIGINT IDENTITY(1,1) NOT NULL PRIMARY KEY,
        location_id BIGINT NOT NULL,
        camera_code NVARCHAR(60) NOT NULL,
        camera_name NVARCHAR(100) NOT NULL,
        image_url NVARCHAR(500) NOT NULL,
        poll_interval_minutes INT NOT NULL CONSTRAINT DF_dim_camera_poll_interval DEFAULT (30),
        is_active BIT NOT NULL CONSTRAINT DF_dim_camera_is_active DEFAULT (1),
        created_at DATETIME2(0) NOT NULL CONSTRAINT DF_dim_camera_created_at DEFAULT (SYSUTCDATETIME())
    );
END
GO

IF NOT EXISTS (
    SELECT 1 FROM sys.foreign_keys WHERE name = 'FK_dim_camera_location'
)
BEGIN
    ALTER TABLE dbo.dim_camera
    ADD CONSTRAINT FK_dim_camera_location
    FOREIGN KEY (location_id) REFERENCES dbo.dim_location(location_id);
END
GO

IF NOT EXISTS (
    SELECT 1 FROM sys.indexes
    WHERE object_id = OBJECT_ID('dbo.dim_camera') AND name = 'UX_dim_camera_camera_code'
)
BEGIN
    CREATE UNIQUE INDEX UX_dim_camera_camera_code ON dbo.dim_camera(camera_code);
END
GO

/* 2) Seed initial example dimension rows */
DECLARE @resort_id BIGINT;
DECLARE @location_id BIGINT;

SELECT @resort_id = resort_id FROM dbo.dim_resort WHERE resort_code = N'EXM';
IF @resort_id IS NULL
BEGIN
    INSERT INTO dbo.dim_resort (resort_code, resort_name, timezone_name, is_active)
    VALUES (N'EXM', N'Example Resort', N'America/Denver', 1);
    SET @resort_id = SCOPE_IDENTITY();
END
ELSE
BEGIN
    UPDATE dbo.dim_resort
    SET resort_name = N'Example Resort', timezone_name = N'America/Denver', is_active = 1
    WHERE resort_id = @resort_id;
END

SELECT @location_id = location_id
FROM dbo.dim_location
WHERE resort_id = @resort_id AND location_code = N'SNOWSTAKE1';

IF @location_id IS NULL
BEGIN
    INSERT INTO dbo.dim_location (resort_id, location_code, location_name, elevation_ft, is_active)
    VALUES (@resort_id, N'SNOWSTAKE1', N'Main Mountain Snow Stake', NULL, 1);
    SET @location_id = SCOPE_IDENTITY();
END
ELSE
BEGIN
    UPDATE dbo.dim_location
    SET location_name = N'Main Mountain Snow Stake', is_active = 1
    WHERE location_id = @location_id;
END

IF NOT EXISTS (SELECT 1 FROM dbo.dim_camera WHERE camera_code = N'EXM-CAM1')
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
        N'EXM-CAM1',
        N'example_snowstake1',
        N'https://example.com/cam-images/example_snowstake1.jpg',
        30,
        1
    );
END
ELSE
BEGIN
    UPDATE dbo.dim_camera
    SET location_id = @location_id,
        camera_name = N'example_snowstake1',
        image_url = N'https://example.com/cam-images/example_snowstake1.jpg',
        poll_interval_minutes = 30,
        is_active = 1
    WHERE camera_code = N'EXM-CAM1';
END
GO

/* 3) Fact table changes */
IF COL_LENGTH('dbo.snowcam_observations', 'camera_id') IS NULL
BEGIN
    ALTER TABLE dbo.snowcam_observations ADD camera_id BIGINT NULL;
END
GO

DECLARE @seed_camera_id BIGINT;
SELECT @seed_camera_id = camera_id FROM dbo.dim_camera WHERE camera_code = N'EXM-CAM1';

UPDATE so
SET so.camera_id = dc.camera_id
FROM dbo.snowcam_observations so
JOIN dbo.dim_camera dc ON dc.camera_name = so.camera_name
JOIN dbo.dim_location dl ON dl.location_id = dc.location_id AND dl.location_name = so.location_name
JOIN dbo.dim_resort dr ON dr.resort_id = dl.resort_id AND dr.resort_name = so.resort_name
WHERE so.camera_id IS NULL;

UPDATE dbo.snowcam_observations
SET camera_id = @seed_camera_id
WHERE camera_id IS NULL;
GO

IF EXISTS (
    SELECT 1 FROM sys.columns
    WHERE object_id = OBJECT_ID('dbo.snowcam_observations')
      AND name = 'camera_id'
      AND is_nullable = 1
)
BEGIN
    ALTER TABLE dbo.snowcam_observations ALTER COLUMN camera_id BIGINT NOT NULL;
END
GO

IF NOT EXISTS (
    SELECT 1 FROM sys.foreign_keys WHERE name = 'FK_snowcam_observations_camera'
)
BEGIN
    ALTER TABLE dbo.snowcam_observations
    ADD CONSTRAINT FK_snowcam_observations_camera
    FOREIGN KEY (camera_id) REFERENCES dbo.dim_camera(camera_id);
END
GO

IF NOT EXISTS (
    SELECT 1 FROM sys.indexes
    WHERE object_id = OBJECT_ID('dbo.snowcam_observations')
      AND name = 'IX_snowcam_observations_camera_observation_utc'
)
BEGIN
    CREATE INDEX IX_snowcam_observations_camera_observation_utc
    ON dbo.snowcam_observations(camera_id, observation_utc DESC);
END
GO

/* 4) Rebuild normalized view */
IF OBJECT_ID('dbo.vw_snowcam_daily_totals', 'V') IS NOT NULL
    DROP VIEW dbo.vw_snowcam_daily_totals;
GO

CREATE VIEW dbo.vw_snowcam_daily_totals
AS
SELECT
    dr.resort_code,
    dr.resort_name,
    dl.location_code,
    dl.location_name,
    dc.camera_code,
    dc.camera_name,
    CAST(so.observation_utc AS DATE) AS observation_date_utc,
    MAX(so.observation_utc) AS latest_observation_utc,
    SUM(COALESCE(so.interval_snowfall_in, 0)) AS total_snowfall_in,
    MAX(so.current_depth_in) AS latest_depth_in,
    MAX(so.today_snowfall_total_in) AS latest_today_total_in,
    MAX(so.yesterday_snowfall_total_in) AS latest_yesterday_total_in
FROM dbo.snowcam_observations so
JOIN dbo.dim_camera dc ON so.camera_id = dc.camera_id
JOIN dbo.dim_location dl ON dc.location_id = dl.location_id
JOIN dbo.dim_resort dr ON dl.resort_id = dr.resort_id
WHERE so.run_status = 'success'
GROUP BY
    dr.resort_code,
    dr.resort_name,
    dl.location_code,
    dl.location_name,
    dc.camera_code,
    dc.camera_name,
    CAST(so.observation_utc AS DATE);
GO

/* 5) Extended property upsert helper */
CREATE OR ALTER PROCEDURE dbo.usp_upsert_extended_property
    @name SYSNAME,
    @value SQL_VARIANT,
    @level0type NVARCHAR(128),
    @level0name SYSNAME,
    @level1type NVARCHAR(128),
    @level1name SYSNAME,
    @level2type NVARCHAR(128) = NULL,
    @level2name SYSNAME = NULL
AS
BEGIN
    SET NOCOUNT ON;
    BEGIN TRY
        EXEC sys.sp_updateextendedproperty
            @name = @name,
            @value = @value,
            @level0type = @level0type,
            @level0name = @level0name,
            @level1type = @level1type,
            @level1name = @level1name,
            @level2type = @level2type,
            @level2name = @level2name;
    END TRY
    BEGIN CATCH
        EXEC sys.sp_addextendedproperty
            @name = @name,
            @value = @value,
            @level0type = @level0type,
            @level0name = @level0name,
            @level1type = @level1type,
            @level1name = @level1name,
            @level2type = @level2type,
            @level2name = @level2name;
    END CATCH
END
GO

/* 6) Extended properties for new/updated objects */
EXEC dbo.usp_upsert_extended_property N'MS_Description', N'Resort dimension table.', N'SCHEMA', N'dbo', N'TABLE', N'dim_resort', NULL, NULL;
EXEC dbo.usp_upsert_extended_property N'MS_Description', N'Location dimension table under each resort.', N'SCHEMA', N'dbo', N'TABLE', N'dim_location', NULL, NULL;
EXEC dbo.usp_upsert_extended_property N'MS_Description', N'Camera dimension table under each location.', N'SCHEMA', N'dbo', N'TABLE', N'dim_camera', NULL, NULL;
EXEC dbo.usp_upsert_extended_property N'MS_Description', N'Normalized snowcam fact table keyed by camera_id.', N'SCHEMA', N'dbo', N'TABLE', N'snowcam_observations', NULL, NULL;
EXEC dbo.usp_upsert_extended_property N'MS_Description', N'Daily snowcam totals with resort/location/camera dimensions.', N'SCHEMA', N'dbo', N'VIEW', N'vw_snowcam_daily_totals', NULL, NULL;

EXEC dbo.usp_upsert_extended_property N'MS_Description', N'Unique short code for resort.', N'SCHEMA', N'dbo', N'TABLE', N'dim_resort', N'COLUMN', N'resort_code';
EXEC dbo.usp_upsert_extended_property N'MS_Description', N'Unique short code for location within a resort.', N'SCHEMA', N'dbo', N'TABLE', N'dim_location', N'COLUMN', N'location_code';
EXEC dbo.usp_upsert_extended_property N'MS_Description', N'Global unique code for camera/feed.', N'SCHEMA', N'dbo', N'TABLE', N'dim_camera', N'COLUMN', N'camera_code';
EXEC dbo.usp_upsert_extended_property N'MS_Description', N'Foreign key to dbo.dim_camera.', N'SCHEMA', N'dbo', N'TABLE', N'snowcam_observations', N'COLUMN', N'camera_id';
GO

/* 7) catalog.objects upsert */
DECLARE @obj_dim_resort INT, @obj_dim_location INT, @obj_dim_camera INT, @obj_fact INT, @obj_view INT;
DECLARE @next_object_id INT;

SELECT @obj_dim_resort = object_id FROM catalog.objects WHERE schema_name = N'dbo' AND object_name = N'dim_resort';
SELECT @obj_dim_location = object_id FROM catalog.objects WHERE schema_name = N'dbo' AND object_name = N'dim_location';
SELECT @obj_dim_camera = object_id FROM catalog.objects WHERE schema_name = N'dbo' AND object_name = N'dim_camera';
SELECT @obj_fact = object_id FROM catalog.objects WHERE schema_name = N'dbo' AND object_name = N'snowcam_observations';
SELECT @obj_view = object_id FROM catalog.objects WHERE schema_name = N'dbo' AND object_name = N'vw_snowcam_daily_totals';

SELECT @next_object_id = ISNULL(MAX(object_id), 0) + 1 FROM catalog.objects;

IF @obj_dim_resort IS NULL
BEGIN
    SET @obj_dim_resort = @next_object_id;
    SET @next_object_id += 1;
    INSERT INTO catalog.objects(object_id, schema_name, object_name, object_type, description, grain, primary_key_columns, created_at, updated_at)
    VALUES(@obj_dim_resort, N'dbo', N'dim_resort', N'TABLE', N'Resort dimension for SnowCam.', N'One row per resort.', N'["resort_id"]', SYSUTCDATETIME(), SYSUTCDATETIME());
END
ELSE
BEGIN
    UPDATE catalog.objects
    SET object_type = N'TABLE',
        description = N'Resort dimension for SnowCam.',
        grain = N'One row per resort.',
        primary_key_columns = N'["resort_id"]',
        updated_at = SYSUTCDATETIME()
    WHERE object_id = @obj_dim_resort;
END

IF @obj_dim_location IS NULL
BEGIN
    SET @obj_dim_location = @next_object_id;
    SET @next_object_id += 1;
    INSERT INTO catalog.objects(object_id, schema_name, object_name, object_type, description, grain, primary_key_columns, created_at, updated_at)
    VALUES(@obj_dim_location, N'dbo', N'dim_location', N'TABLE', N'Location dimension for SnowCam under each resort.', N'One row per resort location.', N'["location_id"]', SYSUTCDATETIME(), SYSUTCDATETIME());
END
ELSE
BEGIN
    UPDATE catalog.objects
    SET object_type = N'TABLE',
        description = N'Location dimension for SnowCam under each resort.',
        grain = N'One row per resort location.',
        primary_key_columns = N'["location_id"]',
        updated_at = SYSUTCDATETIME()
    WHERE object_id = @obj_dim_location;
END

IF @obj_dim_camera IS NULL
BEGIN
    SET @obj_dim_camera = @next_object_id;
    SET @next_object_id += 1;
    INSERT INTO catalog.objects(object_id, schema_name, object_name, object_type, description, grain, primary_key_columns, created_at, updated_at)
    VALUES(@obj_dim_camera, N'dbo', N'dim_camera', N'TABLE', N'Camera dimension for SnowCam under each location.', N'One row per camera.', N'["camera_id"]', SYSUTCDATETIME(), SYSUTCDATETIME());
END
ELSE
BEGIN
    UPDATE catalog.objects
    SET object_type = N'TABLE',
        description = N'Camera dimension for SnowCam under each location.',
        grain = N'One row per camera.',
        primary_key_columns = N'["camera_id"]',
        updated_at = SYSUTCDATETIME()
    WHERE object_id = @obj_dim_camera;
END

IF @obj_fact IS NULL
BEGIN
    SET @obj_fact = @next_object_id;
    SET @next_object_id += 1;
    INSERT INTO catalog.objects(object_id, schema_name, object_name, object_type, description, grain, primary_key_columns, created_at, updated_at)
    VALUES(@obj_fact, N'dbo', N'snowcam_observations', N'TABLE', N'SnowCam fact table keyed by camera_id.', N'One row per camera observation timestamp.', N'["id"]', SYSUTCDATETIME(), SYSUTCDATETIME());
END
ELSE
BEGIN
    UPDATE catalog.objects
    SET object_type = N'TABLE',
        description = N'SnowCam fact table keyed by camera_id.',
        grain = N'One row per camera observation timestamp.',
        primary_key_columns = N'["id"]',
        updated_at = SYSUTCDATETIME()
    WHERE object_id = @obj_fact;
END

IF @obj_view IS NULL
BEGIN
    SET @obj_view = @next_object_id;
    SET @next_object_id += 1;
    INSERT INTO catalog.objects(object_id, schema_name, object_name, object_type, description, grain, primary_key_columns, created_at, updated_at)
    VALUES(@obj_view, N'dbo', N'vw_snowcam_daily_totals', N'VIEW', N'Daily SnowCam totals joined with resort/location/camera metadata.', N'One row per camera per UTC date.', NULL, SYSUTCDATETIME(), SYSUTCDATETIME());
END
ELSE
BEGIN
    UPDATE catalog.objects
    SET object_type = N'VIEW',
        description = N'Daily SnowCam totals joined with resort/location/camera metadata.',
        grain = N'One row per camera per UTC date.',
        primary_key_columns = NULL,
        updated_at = SYSUTCDATETIME()
    WHERE object_id = @obj_view;
END
GO

/* 8) catalog.columns upsert for normalized objects */
DECLARE @object_map TABLE(object_id INT, schema_name SYSNAME, object_name SYSNAME);
INSERT INTO @object_map(object_id, schema_name, object_name)
SELECT o.object_id, o.schema_name, o.object_name
FROM catalog.objects o
WHERE o.schema_name = N'dbo'
  AND o.object_name IN (N'dim_resort', N'dim_location', N'dim_camera', N'snowcam_observations', N'vw_snowcam_daily_totals');

;WITH src AS
(
    SELECT
        m.object_id,
        c.column_id AS source_column_id,
        c.name AS column_name,
        t.name AS data_type,
        c.max_length,
        c.precision,
        c.scale,
        c.is_nullable,
        CASE
            WHEN c.name IN (N'resort_id', N'location_id', N'camera_id', N'id') THEN 1
            WHEN c.name LIKE N'%_id' THEN 1
            WHEN c.name LIKE N'%_code' THEN 1
            ELSE 0
        END AS is_join_key,
        CASE WHEN pk.column_id IS NULL THEN 0 ELSE 1 END AS is_primary_key,
        ISNULL(pk.key_ordinal, 0) AS primary_key_ordinal
    FROM @object_map m
    JOIN sys.columns c ON c.object_id = OBJECT_ID(QUOTENAME(m.schema_name) + N'.' + QUOTENAME(m.object_name))
    JOIN sys.types t ON c.user_type_id = t.user_type_id
    LEFT JOIN
    (
        SELECT ic.object_id, ic.column_id, ic.key_ordinal
        FROM sys.indexes i
        JOIN sys.index_columns ic ON i.object_id = ic.object_id AND i.index_id = ic.index_id
        WHERE i.is_primary_key = 1
    ) pk ON pk.object_id = c.object_id AND pk.column_id = c.column_id
),
missing AS
(
    SELECT s.*
    FROM src s
    LEFT JOIN catalog.columns cc
      ON cc.object_id = s.object_id AND cc.column_name = s.column_name
    WHERE cc.column_id IS NULL
),
numbered_missing AS
(
    SELECT *, ROW_NUMBER() OVER (ORDER BY object_id, source_column_id) AS rn
    FROM missing
)
INSERT INTO catalog.columns
(
    column_id,
    object_id,
    column_name,
    data_type,
    max_length,
    precision,
    scale,
    is_nullable,
    description,
    example_values,
    semantic_tags,
    is_join_key,
    is_primary_key,
    primary_key_ordinal
)
SELECT
    (SELECT ISNULL(MAX(column_id), 0) FROM catalog.columns) + rn,
    object_id,
    column_name,
    data_type,
    max_length,
    precision,
    scale,
    is_nullable,
    NULL,
    NULL,
    N'[]',
    is_join_key,
    is_primary_key,
    primary_key_ordinal
FROM numbered_missing;

;WITH src AS
(
    SELECT
        m.object_id,
        c.name AS column_name,
        t.name AS data_type,
        c.max_length,
        c.precision,
        c.scale,
        c.is_nullable,
        CASE
            WHEN c.name IN (N'resort_id', N'location_id', N'camera_id', N'id') THEN 1
            WHEN c.name LIKE N'%_id' THEN 1
            WHEN c.name LIKE N'%_code' THEN 1
            ELSE 0
        END AS is_join_key,
        CASE WHEN pk.column_id IS NULL THEN 0 ELSE 1 END AS is_primary_key,
        ISNULL(pk.key_ordinal, 0) AS primary_key_ordinal
    FROM @object_map m
    JOIN sys.columns c ON c.object_id = OBJECT_ID(QUOTENAME(m.schema_name) + N'.' + QUOTENAME(m.object_name))
    JOIN sys.types t ON c.user_type_id = t.user_type_id
    LEFT JOIN
    (
        SELECT ic.object_id, ic.column_id, ic.key_ordinal
        FROM sys.indexes i
        JOIN sys.index_columns ic ON i.object_id = ic.object_id AND i.index_id = ic.index_id
        WHERE i.is_primary_key = 1
    ) pk ON pk.object_id = c.object_id AND pk.column_id = c.column_id
)
UPDATE cc
SET cc.data_type = s.data_type,
    cc.max_length = s.max_length,
    cc.precision = s.precision,
    cc.scale = s.scale,
    cc.is_nullable = s.is_nullable,
    cc.is_join_key = s.is_join_key,
    cc.is_primary_key = s.is_primary_key,
    cc.primary_key_ordinal = s.primary_key_ordinal,
    cc.description =
        CASE
            WHEN cc.column_name = N'camera_id' THEN N'Foreign key to camera dimension.'
            WHEN cc.column_name = N'camera_code' THEN N'Stable global camera key used by applications.'
            WHEN cc.column_name = N'location_code' THEN N'Stable location code within resort.'
            WHEN cc.column_name = N'resort_code' THEN N'Stable resort code.'
            WHEN cc.column_name = N'observation_utc' THEN N'Observation timestamp in UTC.'
            WHEN cc.column_name = N'interval_snowfall_in' THEN N'Snowfall attributed to this interval in inches.'
            WHEN cc.column_name = N'total_snowfall_in' THEN N'Daily total snowfall in inches.'
            ELSE ISNULL(cc.description, N'')
        END,
    cc.semantic_tags =
        CASE
            WHEN cc.column_name LIKE N'%_id' THEN N'["key","join_key"]'
            WHEN cc.column_name LIKE N'%_code' THEN N'["key","code"]'
            WHEN cc.column_name LIKE N'%_in' THEN N'["snow","measure"]'
            WHEN cc.column_name LIKE N'%_utc' THEN N'["timestamp","utc"]'
            ELSE ISNULL(NULLIF(cc.semantic_tags, N''), N'[]')
        END
FROM catalog.columns cc
JOIN src s ON s.object_id = cc.object_id AND s.column_name = cc.column_name;
GO

/* 9) catalog.relationships upsert */
DECLARE @rel_next_id INT;
SELECT @rel_next_id = ISNULL(MAX(relationship_id), 0) + 1 FROM catalog.relationships;

DECLARE @obj_resort INT = (SELECT object_id FROM catalog.objects WHERE schema_name = N'dbo' AND object_name = N'dim_resort');
DECLARE @obj_location INT = (SELECT object_id FROM catalog.objects WHERE schema_name = N'dbo' AND object_name = N'dim_location');
DECLARE @obj_camera INT = (SELECT object_id FROM catalog.objects WHERE schema_name = N'dbo' AND object_name = N'dim_camera');
DECLARE @obj_snowcam INT = (SELECT object_id FROM catalog.objects WHERE schema_name = N'dbo' AND object_name = N'snowcam_observations');

IF NOT EXISTS (
    SELECT 1 FROM catalog.relationships
    WHERE from_object_id = @obj_location AND from_column_name = N'resort_id'
      AND to_object_id = @obj_resort AND to_column_name = N'resort_id'
)
BEGIN
    INSERT INTO catalog.relationships
    (relationship_id, from_object_id, from_column_name, to_object_id, to_column_name, relationship_type, cardinality, notes)
    VALUES
    (@rel_next_id, @obj_location, N'resort_id', @obj_resort, N'resort_id', N'hard', N'many-to-one', N'Location belongs to one resort.');
    SET @rel_next_id += 1;
END

IF NOT EXISTS (
    SELECT 1 FROM catalog.relationships
    WHERE from_object_id = @obj_camera AND from_column_name = N'location_id'
      AND to_object_id = @obj_location AND to_column_name = N'location_id'
)
BEGIN
    INSERT INTO catalog.relationships
    (relationship_id, from_object_id, from_column_name, to_object_id, to_column_name, relationship_type, cardinality, notes)
    VALUES
    (@rel_next_id, @obj_camera, N'location_id', @obj_location, N'location_id', N'hard', N'many-to-one', N'Camera belongs to one location.');
    SET @rel_next_id += 1;
END

IF NOT EXISTS (
    SELECT 1 FROM catalog.relationships
    WHERE from_object_id = @obj_snowcam AND from_column_name = N'camera_id'
      AND to_object_id = @obj_camera AND to_column_name = N'camera_id'
)
BEGIN
    INSERT INTO catalog.relationships
    (relationship_id, from_object_id, from_column_name, to_object_id, to_column_name, relationship_type, cardinality, notes)
    VALUES
    (@rel_next_id, @obj_snowcam, N'camera_id', @obj_camera, N'camera_id', N'hard', N'many-to-one', N'Observation belongs to one camera.');
    SET @rel_next_id += 1;
END
GO

/* 10) catalog.metrics upsert */
DECLARE @metric_next_id INT;
SELECT @metric_next_id = ISNULL(MAX(metric_id), 0) + 1 FROM catalog.metrics;
DECLARE @snowcam_object_id NVARCHAR(50) = CAST((SELECT object_id FROM catalog.objects WHERE schema_name = N'dbo' AND object_name = N'snowcam_observations') AS NVARCHAR(50));
DECLARE @snowcam_view_id NVARCHAR(50) = CAST((SELECT object_id FROM catalog.objects WHERE schema_name = N'dbo' AND object_name = N'vw_snowcam_daily_totals') AS NVARCHAR(50));

IF NOT EXISTS (SELECT 1 FROM catalog.metrics WHERE metric_name = N'snowcam_daily_total_in')
BEGIN
    INSERT INTO catalog.metrics(metric_id, metric_name, description, formula_sql, source_object_ids, required_filters)
    VALUES
    (
        @metric_next_id,
        N'snowcam_daily_total_in',
        N'Daily total snowfall in inches by resort/location/camera.',
        N'SELECT resort_code, location_code, camera_code, observation_date_utc, total_snowfall_in FROM dbo.vw_snowcam_daily_totals',
        N'[' + @snowcam_view_id + N']',
        N'["observation_date_utc"]'
    );
    SET @metric_next_id += 1;
END

IF NOT EXISTS (SELECT 1 FROM catalog.metrics WHERE metric_name = N'snowcam_latest_depth_in')
BEGIN
    INSERT INTO catalog.metrics(metric_id, metric_name, description, formula_sql, source_object_ids, required_filters)
    VALUES
    (
        @metric_next_id,
        N'snowcam_latest_depth_in',
        N'Latest depth in inches by camera.',
        N'SELECT TOP 1 WITH TIES camera_id, current_depth_in, observation_utc FROM dbo.snowcam_observations WHERE run_status = ''success'' ORDER BY ROW_NUMBER() OVER (PARTITION BY camera_id ORDER BY observation_utc DESC)',
        N'[' + @snowcam_object_id + N']',
        N'[]'
    );
    SET @metric_next_id += 1;
END

IF NOT EXISTS (SELECT 1 FROM catalog.metrics WHERE metric_name = N'snowcam_data_freshness_minutes')
BEGIN
    INSERT INTO catalog.metrics(metric_id, metric_name, description, formula_sql, source_object_ids, required_filters)
    VALUES
    (
        @metric_next_id,
        N'snowcam_data_freshness_minutes',
        N'Age in minutes of latest observation per camera.',
        N'SELECT camera_id, DATEDIFF(minute, MAX(observation_utc), SYSUTCDATETIME()) AS freshness_minutes FROM dbo.snowcam_observations GROUP BY camera_id',
        N'[' + @snowcam_object_id + N']',
        N'[]'
    );
    SET @metric_next_id += 1;
END

IF NOT EXISTS (SELECT 1 FROM catalog.metrics WHERE metric_name = N'snowcam_error_rate_24h')
BEGIN
    INSERT INTO catalog.metrics(metric_id, metric_name, description, formula_sql, source_object_ids, required_filters)
    VALUES
    (
        @metric_next_id,
        N'snowcam_error_rate_24h',
        N'Error run percentage by camera in the last 24 hours.',
        N'SELECT camera_id, 100.0 * SUM(CASE WHEN run_status = ''error'' THEN 1 ELSE 0 END) / NULLIF(COUNT(*),0) AS error_rate_pct FROM dbo.snowcam_observations WHERE observation_utc >= DATEADD(hour,-24,SYSUTCDATETIME()) GROUP BY camera_id',
        N'[' + @snowcam_object_id + N']',
        N'[]'
    );
    SET @metric_next_id += 1;
END

IF NOT EXISTS (SELECT 1 FROM catalog.metrics WHERE metric_name = N'snowcam_cleared_events_24h')
BEGIN
    INSERT INTO catalog.metrics(metric_id, metric_name, description, formula_sql, source_object_ids, required_filters)
    VALUES
    (
        @metric_next_id,
        N'snowcam_cleared_events_24h',
        N'Count of stake-cleared events by camera in last 24 hours.',
        N'SELECT camera_id, COUNT(*) AS cleared_events_24h FROM dbo.snowcam_observations WHERE stake_cleared = 1 AND observation_utc >= DATEADD(hour,-24,SYSUTCDATETIME()) GROUP BY camera_id',
        N'[' + @snowcam_object_id + N']',
        N'[]'
    );
END
GO

/* 11) Cleanup helper proc */
DROP PROCEDURE IF EXISTS dbo.usp_upsert_extended_property;
GO
