SET NOCOUNT ON;
GO

IF COL_LENGTH('dbo.dim_camera', 'model_notes') IS NULL
BEGIN
    THROW 50003, 'model_notes column not found on dbo.dim_camera. Run sql/add_camera_model_notes.sql first.', 1;
END
GO

UPDATE dbo.dim_camera
SET model_notes = N'Only count snow where a continuous snow surface clearly intersects the ruler marks. For this camera, ignore the fixed dark brush-like object at the base; it is not snow.'
WHERE camera_code = N'EXM-CAM2';
GO

UPDATE dbo.dim_camera
SET model_notes = N'Use only the stake intersection for depth. If the base/platform at the stake is visible and clear, depth is 0.0.'
WHERE camera_code = N'EXM-CAM1';
GO

SELECT camera_code, model_notes
FROM dbo.dim_camera
WHERE camera_code IN (N'EXM-CAM1', N'EXM-CAM2')
ORDER BY camera_code;
GO
