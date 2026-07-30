[CmdletBinding()]
param(
    [Parameter(Position = 0)]
    [ValidateSet("menu", "doctor", "verify-wechat", "source-status", "validate-manifest")]
    [string]$Command = "menu",

    [string]$AdbPath
)

$ErrorActionPreference = "Stop"
$ProjectRoot = (Resolve-Path (Join-Path $PSScriptRoot "..\..")).Path
$ManifestPath = Join-Path $ProjectRoot "checks\wechat-8.0.70.json"
$script:AdbExecutable = $null

function Write-Title {
    param([string]$Text)
    Write-Host ""
    Write-Host "=== $Text ===" -ForegroundColor Cyan
}

function Write-Pass {
    param([string]$Text)
    Write-Host "[通过] $Text" -ForegroundColor Green
}

function Write-Warn {
    param([string]$Text)
    Write-Host "[注意] $Text" -ForegroundColor Yellow
}

function Write-Fail {
    param([string]$Text)
    Write-Host "[失败] $Text" -ForegroundColor Red
}

function Get-WechatManifest {
    if (-not (Test-Path -LiteralPath $ManifestPath)) {
        throw "找不到微信校验清单：$ManifestPath"
    }

    return Get-Content -Raw -Encoding UTF8 -LiteralPath $ManifestPath |
        ConvertFrom-Json
}

function Test-Manifest {
    param([switch]$Quiet)

    $manifest = Get-WechatManifest
    $errors = [System.Collections.Generic.List[string]]::new()

    if ($manifest.schemaVersion -ne 1) {
        $errors.Add("schemaVersion 必须为 1")
    }
    if ($manifest.packageName -ne "com.tencent.mm") {
        $errors.Add("packageName 必须为 com.tencent.mm")
    }
    if ($manifest.versionName -ne "8.0.70") {
        $errors.Add("versionName 必须为 8.0.70")
    }
    if ($manifest.status -notin @("metadata-pending", "verified")) {
        $errors.Add("status 只能是 metadata-pending 或 verified")
    }

    $verifiedFields = @(
        "downloadUrl",
        "fileSha256",
        "signingCertificateSha256",
        "verifiedAt"
    )

    if ($manifest.status -eq "verified") {
        foreach ($field in $verifiedFields) {
            if ([string]::IsNullOrWhiteSpace([string]$manifest.$field)) {
                $errors.Add("verified 状态缺少 $field")
            }
        }
        if ([string]$manifest.fileSha256 -notmatch "^[a-fA-F0-9]{64}$") {
            $errors.Add("fileSha256 必须是 64 位十六进制")
        }
        if ([string]$manifest.signingCertificateSha256 -notmatch "^[a-fA-F0-9]{64}$") {
            $errors.Add("signingCertificateSha256 必须是 64 位十六进制")
        }
        if ([string]$manifest.downloadUrl -notmatch "^https://") {
            $errors.Add("verified 下载地址必须使用 https://")
        }
    }
    else {
        foreach ($field in @("downloadUrl", "fileSha256", "signingCertificateSha256")) {
            if (-not [string]::IsNullOrWhiteSpace([string]$manifest.$field)) {
                $errors.Add("metadata-pending 状态不得提前发布 $field")
            }
        }
    }

    if ($errors.Count -gt 0) {
        if (-not $Quiet) {
            foreach ($item in $errors) {
                Write-Fail $item
            }
        }
        return $false
    }

    if (-not $Quiet) {
        Write-Pass "微信校验清单结构有效"
    }
    return $true
}

function Resolve-AdbExecutable {
    if ($script:AdbExecutable) {
        return $script:AdbExecutable
    }

    $candidates = [System.Collections.Generic.List[string]]::new()
    if (-not [string]::IsNullOrWhiteSpace($AdbPath)) {
        $candidates.Add($AdbPath)
    }
    if (-not [string]::IsNullOrWhiteSpace($env:FEAGLE_ADB_PATH)) {
        $candidates.Add($env:FEAGLE_ADB_PATH)
    }
    $candidates.Add((Join-Path $ProjectRoot ".tools\platform-tools\adb.exe"))

    $pathAdb = Get-Command adb -ErrorAction SilentlyContinue
    if ($pathAdb) {
        $candidates.Add($pathAdb.Source)
    }

    foreach ($candidate in $candidates) {
        if (Test-Path -LiteralPath $candidate) {
            $script:AdbExecutable = (Resolve-Path -LiteralPath $candidate).Path
            return $script:AdbExecutable
        }
    }

    throw "未找到 adb.exe。请安装 Android Platform Tools，或使用 -AdbPath 指定路径。"
}

function Invoke-AdbText {
    param(
        [Parameter(Mandatory)]
        [string[]]$Arguments,

        [switch]$AllowFailure
    )

    $adb = Resolve-AdbExecutable
    $output = & $adb @Arguments 2>&1
    $exitCode = $LASTEXITCODE
    $text = ($output | Out-String).Trim()

    if ($exitCode -ne 0 -and -not $AllowFailure) {
        throw "ADB 命令失败：$text"
    }

    return [pscustomobject]@{
        ExitCode = $exitCode
        Text = $text
    }
}

function Get-ConnectedDevice {
    $result = Invoke-AdbText -Arguments @("devices")
    $devices = [System.Collections.Generic.List[object]]::new()

    foreach ($line in ($result.Text -split "`r?`n")) {
        if ($line -match "^([^\s]+)\s+(device|unauthorized|offline)$") {
            $devices.Add([pscustomobject]@{
                Serial = $Matches[1]
                State = $Matches[2]
            })
        }
    }

    if ($devices.Count -eq 0) {
        throw "没有发现 Android 设备。请检查 USB 数据线和 USB 调试。"
    }
    if ($devices.Count -gt 1) {
        throw "发现多台设备。首期向导要求一次只连接一台 Android 设备。"
    }
    if ($devices[0].State -eq "unauthorized") {
        throw "设备尚未授权。请解锁屏幕并确认这台电脑的 USB 调试指纹。"
    }
    if ($devices[0].State -ne "device") {
        throw "设备状态异常：$($devices[0].State)"
    }

    return $devices[0]
}

function Get-DeviceProperty {
    param([string]$Name)
    return (Invoke-AdbText -Arguments @("shell", "getprop", $Name)).Text.Trim()
}

function Get-WechatPackageInfo {
    $result = Invoke-AdbText -Arguments @(
        "shell",
        "dumpsys",
        "package",
        "com.tencent.mm"
    ) -AllowFailure

    if ($result.ExitCode -ne 0 -or $result.Text -notmatch "Package \[com\.tencent\.mm\]") {
        return $null
    }

    $versionName = $null
    $versionCode = $null
    if ($result.Text -match "versionName=([^\s]+)") {
        $versionName = $Matches[1]
    }
    if ($result.Text -match "versionCode=(\d+)") {
        $versionCode = $Matches[1]
    }

    return [pscustomobject]@{
        PackageName = "com.tencent.mm"
        VersionName = $versionName
        VersionCode = $versionCode
    }
}

function Invoke-Doctor {
    Write-Title "FEAGLE Android 设备检查"

    try {
        $adb = Resolve-AdbExecutable
        Write-Pass "ADB：$adb"

        $device = Get-ConnectedDevice
        Write-Pass "设备已连接并授权：$($device.Serial)"

        $model = Get-DeviceProperty "ro.product.model"
        $android = Get-DeviceProperty "ro.build.version.release"
        $abi = Get-DeviceProperty "ro.product.cpu.abi"
        Write-Host "  型号：$model"
        Write-Host "  Android：$android"
        Write-Host "  ABI：$abi"

        if ($model -eq "SM-X200" -and $android -eq "14") {
            Write-Pass "设备属于当前已验证基线"
        }
        else {
            Write-Warn "设备不属于当前已验证基线，将按未经验证设备处理"
        }

        $root = Invoke-AdbText -Arguments @("shell", "su", "-c", "id") -AllowFailure
        if ($root.ExitCode -eq 0 -and $root.Text -match "uid=0") {
            Write-Pass "Root：su 可用"
        }
        else {
            Write-Fail "Root：su 不可用或未授权"
        }

        $wechat = Get-WechatPackageInfo
        if (-not $wechat) {
            Write-Warn "微信尚未安装"
        }
        elseif ($wechat.VersionName -eq "8.0.70") {
            Write-Pass "微信版本：8.0.70"
            Write-Warn "当前只确认版本，签名元数据尚未发布，不代表可以安全登录"
        }
        else {
            Write-Fail "微信版本不兼容：$($wechat.VersionName)"
        }

        Show-SourceStatus
        return $true
    }
    catch {
        Write-Fail $_.Exception.Message
        return $false
    }
}

function Invoke-WechatVerification {
    Write-Title "微信 8.0.70 检查"

    try {
        $null = Get-ConnectedDevice
        $manifest = Get-WechatManifest
        $wechat = Get-WechatPackageInfo

        if (-not $wechat) {
            Write-Fail "没有安装 com.tencent.mm"
            return $false
        }

        Write-Pass "包名：$($wechat.PackageName)"
        if ($wechat.VersionName -ne $manifest.versionName) {
            Write-Fail "版本不匹配：当前 $($wechat.VersionName)，要求 $($manifest.versionName)"
            return $false
        }
        Write-Pass "版本：$($wechat.VersionName)"

        if ($manifest.status -ne "verified") {
            Write-Warn "签名证书与文件哈希尚未发布"
            Write-Warn "现在不要依据本工具结论登录微信账号"
            return $false
        }

        Write-Warn "签名比对功能将在发布可信元数据后启用"
        return $false
    }
    catch {
        Write-Fail $_.Exception.Message
        return $false
    }
}

function Show-SourceStatus {
    Write-Title "微信下载源状态"
    $manifest = Get-WechatManifest

    Write-Host "  包名：$($manifest.packageName)"
    Write-Host "  版本：$($manifest.versionName)"
    Write-Host "  状态：$($manifest.status)"

    if ($manifest.status -eq "verified") {
        Write-Pass "下载源、文件哈希和签名证书已经发布"
    }
    else {
        Write-Warn "尚未发布下载链接"
        Write-Warn "需要先从已验证设备确认文件哈希和签名证书"
    }
}

function Show-Menu {
    while ($true) {
        Write-Title "FEAGLE Android Setup"
        Write-Host "1) 检查电脑与 Android 设备"
        Write-Host "2) 检查已安装微信"
        Write-Host "3) 查看微信下载源状态"
        Write-Host "4) 阅读设备前置条件"
        Write-Host "0) 退出"
        Write-Host ""

        $choice = Read-Host "请选择 [0-4]"
        switch ($choice) {
            "1" { $null = Invoke-Doctor }
            "2" { $null = Invoke-WechatVerification }
            "3" { Show-SourceStatus }
            "4" {
                Write-Host (Join-Path $ProjectRoot "docs\01-device-requirements.md")
            }
            "0" { return }
            default { Write-Warn "无效选项" }
        }
    }
}

switch ($Command) {
    "menu" {
        Show-Menu
    }
    "doctor" {
        if (-not (Invoke-Doctor)) {
            exit 1
        }
    }
    "verify-wechat" {
        if (-not (Invoke-WechatVerification)) {
            exit 1
        }
    }
    "source-status" {
        Show-SourceStatus
    }
    "validate-manifest" {
        if (-not (Test-Manifest)) {
            exit 1
        }
    }
}
