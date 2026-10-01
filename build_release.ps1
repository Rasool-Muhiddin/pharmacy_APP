# Run from project root:  powershell -ExecutionPolicy Bypass -File .\build_release.ps1
$ErrorActionPreference = "Stop"
$ApiRoot = "https://pharmacy-api.tera-software1.com/api"

# 1) Make sure the server is reachable before building
try {
    $r = Invoke-WebRequest -Uri "$ApiRoot/health/" -UseBasicParsing -TimeoutSec 15
    Write-Host "Server OK ($($r.StatusCode))" -ForegroundColor Green
} catch {
    Write-Host "API is not responding: $ApiRoot/health/ - build aborted, check the server first" -ForegroundColor Red
    exit 1
}

# 2) Build
flutter clean
flutter pub get
flutter build windows --release --dart-define=TERA_API_ROOT_URL=$ApiRoot
if ($LASTEXITCODE -ne 0) {
    Write-Host "Build failed" -ForegroundColor Red
    exit 1
}

# 3) Verify the local dev URL is not baked into the build
$so = "build\windows\x64\runner\Release\data\app.so"
if (Select-String -Path $so -Pattern "127.0.0.1:8000" -SimpleMatch -Quiet) {
    Write-Host "WARNING: local dev URL is still inside the build!" -ForegroundColor Red
} else {
    Write-Host "DONE: build points to the production server" -ForegroundColor Green
}
Write-Host "Output: build\windows\x64\runner\Release"