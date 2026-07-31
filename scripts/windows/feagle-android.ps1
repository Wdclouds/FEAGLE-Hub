[CmdletBinding()]
param(
    [Parameter(Position = 0)]
    [ValidateSet(
        "menu",
        "doctor",
        "verify-apk",
        "install-wechat",
        "verify-wechat",
        "source-status",
        "validate-manifest"
    )]
    [string]$Command = "menu",

    [string]$AdbPath,

    [string]$ApkPath,

    [string]$AndroidSdkPath,

    [string]$JavaHome,

    [switch]$ConfirmInstall
)

$ErrorActionPreference = "Stop"
$ProjectRoot = (Resolve-Path (Join-Path $PSScriptRoot "..\..")).Path
$ManifestPath = Join-Path $ProjectRoot "checks\wechat-8.0.70.json"
$script:AdbExecutable = $null
$script:ApkSignerExecutable = $null
$script:Aapt2Executable = $null
$script:ResolvedJavaHome = $null

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
    if ($manifest.status -notin @(
        "metadata-pending",
        "reference-verified",
        "source-verified"
    )) {
        $errors.Add(
            "status 只能是 metadata-pending、reference-verified 或 source-verified"
        )
    }

    $fingerprintFields = @(
        "fileSha256",
        "signingCertificateSha256",
        "verifiedAt"
    )

    if ($manifest.status -in @("reference-verified", "source-verified")) {
        foreach ($field in $fingerprintFields) {
            if ([string]::IsNullOrWhiteSpace([string]$manifest.$field)) {
                $errors.Add("$($manifest.status) 状态缺少 $field")
            }
        }
        if ([string]$manifest.fileSha256 -notmatch "^[a-fA-F0-9]{64}$") {
            $errors.Add("fileSha256 必须是 64 位十六进制")
        }
        if ([string]$manifest.signingCertificateSha256 -notmatch "^[a-fA-F0-9]{64}$") {
            $errors.Add("signingCertificateSha256 必须是 64 位十六进制")
        }
    }

    if ($manifest.status -eq "source-verified") {
        if ([string]::IsNullOrWhiteSpace([string]$manifest.downloadUrl)) {
            $errors.Add("source-verified 状态缺少 downloadUrl")
        }
        if ([string]$manifest.downloadUrl -notmatch "^https://") {
            $errors.Add("source-verified 下载地址必须使用 https://")
        }
    }

    if ($manifest.status -eq "reference-verified") {
        if (-not [string]::IsNullOrWhiteSpace([string]$manifest.downloadUrl)) {
            $errors.Add("reference-verified 状态不得提前发布 downloadUrl")
        }
    }

    if ($manifest.status -eq "metadata-pending") {
        foreach ($field in @("downloadUrl", "fileSha256", "signingCertificateSha256")) {
            if (-not [string]::IsNullOrWhiteSpace([string]$manifest.$field)) {
                $errors.Add("metadata-pending 状态不得提前发布 $field")
            }
        }
    }

    foreach ($candidate in @($manifest.candidateSources)) {
        if ([string]$candidate.pageUrl -notmatch "^https://") {
            $errors.Add("候选来源页面必须使用 https://")
        }
        if ($candidate.metadataMatchesReference -eq $true) {
            if ([string]$candidate.reportedFileSha256 -ne [string]$manifest.fileSha256) {
                $errors.Add("候选来源报告的文件 SHA-256 与参考值不一致")
            }
            if (
                [string]$candidate.reportedSigningCertificateSha256 -ne
                [string]$manifest.signingCertificateSha256
            ) {
                $errors.Add("候选来源报告的签名证书 SHA-256 与参考值不一致")
            }
            if (
                [long]$candidate.reportedArtifactSizeBytes -ne
                [long]$manifest.artifactSizeBytes
            ) {
                $errors.Add("候选来源报告的文件大小与参考值不一致")
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

function Get-AndroidSdkCandidates {
    $candidates = [System.Collections.Generic.List[string]]::new()

    foreach ($candidate in @(
        $AndroidSdkPath,
        $env:FEAGLE_ANDROID_SDK,
        $env:ANDROID_SDK_ROOT,
        $env:ANDROID_HOME,
        (Join-Path $ProjectRoot ".tools\android-sdk")
    )) {
        if (-not [string]::IsNullOrWhiteSpace([string]$candidate)) {
            $candidates.Add([string]$candidate)
        }
    }

    return $candidates
}

function Resolve-BuildTool {
    param(
        [Parameter(Mandatory)]
        [string]$FileName
    )

    foreach ($sdkRoot in Get-AndroidSdkCandidates) {
        if (-not (Test-Path -LiteralPath $sdkRoot)) {
            continue
        }

        $buildTools = Join-Path $sdkRoot "build-tools"
        if (-not (Test-Path -LiteralPath $buildTools)) {
            continue
        }

        $match = Get-ChildItem -LiteralPath $buildTools -Directory |
            Sort-Object Name -Descending |
            ForEach-Object {
                Join-Path $_.FullName $FileName
            } |
            Where-Object {
                Test-Path -LiteralPath $_
            } |
            Select-Object -First 1

        if ($match) {
            return (Resolve-Path -LiteralPath $match).Path
        }
    }

    throw (
        "未找到 Android SDK Build Tools 中的 $FileName。请安装 Build Tools，" +
        "或使用 -AndroidSdkPath 指定 Android SDK 目录。"
    )
}

function Resolve-ApkSignerExecutable {
    if (-not $script:ApkSignerExecutable) {
        $script:ApkSignerExecutable = Resolve-BuildTool "apksigner.bat"
    }
    return $script:ApkSignerExecutable
}

function Resolve-Aapt2Executable {
    if (-not $script:Aapt2Executable) {
        $script:Aapt2Executable = Resolve-BuildTool "aapt2.exe"
    }
    return $script:Aapt2Executable
}

function Resolve-JavaHome {
    if ($script:ResolvedJavaHome) {
        return $script:ResolvedJavaHome
    }

    $candidates = [System.Collections.Generic.List[string]]::new()
    foreach ($candidate in @(
        $JavaHome,
        $env:FEAGLE_JAVA_HOME,
        $env:JAVA_HOME,
        (Join-Path $ProjectRoot ".tools\jdk")
    )) {
        if (-not [string]::IsNullOrWhiteSpace([string]$candidate)) {
            $candidates.Add([string]$candidate)
        }
    }

    $pathJava = Get-Command java -ErrorAction SilentlyContinue
    if ($pathJava) {
        $candidates.Add((Split-Path (Split-Path $pathJava.Source -Parent) -Parent))
    }

    foreach ($candidate in $candidates) {
        $javaExecutable = Join-Path $candidate "bin\java.exe"
        if (Test-Path -LiteralPath $javaExecutable) {
            $script:ResolvedJavaHome = (Resolve-Path -LiteralPath $candidate).Path
            return $script:ResolvedJavaHome
        }
    }

    throw (
        "未找到 Java。APK 签名校验需要 JDK 17；请使用 -JavaHome 指定 JDK 目录。"
    )
}

function Invoke-ExternalText {
    param(
        [Parameter(Mandatory)]
        [string]$FilePath,

        [Parameter(Mandatory)]
        [string[]]$Arguments,

        [switch]$AllowFailure
    )

    $previousErrorAction = $ErrorActionPreference
    try {
        $ErrorActionPreference = "Continue"
        $output = & $FilePath @Arguments 2>&1
        $exitCode = $LASTEXITCODE
    }
    finally {
        $ErrorActionPreference = $previousErrorAction
    }
    $text = ($output | Out-String).Trim()

    if ($exitCode -ne 0 -and -not $AllowFailure) {
        throw "外部工具执行失败：$text"
    }

    return [pscustomobject]@{
        ExitCode = $exitCode
        Text = $text
    }
}

function Invoke-AdbText {
    param(
        [Parameter(Mandatory)]
        [string[]]$Arguments,

        [switch]$AllowFailure
    )

    $adb = Resolve-AdbExecutable
    $previousErrorAction = $ErrorActionPreference
    try {
        $ErrorActionPreference = "Continue"
        $output = & $adb @Arguments 2>&1
        $exitCode = $LASTEXITCODE
    }
    finally {
        $ErrorActionPreference = $previousErrorAction
    }
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
    $null = Invoke-AdbText -Arguments @("start-server") -AllowFailure
    $result = Invoke-AdbText -Arguments @("devices") -AllowFailure
    if ($result.ExitCode -ne 0) {
        Start-Sleep -Milliseconds 500
        $result = Invoke-AdbText -Arguments @("devices") -AllowFailure
    }
    if ($result.ExitCode -ne 0) {
        throw "ADB 设备列表读取失败：$($result.Text)"
    }

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

function Normalize-Fingerprint {
    param([string]$Value)
    return ([string]$Value -replace "[^a-fA-F0-9]", "").ToLowerInvariant()
}

function Get-ApkInspection {
    param(
        [Parameter(Mandatory)]
        [string]$Path
    )

    $manifest = Get-WechatManifest
    $errors = [System.Collections.Generic.List[string]]::new()
    $resolvedPath = $null
    $actualSize = 0
    $actualFileSha256 = $null
    $certificateSha256 = $null
    $certificateSubject = $null
    $packageName = $null
    $versionName = $null
    $versionCode = $null
    $nativeAbis = @()

    try {
        if (-not (Test-Manifest -Quiet)) {
            throw "微信校验清单无效"
        }
        if ($manifest.status -eq "metadata-pending") {
            throw "参考文件哈希与签名证书尚未发布，不能验证 APK"
        }
        if ([string]::IsNullOrWhiteSpace($Path)) {
            throw "缺少 APK 路径。请使用 -ApkPath 指定下载文件。"
        }
        if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
            throw "找不到 APK 文件：$Path"
        }

        $resolvedPath = (Resolve-Path -LiteralPath $Path).Path
        if ([System.IO.Path]::GetExtension($resolvedPath) -ne ".apk") {
            throw "只接受扩展名为 .apk 的单文件安装包"
        }

        $file = Get-Item -LiteralPath $resolvedPath
        $actualSize = [long]$file.Length
        if ($actualSize -ne [long]$manifest.artifactSizeBytes) {
            throw (
                "文件大小不匹配：实际 $actualSize bytes，" +
                "参考 $($manifest.artifactSizeBytes) bytes"
            )
        }

        $actualFileSha256 = (
            Get-FileHash -LiteralPath $resolvedPath -Algorithm SHA256
        ).Hash.ToLowerInvariant()
        if (
            $actualFileSha256 -ne
            ([string]$manifest.fileSha256).ToLowerInvariant()
        ) {
            throw "文件 SHA-256 与参考安装包不一致，已停止后续解析"
        }

        # Only parse the APK after its full-file hash matches the validated reference.
        $env:JAVA_HOME = Resolve-JavaHome
        $apksigner = Resolve-ApkSignerExecutable
        $signature = Invoke-ExternalText -FilePath $apksigner -Arguments @(
            "verify",
            "--verbose",
            "--print-certs",
            $resolvedPath
        ) -AllowFailure

        if (
            $signature.ExitCode -ne 0 -or
            $signature.Text -notmatch "(?m)^Verifies\s*$"
        ) {
            throw "APK 签名结构验证失败"
        }
        if (
            $signature.Text -notmatch
            "(?m)^Signer #1 certificate SHA-256 digest:\s*([a-fA-F0-9:]+)\s*$"
        ) {
            throw "无法读取 APK 签名证书 SHA-256"
        }
        $certificateSha256 = Normalize-Fingerprint $Matches[1]
        if (
            $certificateSha256 -ne
            (Normalize-Fingerprint $manifest.signingCertificateSha256)
        ) {
            throw "APK 签名证书与参考值不一致"
        }
        if (
            $signature.Text -match
            "(?m)^Signer #1 certificate DN:\s*(.+?)\s*$"
        ) {
            $certificateSubject = $Matches[1].Trim()
        }

        $aapt2 = Resolve-Aapt2Executable
        $badging = Invoke-ExternalText -FilePath $aapt2 -Arguments @(
            "dump",
            "badging",
            $resolvedPath
        ) -AllowFailure
        if ($badging.ExitCode -ne 0) {
            throw "无法读取 APK 包信息"
        }
        if (
            $badging.Text -notmatch
            "(?m)^package:\s+name='([^']+)'\s+versionCode='([^']+)'\s+versionName='([^']+)'"
        ) {
            throw "APK 包名或版本信息缺失"
        }

        $packageName = $Matches[1]
        $versionCode = $Matches[2]
        $versionName = $Matches[3]

        if ($packageName -ne [string]$manifest.packageName) {
            throw "APK 包名不匹配：$packageName"
        }
        if ($versionName -ne [string]$manifest.versionName) {
            throw "APK 版本不匹配：$versionName"
        }
        if ([long]$versionCode -ne [long]$manifest.versionCode) {
            throw "APK versionCode 不匹配：$versionCode"
        }

        if ($badging.Text -match "(?m)^native-code:\s*(.+?)\s*$") {
            $nativeAbis = @(
                [regex]::Matches($Matches[1], "'([^']+)'") |
                    ForEach-Object {
                        $_.Groups[1].Value
                    }
            )
        }

        $supported = @($manifest.supportedAbis)
        if (
            $nativeAbis.Count -eq 0 -or
            -not @($nativeAbis | Where-Object { $_ -in $supported }).Count
        ) {
            throw (
                "APK CPU 架构不匹配：$($nativeAbis -join ', ')；" +
                "要求 $($supported -join ', ')"
            )
        }
    }
    catch {
        $errors.Add($_.Exception.Message)
    }

    return [pscustomobject]@{
        Valid = ($errors.Count -eq 0)
        Path = $resolvedPath
        SizeBytes = $actualSize
        FileSha256 = $actualFileSha256
        SigningCertificateSha256 = $certificateSha256
        SigningCertificateSubject = $certificateSubject
        PackageName = $packageName
        VersionName = $versionName
        VersionCode = $versionCode
        NativeAbis = $nativeAbis
        Errors = @($errors)
    }
}

function Write-ApkInspection {
    param(
        [Parameter(Mandatory)]
        [object]$Inspection
    )

    if (-not $Inspection.Valid) {
        foreach ($item in $Inspection.Errors) {
            Write-Fail $item
        }
        return
    }

    Write-Pass "文件大小与参考值一致：$($Inspection.SizeBytes) bytes"
    Write-Pass "文件 SHA-256 与参考值一致"
    Write-Pass "APK 签名结构验证通过"
    Write-Pass "腾讯签名证书 SHA-256 与参考值一致"
    Write-Pass (
        "包名与版本：$($Inspection.PackageName) " +
        "$($Inspection.VersionName) ($($Inspection.VersionCode))"
    )
    Write-Pass "CPU 架构：$($Inspection.NativeAbis -join ', ')"
}

function Invoke-ApkVerification {
    param(
        [Parameter(Mandatory)]
        [string]$Path
    )

    Write-Title "微信 APK 安全验证"
    $inspection = Get-ApkInspection -Path $Path
    Write-ApkInspection $inspection

    if ($inspection.Valid) {
        Write-Pass "全部验证通过：该文件与已验证参考安装包完全一致"
        Write-Host "  下一步可使用 install-wechat 并显式确认安装。"
    }
    else {
        Write-Warn "验证失败：不会安装，也不要使用该文件登录微信"
    }

    return $inspection
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
            Write-Warn "doctor 只检查版本；请运行 verify-wechat 完成安装指纹验证"
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

    $temporaryDirectory = $null
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

        $paths = @(
            (Invoke-AdbText -Arguments @(
                "shell",
                "pm",
                "path",
                "com.tencent.mm"
            )).Text -split "`r?`n" |
                Where-Object {
                    $_ -match "^package:"
                } |
                ForEach-Object {
                    ($_ -replace "^package:", "").Trim()
                }
        )

        if ($paths.Count -ne 1 -or (Split-Path $paths[0] -Leaf) -ne "base.apk") {
            Write-Fail "当前安装不是已验证的单 base.apk 结构"
            return $false
        }

        $temporaryDirectory = Join-Path (
            [System.IO.Path]::GetTempPath()
        ) ("feagle-wechat-verify-" + [guid]::NewGuid().ToString("N"))
        New-Item -ItemType Directory -Path $temporaryDirectory | Out-Null
        $temporaryApk = Join-Path $temporaryDirectory "base.apk"

        Write-Host "  正在从设备临时读取已安装 APK 进行指纹比对..."
        $pull = Invoke-AdbText -Arguments @(
            "pull",
            $paths[0],
            $temporaryApk
        ) -AllowFailure
        if ($pull.ExitCode -ne 0 -or -not (Test-Path -LiteralPath $temporaryApk)) {
            Write-Fail "无法从设备读取已安装 APK：$($pull.Text)"
            return $false
        }

        $inspection = Get-ApkInspection -Path $temporaryApk
        Write-ApkInspection $inspection
        if (-not $inspection.Valid) {
            Write-Warn "已安装微信未通过完整指纹检查，不要依据本工具结论登录"
            return $false
        }

        Write-Pass "已安装微信与验证参考包完全一致"
        return $true
    }
    catch {
        Write-Fail $_.Exception.Message
        return $false
    }
    finally {
        if (
            $temporaryDirectory -and
            (Test-Path -LiteralPath $temporaryDirectory)
        ) {
            Remove-Item -LiteralPath $temporaryDirectory -Recurse -Force
        }
    }
}

function Invoke-WechatInstall {
    param(
        [Parameter(Mandatory)]
        [string]$Path,

        [switch]$Confirmed
    )

    Write-Title "安装经过验证的微信 8.0.70"
    $inspection = Get-ApkInspection -Path $Path
    Write-ApkInspection $inspection
    if (-not $inspection.Valid) {
        Write-Warn "APK 验证失败，安装已阻止"
        return $false
    }

    try {
        $null = Get-ConnectedDevice
        $existing = Get-WechatPackageInfo
        if ($existing) {
            if (
                $existing.VersionName -eq $inspection.VersionName -and
                [long]$existing.VersionCode -eq [long]$inspection.VersionCode
            ) {
                Write-Warn "设备已安装目标版本，不重复覆盖"
                return Invoke-WechatVerification
            }

            Write-Fail (
                "设备已安装微信 $($existing.VersionName) " +
                "($($existing.VersionCode))"
            )
            Write-Warn "助手不会自动卸载、降级或清除微信数据"
            Write-Warn "请先备份并由设备所有者手动处理现有版本，再重新检查"
            return $false
        }

        if (-not $Confirmed) {
            Write-Warn "文件已经通过验证，但尚未获得安装确认"
            Write-Host (
                "  确认设备中没有需要保留的微信数据后，重新运行并添加 " +
                "-ConfirmInstall"
            )
            return $false
        }

        Write-Host "  正在通过 ADB 安装..."
        $install = Invoke-AdbText -Arguments @(
            "install",
            "--no-streaming",
            $inspection.Path
        ) -AllowFailure
        if ($install.ExitCode -ne 0 -or $install.Text -notmatch "(?m)^Success$") {
            Write-Fail "ADB 安装失败：$($install.Text)"
            return $false
        }

        Write-Pass "ADB 安装完成"
        return Invoke-WechatVerification
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

    if ($manifest.status -eq "source-verified") {
        Write-Pass "下载源、文件哈希和签名证书已经发布"
    }
    elseif ($manifest.status -eq "reference-verified") {
        Write-Pass "参考文件哈希和签名证书已经确认"
        Write-Warn "尚未发布与参考指纹完全匹配的下载链接"
        foreach ($candidate in @($manifest.candidateSources)) {
            Write-Host "  候选页面：$($candidate.name)"
            if ($candidate.metadataMatchesReference -eq $true) {
                Write-Pass "候选页面报告的元数据与参考指纹一致"
            }
            if ($candidate.downloadVerifiedLocally -ne $true) {
                Write-Warn "候选文件尚未由安装助手独立下载复验"
            }
        }
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
        Write-Host "2) 验证本地微信 APK"
        Write-Host "3) 安装已经验证的微信 APK"
        Write-Host "4) 完整检查设备中已安装的微信"
        Write-Host "5) 查看微信下载源状态"
        Write-Host "6) 阅读设备前置条件"
        Write-Host "0) 退出"
        Write-Host ""

        $choice = Read-Host "请选择 [0-6]"
        switch ($choice) {
            "1" { $null = Invoke-Doctor }
            "2" {
                $localApk = Read-Host "请输入下载完成的 APK 文件路径"
                if (-not [string]::IsNullOrWhiteSpace($localApk)) {
                    $null = Invoke-ApkVerification -Path $localApk
                }
            }
            "3" {
                $localApk = Read-Host "请输入已经验证的 APK 文件路径"
                $confirmation = Read-Host (
                    "确认设备没有需要保留的旧微信数据后，输入 INSTALL 8.0.70"
                )
                if (-not [string]::IsNullOrWhiteSpace($localApk)) {
                    $null = Invoke-WechatInstall -Path $localApk `
                        -Confirmed:($confirmation -eq "INSTALL 8.0.70")
                }
            }
            "4" { $null = Invoke-WechatVerification }
            "5" { Show-SourceStatus }
            "6" {
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
    "verify-apk" {
        if ([string]::IsNullOrWhiteSpace($ApkPath)) {
            Write-Fail "请使用 -ApkPath 指定 APK 文件"
            exit 2
        }
        $result = Invoke-ApkVerification -Path $ApkPath
        if (-not $result.Valid) {
            exit 1
        }
    }
    "install-wechat" {
        if ([string]::IsNullOrWhiteSpace($ApkPath)) {
            Write-Fail "请使用 -ApkPath 指定 APK 文件"
            exit 2
        }
        if (-not (Invoke-WechatInstall -Path $ApkPath -Confirmed:$ConfirmInstall)) {
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
