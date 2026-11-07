#Requires -Version 7.0
<#
  build-apk.ps1 - builds MovieCrawler.apk with the plain SDK tools.

  No Gradle, no AndroidX, no Kotlin: aapt2 -> javac -> d8 -> zipalign -> apksigner.
  The whole app is one Activity + one scraper + the single-file HTML UI.

  Usage:  pwsh -File .\build-apk.ps1
#>
[CmdletBinding()]
param(
  [string]$BuildTools = '',
  [string]$Platform   = 'android-34'
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

function Step($msg) { Write-Host "`n== $msg" -ForegroundColor Cyan }
function Fail($msg) { Write-Host "FAILED: $msg" -ForegroundColor Red; exit 1 }

$Root = $PSScriptRoot
$Sdk  = $env:ANDROID_HOME
if (-not $Sdk -or -not (Test-Path $Sdk)) { Fail 'ANDROID_HOME is not set / not found.' }

if (-not $BuildTools) {
  $BuildTools = Get-ChildItem (Join-Path $Sdk 'build-tools') -Directory |
                Sort-Object { [version]$_.Name } -Descending |
                Select-Object -First 1 -ExpandProperty Name
}
$Bt  = Join-Path $Sdk "build-tools\$BuildTools"
$Jar = Join-Path $Sdk "platforms\$Platform\android.jar"
if (-not (Test-Path $Jar)) { Fail "android.jar not found: $Jar" }

$Aapt2     = Join-Path $Bt 'aapt2.exe'
$D8        = Join-Path $Bt 'd8.bat'
$ZipAlign  = Join-Path $Bt 'zipalign.exe'
$ApkSigner = Join-Path $Bt 'apksigner.bat'
foreach ($t in @($Aapt2, $D8, $ZipAlign, $ApkSigner)) {
  if (-not (Test-Path $t)) { Fail "missing tool: $t" }
}

$Src   = Join-Path $Root 'android'
$Out   = Join-Path $Src 'build'
$Apk   = Join-Path $Root 'MovieCrawler.apk'
$Html  = Join-Path $Root 'moviezda-crawler.html'

if (-not (Test-Path $Html)) { Fail 'moviezda-crawler.html not found next to this script.' }
if (Test-Path $Out) { Remove-Item $Out -Recurse -Force }
New-Item -ItemType Directory -Path $Out | Out-Null
New-Item -ItemType Directory -Path (Join-Path $Out 'gen')     | Out-Null
New-Item -ItemType Directory -Path (Join-Path $Out 'classes') | Out-Null
New-Item -ItemType Directory -Path (Join-Path $Out 'dex')     | Out-Null

Write-Host "build-tools : $BuildTools"
Write-Host "platform    : $Platform"
Write-Host "output      : $Apk"

# ---------------------------------------------------------------- assets
Step 'staging assets'
$Assets = Join-Path $Src 'assets'
if (-not (Test-Path $Assets)) { New-Item -ItemType Directory -Path $Assets | Out-Null }
Copy-Item $Html (Join-Path $Assets 'moviezda-crawler.html') -Force
Write-Host ("  moviezda-crawler.html  {0:N0} KB" -f ((Get-Item $Html).Length / 1KB))

# ---------------------------------------------------------------- resources
Step 'aapt2 compile'
& $Aapt2 compile --dir (Join-Path $Src 'res') -o (Join-Path $Out 'res.zip')
if ($LASTEXITCODE -ne 0) { Fail 'aapt2 compile' }

Step 'aapt2 link'
$Base = Join-Path $Out 'base.apk'
& $Aapt2 link `
  -o $Base `
  -I $Jar `
  --manifest (Join-Path $Src 'AndroidManifest.xml') `
  (Join-Path $Out 'res.zip') `
  -A $Assets `
  --java (Join-Path $Out 'gen') `
  --min-sdk-version 24 `
  --target-sdk-version 34
if ($LASTEXITCODE -ne 0) { Fail 'aapt2 link' }

# ---------------------------------------------------------------- java
Step 'javac'
$Sources = @()
$Sources += Get-ChildItem (Join-Path $Src 'java') -Recurse -Filter *.java | ForEach-Object { $_.FullName }
$Sources += Get-ChildItem (Join-Path $Out 'gen')  -Recurse -Filter *.java | ForEach-Object { $_.FullName }

& javac -encoding UTF-8 -nowarn -source 8 -target 8 `
  -bootclasspath $Jar `
  -d (Join-Path $Out 'classes') `
  @Sources 2>&1 | Where-Object { $_ -notmatch 'bootstrap class path|source value 8|target value 8|deprecat' } | ForEach-Object { Write-Host "  $_" }
if ($LASTEXITCODE -ne 0) { Fail 'javac' }

# ---------------------------------------------------------------- dex
Step 'd8'
$Classes = Get-ChildItem (Join-Path $Out 'classes') -Recurse -Filter *.class | ForEach-Object { $_.FullName }
if (-not $Classes) { Fail 'no .class files produced' }
& $D8 --release --min-api 24 --lib $Jar --output (Join-Path $Out 'dex') @Classes
if ($LASTEXITCODE -ne 0) { Fail 'd8' }

# ---------------------------------------------------------------- package
Step 'packaging classes.dex'
Add-Type -AssemblyName System.IO.Compression.FileSystem
$zip = [System.IO.Compression.ZipFile]::Open($Base, 'Update')
try {
  $dex = Join-Path $Out 'dex\classes.dex'
  if (-not (Test-Path $dex)) { Fail 'classes.dex missing' }
  $zip.Entries | Where-Object { $_.FullName -eq 'classes.dex' } | ForEach-Object { $_.Delete() }
  $null = [System.IO.Compression.ZipFileExtensions]::CreateEntryFromFile(
            $zip, $dex, 'classes.dex', [System.IO.Compression.CompressionLevel]::Optimal)
}
finally { $zip.Dispose() }

Step 'zipalign'
$Aligned = Join-Path $Out 'aligned.apk'
& $ZipAlign -f -p 4 $Base $Aligned
if ($LASTEXITCODE -ne 0) { Fail 'zipalign' }

# ---------------------------------------------------------------- sign
Step 'signing'
$Ks = Join-Path $Src 'debug.keystore'
if (-not (Test-Path $Ks)) {
  & keytool -genkeypair -v `
    -keystore $Ks -storepass android -keypass android `
    -alias androiddebugkey -keyalg RSA -keysize 2048 -validity 10000 `
    -dname "CN=Android Debug,O=Android,C=US" 2>&1 | Out-Null
  if ($LASTEXITCODE -ne 0) { Fail 'keytool' }
}

if (Test-Path $Apk) { Remove-Item $Apk -Force }
& $ApkSigner sign --ks $Ks --ks-pass pass:android --key-pass pass:android `
  --v1-signing-enabled true --v2-signing-enabled true `
  --out $Apk $Aligned
if ($LASTEXITCODE -ne 0) { Fail 'apksigner sign' }

& $ApkSigner verify --print-certs $Apk | Select-Object -First 6 | ForEach-Object { Write-Host "  $_" }
if ($LASTEXITCODE -ne 0) { Fail 'apksigner verify' }

# ---------------------------------------------------------------- report
Step 'result'
$fi = Get-Item $Apk
Write-Host ("  {0}" -f $fi.FullName) -ForegroundColor Green
Write-Host ("  {0:N0} KB" -f ($fi.Length / 1KB)) -ForegroundColor Green

$badging = & $Aapt2 dump badging $Apk 2>$null
$badging | Where-Object { $_ -match '^(package|application-label|launchable-activity|sdkVersion|targetSdkVersion)' } |
  ForEach-Object { Write-Host "  $_" }

Write-Host ''
Write-Host '  install:  adb install -r MovieCrawler.apk' -ForegroundColor Yellow
