SET NOCOUNT ON;
GO

IF COL_LENGTH('dbo.dim_camera', 'crop_x') IS NULL
BEGIN
    THROW 50002, 'Crop columns not found on dbo.dim_camera. Run sql/add_camera_crop_columns.sql first.', 1;
END
GO

/* EXM-CAM1 (source image is currently 1280x720) */
UPDATE dbo.dim_camera
SET crop_x = 505,
    crop_y = 180,
    crop_w = 260,
    crop_h = 520
WHERE camera_code = N'EXM-CAM1';
GO

/* EXM-CAM2 (source image is currently 1920x1080) */
UPDATE dbo.dim_camera
SET crop_x = 760,
    crop_y = 150,
    crop_w = 360,
    crop_h = 760
WHERE camera_code = N'EXM-CAM2';
GO

SELECT
    camera_id,
    camera_code,
    camera_name,
    crop_x,
    crop_y,
    crop_w,
    crop_h
FROM dbo.dim_camera
WHERE camera_code IN (N'EXM-CAM1', N'EXM-CAM2')
ORDER BY camera_id;
GO
