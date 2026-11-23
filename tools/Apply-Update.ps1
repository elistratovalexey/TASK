param(
    [string]$Target = "D:\Projects\project_reminders"
)
$ErrorActionPreference = "Stop"
$source = Split-Path -Parent $PSScriptRoot
$source = [IO.Path]::GetFullPath($source).TrimEnd('\')
$Target = [IO.Path]::GetFullPath($Target).TrimEnd('\')
if ($source -eq $Target -or $source.StartsWith($Target + '\', [StringComparison]::OrdinalIgnoreCase)) {
    throw "Extract the update to a separate folder, not into the target."
}
if (-not (Test-Path (Join-Path $Target "pubspec.yaml"))) {
    throw "Target project not found: $Target"
}
Write-Host "Close the running application before continuing."
Write-Host "Source: $source"
Write-Host "Target: $Target"
if ((Read-Host "Type YES to back up the source and apply the update") -cne "YES") {
    Write-Host "Cancelled."
    exit 0
}
$backup = "${Target}_sources_before_v020_$(Get-Date -Format yyyyMMdd_HHmmss)"
if (Test-Path $backup) { throw "Backup folder already exists: $backup" }
New-Item -ItemType Directory -Path $backup | Out-Null
$items = @("lib", "test", "android", "windows", "pubspec.yaml", "pubspec.lock", "analysis_options.yaml")
foreach ($item in $items) {
    $path = Join-Path $Target $item
    if (Test-Path $path) {
        if (Test-Path $path -PathType Container) {
            foreach ($file in Get-ChildItem -LiteralPath $path -Recurse -File) {
                $relative = $file.FullName.Substring($Target.Length + 1)
                if ($relative -match '(^|\\)(build|\.gradle|\.kotlin|\.dart_tool|ephemeral)(\\|$)') { continue }
                $destination = Join-Path $backup $relative
                New-Item -ItemType Directory -Force -Path (Split-Path -Parent $destination) | Out-Null
                Copy-Item -LiteralPath $file.FullName -Destination $destination
            }
        } else {
            Copy-Item -LiteralPath $path -Destination $backup
        }
    }
}
Write-Host "Source backup created: $backup"
Write-Host "Keep this backup private: an existing project may contain signing keys."
# Only source files shipped in this update are copied. No caches, local SDK
# paths, signing keys, or user data are deleted or overwritten.
foreach ($item in @("lib", "test", "android", "windows")) {
    $folder = Join-Path $source $item
    foreach ($file in Get-ChildItem -LiteralPath $folder -Recurse -File) {
        $relative = $file.FullName.Substring($source.Length + 1)
        if ($relative -match '(^|\\)(build|\.gradle|\.kotlin|\.dart_tool|ephemeral)(\\|$)') { continue }
        if ($file.Name -in @("local.properties", "key.properties") -or
            $file.Extension -in @(".jks", ".keystore", ".pfx", ".p12")) { continue }
        $destination = Join-Path $Target $relative
        New-Item -ItemType Directory -Force -Path (Split-Path -Parent $destination) | Out-Null
        Copy-Item -LiteralPath $file.FullName -Destination $destination -Force
    }
}
foreach ($item in @("pubspec.yaml", "pubspec.lock", "analysis_options.yaml", "README_RU.md", "TEST_REPORT.md")) {
    Copy-Item -LiteralPath (Join-Path $source $item) -Destination (Join-Path $Target $item) -Force
}
Write-Host "Update applied. Application data was not touched."
Write-Host "Next commands:"
Write-Host "  cd `"$Target`""
Write-Host "  flutter pub get"
Write-Host "  flutter analyze"
Write-Host "  flutter test"
Write-Host "  flutter run -d windows"
