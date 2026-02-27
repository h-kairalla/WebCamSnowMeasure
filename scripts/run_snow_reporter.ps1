param(
    [string]$ProjectDir = "C:\Users\hskai\Desktop\WebCamSnowMeasure"
)

Set-Location $ProjectDir
docker compose run --rm snowcam-reporter python snow_reporter.py
exit $LASTEXITCODE
