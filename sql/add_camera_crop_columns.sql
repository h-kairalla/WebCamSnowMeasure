SET NOCOUNT ON;
GO

/* Add per-camera crop columns (pixel coordinates on source image). */
IF COL_LENGTH('dbo.dim_camera', 'crop_x') IS NULL
    ALTER TABLE dbo.dim_camera ADD crop_x INT NULL;
GO
IF COL_LENGTH('dbo.dim_camera', 'crop_y') IS NULL
    ALTER TABLE dbo.dim_camera ADD crop_y INT NULL;
GO
IF COL_LENGTH('dbo.dim_camera', 'crop_w') IS NULL
    ALTER TABLE dbo.dim_camera ADD crop_w INT NULL;
GO
IF COL_LENGTH('dbo.dim_camera', 'crop_h') IS NULL
    ALTER TABLE dbo.dim_camera ADD crop_h INT NULL;
GO

/* Guardrails so invalid crop values are rejected. */
IF NOT EXISTS (SELECT 1 FROM sys.check_constraints WHERE name = 'CK_dim_camera_crop_x_nonnegative')
BEGIN
    ALTER TABLE dbo.dim_camera
    ADD CONSTRAINT CK_dim_camera_crop_x_nonnegative
    CHECK (crop_x IS NULL OR crop_x >= 0);
END
GO
IF NOT EXISTS (SELECT 1 FROM sys.check_constraints WHERE name = 'CK_dim_camera_crop_y_nonnegative')
BEGIN
    ALTER TABLE dbo.dim_camera
    ADD CONSTRAINT CK_dim_camera_crop_y_nonnegative
    CHECK (crop_y IS NULL OR crop_y >= 0);
END
GO
IF NOT EXISTS (SELECT 1 FROM sys.check_constraints WHERE name = 'CK_dim_camera_crop_w_positive')
BEGIN
    ALTER TABLE dbo.dim_camera
    ADD CONSTRAINT CK_dim_camera_crop_w_positive
    CHECK (crop_w IS NULL OR crop_w > 0);
END
GO
IF NOT EXISTS (SELECT 1 FROM sys.check_constraints WHERE name = 'CK_dim_camera_crop_h_positive')
BEGIN
    ALTER TABLE dbo.dim_camera
    ADD CONSTRAINT CK_dim_camera_crop_h_positive
    CHECK (crop_h IS NULL OR crop_h > 0);
END
GO

/* Keep crop fields all-null (no crop) or all-set (valid crop rectangle). */
IF NOT EXISTS (SELECT 1 FROM sys.check_constraints WHERE name = 'CK_dim_camera_crop_all_or_none')
BEGIN
    ALTER TABLE dbo.dim_camera
    ADD CONSTRAINT CK_dim_camera_crop_all_or_none
    CHECK (
        (crop_x IS NULL AND crop_y IS NULL AND crop_w IS NULL AND crop_h IS NULL)
        OR
        (crop_x IS NOT NULL AND crop_y IS NOT NULL AND crop_w IS NOT NULL AND crop_h IS NOT NULL)
    );
END
GO

/* Extended properties (MS_Description). */
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

IF COL_LENGTH('dbo.dim_camera', 'crop_x') IS NOT NULL
    EXEC dbo.usp_upsert_extended_property
        N'MS_Description', N'Left pixel for optional camera-specific crop rectangle.',
        N'SCHEMA', N'dbo', N'TABLE', N'dim_camera', N'COLUMN', N'crop_x';
IF COL_LENGTH('dbo.dim_camera', 'crop_y') IS NOT NULL
    EXEC dbo.usp_upsert_extended_property
        N'MS_Description', N'Top pixel for optional camera-specific crop rectangle.',
        N'SCHEMA', N'dbo', N'TABLE', N'dim_camera', N'COLUMN', N'crop_y';
IF COL_LENGTH('dbo.dim_camera', 'crop_w') IS NOT NULL
    EXEC dbo.usp_upsert_extended_property
        N'MS_Description', N'Width in pixels for optional camera-specific crop rectangle.',
        N'SCHEMA', N'dbo', N'TABLE', N'dim_camera', N'COLUMN', N'crop_w';
IF COL_LENGTH('dbo.dim_camera', 'crop_h') IS NOT NULL
    EXEC dbo.usp_upsert_extended_property
        N'MS_Description', N'Height in pixels for optional camera-specific crop rectangle.',
        N'SCHEMA', N'dbo', N'TABLE', N'dim_camera', N'COLUMN', N'crop_h';
GO

/* Catalog metadata (if catalog tables exist in this DB). */
IF OBJECT_ID('catalog.columns', 'U') IS NOT NULL
BEGIN
    DECLARE @obj_id INT = (
        SELECT object_id
        FROM catalog.objects
        WHERE schema_name = N'dbo' AND object_name = N'dim_camera'
    );

    IF @obj_id IS NOT NULL
    BEGIN
        ;WITH src AS
        (
            SELECT
                @obj_id AS object_id,
                c.name AS column_name,
                t.name AS data_type,
                c.max_length,
                c.precision,
                c.scale,
                c.is_nullable
            FROM sys.columns c
            JOIN sys.types t ON c.user_type_id = t.user_type_id
            WHERE c.object_id = OBJECT_ID(N'dbo.dim_camera')
              AND c.name IN (N'crop_x', N'crop_y', N'crop_w', N'crop_h')
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
            SELECT *, ROW_NUMBER() OVER (ORDER BY column_name) AS rn
            FROM missing
        )
        INSERT INTO catalog.columns
        (
            column_id, object_id, column_name, data_type, max_length, precision, scale, is_nullable,
            description, example_values, semantic_tags, is_join_key, is_primary_key, primary_key_ordinal
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
            CASE column_name
                WHEN N'crop_x' THEN N'Left pixel for optional crop rectangle.'
                WHEN N'crop_y' THEN N'Top pixel for optional crop rectangle.'
                WHEN N'crop_w' THEN N'Width in pixels for optional crop rectangle.'
                WHEN N'crop_h' THEN N'Height in pixels for optional crop rectangle.'
            END,
            NULL,
            N'["camera","image","crop"]',
            0,
            0,
            0
        FROM numbered_missing;

        UPDATE cc
        SET cc.description =
            CASE cc.column_name
                WHEN N'crop_x' THEN N'Left pixel for optional crop rectangle.'
                WHEN N'crop_y' THEN N'Top pixel for optional crop rectangle.'
                WHEN N'crop_w' THEN N'Width in pixels for optional crop rectangle.'
                WHEN N'crop_h' THEN N'Height in pixels for optional crop rectangle.'
                ELSE cc.description
            END,
            cc.semantic_tags = N'["camera","image","crop"]'
        FROM catalog.columns cc
        WHERE cc.object_id = @obj_id
          AND cc.column_name IN (N'crop_x', N'crop_y', N'crop_w', N'crop_h');
    END
END
GO

DROP PROCEDURE IF EXISTS dbo.usp_upsert_extended_property;
GO
