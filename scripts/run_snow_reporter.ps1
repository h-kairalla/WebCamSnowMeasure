param(
    [string]$ProjectDir = "C:\Users\hskai\Desktop\WebCamSnowMeasure"
)

Set-Location $ProjectDir

$pythonExe = Join-Path $ProjectDir ".venv\Scripts\python.exe"
if (-not (Test-Path $pythonExe)) {
    Write-Error "Python venv executable not found: $pythonExe"
    exit 1
}

& $pythonExe "snow_reporter.py" --once
exit $LASTEXITCODE
