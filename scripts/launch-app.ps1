# FEAGLE Hub 轻量原生桌面窗口启动器 (基于系统 Edge WebView2 / App Mode)
$ErrorActionPreference = "Stop"

$HubDir = Resolve-Path (Join-Path $PSScriptRoot "..")
$PublicUrl = "http://127.0.0.1:6200"

Write-Host "正在检查并启动 FEAGLE Hub 后台微服务..." -ForegroundColor Cyan

# 1. 检查并自愈启动后台 Node.js 服务 (静默无黑框)
$portBusy = Get-NetTCPConnection -LocalPort 6200 -State Listen -ErrorAction SilentlyContinue
if (-not $portBusy) {
    Start-Process -FilePath "node.exe" -ArgumentList "src/index.js" -WorkingDirectory $HubDir -WindowStyle Hidden
    Start-Sleep -Milliseconds 800
}

Write-Host "正在拉起独立轻量桌面应用视窗 (无边框/无URL栏)..." -ForegroundColor Green

# 2. 优先使用 Windows Edge 应用模式启动独立窗口 (零打包体积，内存极低)
$EdgePath = "C:\Program Files (x86)\Microsoft\Edge\Application\msedge.exe"
if (-not (Test-Path $EdgePath)) {
    $EdgePath = "C:\Program Files\Microsoft\Edge\Application\msedge.exe"
}

if (Test-Path $EdgePath) {
    Start-Process -FilePath $EdgePath -ArgumentList "--app=$PublicUrl", "--window-size=1280,840", "--user-data-dir=$env:TEMP\feagle_hub_webview"
} else {
    Start-Process $PublicUrl
}
