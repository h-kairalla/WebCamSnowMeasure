SET NOCOUNT ON;
GO

IF COL_LENGTH('dbo.dim_camera', 'model_notes') IS NULL
BEGIN
    ALTER TABLE dbo.dim_camera ADD model_notes NVARCHAR(1000) NULL;
END
GO

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

IF COL_LENGTH('dbo.dim_camera', 'model_notes') IS NOT NULL
    EXEC dbo.usp_upsert_extended_property
        N'MS_Description', N'Optional camera-specific model instructions appended to the global prompt.',
        N'SCHEMA', N'dbo', N'TABLE', N'dim_camera', N'COLUMN', N'model_notes';
GO

IF OBJECT_ID('catalog.columns', 'U') IS NOT NULL
BEGIN
    DECLARE @obj_id INT = (
        SELECT object_id
        FROM catalog.objects
        WHERE schema_name = N'dbo' AND object_name = N'dim_camera'
    );

    IF @obj_id IS NOT NULL
    BEGIN
        IF NOT EXISTS (
            SELECT 1
            FROM catalog.columns
            WHERE object_id = @obj_id
              AND column_name = N'model_notes'
        )
        BEGIN
            INSERT INTO catalog.columns
            (
                column_id, object_id, column_name, data_type, max_length, precision, scale, is_nullable,
                description, example_values, semantic_tags, is_join_key, is_primary_key, primary_key_ordinal
            )
            SELECT
                ISNULL(MAX(column_id), 0) + 1,
                @obj_id,
                N'model_notes',
                N'nvarchar',
                2000,
                0,
                0,
                1,
                N'Optional camera-specific model instructions appended to the global prompt.',
                NULL,
                N'["camera","ai","prompt"]',
                0,
                0,
                0
            FROM catalog.columns;
        END
        ELSE
        BEGIN
            UPDATE catalog.columns
            SET description = N'Optional camera-specific model instructions appended to the global prompt.',
                semantic_tags = N'["camera","ai","prompt"]'
            WHERE object_id = @obj_id
              AND column_name = N'model_notes';
        END
    END
END
GO

DROP PROCEDURE IF EXISTS dbo.usp_upsert_extended_property;
GO
