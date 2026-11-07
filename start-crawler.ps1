<#
  moviezda-crawler  -  local resolver + static server

  Why this file exists:
    A browser page (even a local file:// page) is NOT allowed to read
    https://moviezda.me or https://isaidub.green with fetch(). The sites send
    no CORS headers, so every XMLHttpRequest from the HTML tool is blocked by
    the browser. This tiny local service does the HTTP work, follows the
    redirect chain with an explicit host allow-list (so ad/popunder domains
    are never touched) and hands the HTML tool clean JSON.

  Usage:
      pwsh -File .\start-crawler.ps1
      pwsh -File .\start-crawler.ps1 -RebuildIndex
      pwsh -File .\start-crawler.ps1 -RebuildIndex -Site isaidub
      pwsh -File .\start-crawler.ps1 -Movie /kumbaari-2024-tamil-movie/
      pwsh -File .\start-crawler.ps1 -Movie /movie/red-eye-2005-tamil-dubbed-movie/ -Site isaidub
#>

#Requires -Version 7.0
[CmdletBinding()]
param(
  [int]$Port = 8787,
  [switch]$RebuildIndex,
  [ValidateSet('moviezda','isaidub')][string]$Site = 'moviezda',
  [string]$Movie,
  [string]$Quality,
  [switch]$Download,
  [int]$MaxMB = 0,
  [switch]$NoBrowser
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$Root      = $PSScriptRoot
$CacheDir  = Join-Path $Root 'cache'
$IndexFile = Join-Path $CacheDir 'index.json'
$IsaiIndexFile = Join-Path $CacheDir 'isai-index.json'
$HtmlFile  = Join-Path $Root 'moviezda-crawler.html'
$Base      = 'https://moviezda.me'
$IsaiBase  = 'https://isaidub.green'
$UA        = 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/126.0.0.0 Safari/537.36'

# Only these hosts are ever contacted. Everything else (ad networks,
# popunders, "your download is ready" scams) is refused by design.
$AllowedHosts = @(
  'moviezda.me',
  'www.moviezda.me',
  'download.moviespage.xyz',
  'movies.downloadpage.xyz',
  'download.fastbytes.xyz',
  'play.onestream.today',
  'isaidub.green',
  'www.isaidub.green',
  'dubpage.xyz',
  'www.dubpage.xyz',
  'dubmv.xyz',
  'www.dubmv.xyz',
  'uptodub.ch',
  'dub.uptodub.ch',
  'isaidub.dad',
  'dubshare.one'
)

# Metadata-only hosts used for poster lookup. These are NEVER part of the
# download chain - they only serve title -> poster resolution.
$MetaHosts = @(
  'en.wikipedia.org',
  'upload.wikimedia.org',
  'commons.wikimedia.org',
  'api.tvmaze.com',
  'static.tvmaze.com'
)
$PosterFile = Join-Path $CacheDir 'posters.json'

if (-not (Test-Path $CacheDir)) { New-Item -ItemType Directory -Path $CacheDir | Out-Null }

# ----------------------------------------------------------------------------
# HTTP
# ----------------------------------------------------------------------------
Add-Type -AssemblyName System.Net.Http
Add-Type -AssemblyName System.Web

$script:Cookies = [System.Net.CookieContainer]::new()
$script:Handler = [System.Net.Http.HttpClientHandler]::new()
$script:Handler.AllowAutoRedirect    = $false
$script:Handler.CookieContainer      = $script:Cookies
$script:Handler.AutomaticDecompression = [System.Net.DecompressionMethods]::GZip -bor [System.Net.DecompressionMethods]::Deflate
$script:Http = [System.Net.Http.HttpClient]::new($script:Handler)
$script:Http.Timeout = [TimeSpan]::FromSeconds(50)
$null = $script:Http.DefaultRequestHeaders.UserAgent.TryParseAdd($UA)
$null = $script:Http.DefaultRequestHeaders.Accept.TryParseAdd('text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8')
$null = $script:Http.DefaultRequestHeaders.AcceptLanguage.TryParseAdd('en-US,en;q=0.9')

function Test-HostAllowed {
  param([string]$Url)
  try { $h = ([System.Uri]$Url).Host } catch { return $false }
  foreach ($a in $AllowedHosts) {
    if ($h -eq $a) { return $true }
    if ($h.EndsWith('.r2.cloudflarestorage.com')) { return $true }
    if ($h.EndsWith('.uptodub.ch')) { return $true }
    if ($h.EndsWith('.isaidub.dad')) { return $true }
    if ($h.EndsWith('.dubshare.one')) { return $true }
  }
  return $false
}

function Invoke-Http {
  param(
    [Parameter(Mandatory)][string]$Url,
    [ValidateSet('GET','HEAD')][string]$Method = 'GET',
    [int]$Range = -1,
    [int64]$MaxBytes = -1
  )
  if (-not (Test-HostAllowed $Url)) { throw "Host not allowed: $Url" }

  $req = [System.Net.Http.HttpRequestMessage]::new([System.Net.Http.HttpMethod]::$Method, $Url)
  if ($Range -ge 0) { $req.Headers.Range = [System.Net.Http.Headers.RangeHeaderValue]::new($Range, $Range + 1) }

  $resp = $script:Http.SendAsync($req).GetAwaiter().GetResult()
  try {
    if ($MaxBytes -ge 0 -and $Method -eq 'GET') {
      # capped read: link probes must never pull a whole movie into memory,
      # even if the server ignores Range
      $ms  = [System.IO.MemoryStream]::new()
      $in  = $resp.Content.ReadAsStreamAsync().GetAwaiter().GetResult()
      $buf = [byte[]]::new(65536)
      $got = [int64]0
      while ($got -lt $MaxBytes) {
        $want = [int][Math]::Min($buf.Length, $MaxBytes - $got)
        $n = $in.Read($buf, 0, $want)
        if ($n -le 0) { break }
        $ms.Write($buf, 0, $n)
        $got += $n
      }
      $in.Dispose()
      $bytes = $ms.ToArray()
      $ms.Dispose()
    } else {
      $bytes = $resp.Content.ReadAsByteArrayAsync().GetAwaiter().GetResult()
    }
    $loc   = if ($resp.Headers.Location) { $resp.Headers.Location.ToString() } else { $null }
    $hdrs  = @{}
    foreach ($h in $resp.Headers)          { $hdrs[$h.Key.ToLowerInvariant()]  = ($h.Value -join ', ') }
    foreach ($h in $resp.Content.Headers)  { $hdrs[$h.Key.ToLowerInvariant()]  = ($h.Value -join ', ') }

    [pscustomobject]@{
      Url         = $Url
      Status      = [int]$resp.StatusCode
      Location    = $loc
      ContentType = if ($hdrs['content-type']) { $hdrs['content-type'] } else { '' }
      Headers     = $hdrs
      Bytes       = $bytes
      Text        = if ($Method -eq 'GET') { [System.Text.Encoding]::UTF8.GetString($bytes) } else { '' }
    }
  }
  finally { $resp.Dispose(); $req.Dispose() }
}

function Get-Html {
  param([string]$Url)
  $r = Invoke-Http -Url $Url -Method GET
  if ($r.Status -ne 200) { throw "GET $Url -> HTTP $($r.Status)" }
  $r.Text
}

# ----------------------------------------------------------------------------
# Parsing
# ----------------------------------------------------------------------------
function ConvertTo-Text {
  param([string]$Html)
  $s = [regex]::Replace($Html, '(?s)<[^>]+>', ' ')
  $s = [System.Net.WebUtility]::HtmlDecode($s)
  [regex]::Replace($s, '\s+', ' ').Trim()
}

function Get-Anchors {
  param([string]$Html)
  $out = [System.Collections.Generic.List[object]]::new()
  foreach ($m in [regex]::Matches($Html, '(?s)<a\b([^>]*)>(.*?)</a>')) {
    $attrs = $m.Groups[1].Value
    $href  = [regex]::Match($attrs, 'href\s*=\s*"([^"]*)"').Groups[1].Value
    if (-not $href) { $href = [regex]::Match($attrs, "href\s*=\s*'([^']*)'").Groups[1].Value }
    $out.Add([pscustomobject]@{
      Href  = [System.Net.WebUtility]::HtmlDecode($href)
      Class = [regex]::Match($attrs, 'class\s*=\s*"([^"]*)"').Groups[1].Value
      Text  = ConvertTo-Text $m.Groups[2].Value
    })
  }
  $out
}

# <div class="f"> <img ...> <a href="/x/">Title</a> </div>
function Get-FolderLinks {
  param([string]$Html)
  $out = [System.Collections.Generic.List[object]]::new()
  foreach ($m in [regex]::Matches($Html, '(?s)<div class="f">(.*?)</div>')) {
    $a = Get-Anchors $m.Groups[1].Value | Where-Object { $_.Href -and $_.Href -ne '#' } | Select-Object -First 1
    if ($a) { $out.Add([pscustomobject]@{ Href = $a.Href; Text = $a.Text }) }
  }
  $out
}

function Get-DetailFields {
  param([string]$Html)
  $d = @{}
  foreach ($m in [regex]::Matches($Html, '(?s)<div class="details">\s*<strong>([^<]+)</strong>\s*(.*?)</div>')) {
    $k = ($m.Groups[1].Value -replace ':', '').Trim()
    $v = ConvertTo-Text $m.Groups[2].Value
    if ($k) { $d[$k] = $v }
  }
  $d
}

function Get-PageTitle {
  param([string]$Html)
  $m = [regex]::Match($Html, '(?s)<h1[^>]*>(.*?)</h1>')
  if ($m.Success) { return (ConvertTo-Text $m.Groups[1].Value) }
  $t = [regex]::Match($Html, '(?s)<title>(.*?)</title>')
  (ConvertTo-Text $t.Groups[1].Value)
}

function Get-FirstHref {
  param($Anchors, [string]$Pattern)
  foreach ($a in @($Anchors)) {
    if ($a -and $a.Href -and $a.Href -match $Pattern) { return $a.Href }
  }
  return ''
}

function Format-Quality {
  param([string]$Label)
  if (-not $Label) { return '' }
  $m = [regex]::Match($Label, '\(([^()]*)\)\s*$')
  if ($m.Success) { return $m.Groups[1].Value.Trim() }
  $m = [regex]::Match($Label, '(?i)(\d{3,4}p(?:\s*(?:HD|WEB-?DL|HDRip))?)')
  if ($m.Success) { return $m.Groups[1].Value.Trim() }
  $Label.Trim()
}

function Get-QualityLabel {
  param([string]$Html, [string]$Fallback)
  $t = Get-PageTitle $Html
  foreach ($candidate in @($t, $Fallback)) {
    if (-not $candidate) { continue }
    $m = [regex]::Match($candidate, '\(([^()]*)\)\s*$')
    if ($m.Success) { return $m.Groups[1].Value.Trim() }
  }
  if ($Fallback -match '(?i)(\d{3,4}p)') { return $Matches[1].ToUpperInvariant() }
  $Fallback
}

# ----------------------------------------------------------------------------
# isaiDub parsing (isaidub.green)
#
# Same template family as moviezda but different wrappers:
#   listing/category : <div class="folder"> <a href="/movie/<slug>/">Title (Year)</a>
#   movie page       : <div class="folder"> -> /movie/<id>/  (collection / season)
#   collection page  : <div class="folder"> -> /movie/<id>/  (quality)
#   quality page     : <div class="f"><div class="mv-content"> ... <a class="coral"
#                      href="/download/page/<id>/">name</a> <li>File Size: ..</li>
#                      <li>Download Format: ..</li> ...  (one block per file/episode)
#   download page    : /download/page/<id>/  ->  .details fields +
#                      .dlink a -> https://dubpage.xyz/download/view/<id>
# ----------------------------------------------------------------------------
function Get-IsaiFolderLinks {
  param([string]$Html)
  # nav/listing pages wrap child links in <div class="folder">, but the A-Z
  # listing pages use <div class="f"> for the same job - accept both.
  # Children are always /movie/... links; /download/page/ file links are
  # filtered out here so they can never be mistaken for folders.
  $out = [System.Collections.Generic.List[object]]::new()
  foreach ($m in [regex]::Matches($Html, '(?s)<div class="(?:folder|f)">(.*?)</div>')) {
    $a = Get-Anchors $m.Groups[1].Value | Where-Object { $_.Href -match '^/movie/' } | Select-Object -First 1
    if ($a) { $out.Add([pscustomobject]@{ Href = $a.Href; Text = $a.Text }) }
  }
  $out
}

# Every <a class="coral" href="/download/page/<id>/"> on a quality page is one
# downloadable file (a movie encode, or one episode of a web series).  Its
# File Size / Download Format sit in <li> siblings AFTER the anchor, inside
# the same .mv-content block - i.e. between this anchor and the next coral one.
function Get-IsaiFiles {
  param([string]$Html)
  $out  = [System.Collections.Generic.List[object]]::new()
  $hits = [System.Collections.Generic.List[object]]::new()
  foreach ($m in [regex]::Matches($Html, '(?s)<a\b[^>]*>.*?</a>')) {
    $attrs = [regex]::Match($m.Value, '<a\b([^>]*)>').Groups[1].Value
    if ($attrs -notmatch 'coral') { continue }
    $href = [regex]::Match($attrs, 'href\s*=\s*"([^"]*)"').Groups[1].Value
    if (-not $href) { $href = [regex]::Match($attrs, "href\s*=\s*'([^']*)'").Groups[1].Value }
    if (-not $href -or $href -notmatch '/download/page/') { continue }
    $hits.Add([pscustomobject]@{ Index = $m.Index; Length = $m.Length; End = $m.Index + $m.Length; Value = $m.Value; Href = [System.Net.WebUtility]::HtmlDecode($href) })
  }
  for ($i = 0; $i -lt $hits.Count; $i++) {
    $h = $hits[$i]
    $segEnd = if ($i + 1 -lt $hits.Count) { $hits[$i + 1].Index } else { [Math]::Min($Html.Length, $h.End + 6000) }
    $segLen = [Math]::Max(0, [Math]::Min($segEnd - $h.End, 5000))
    $seg = if ($segLen -gt 0) { ConvertTo-Text $Html.Substring($h.End, $segLen) } else { '' }

    $size = ''; $fmt = ''
    $sm = [regex]::Match($seg, 'File Size:\s*([0-9][0-9.,]*\s*[KMGT]?B)')
    if ($sm.Success) { $size = $sm.Groups[1].Value.Trim() }
    $fm = [regex]::Match($seg, 'Download Format:\s*([A-Za-z0-9]+)')
    if ($fm.Success) { $fmt = $fm.Groups[1].Value.Trim() }

    $out.Add([pscustomobject]@{ Href = $h.Href; Text = (ConvertTo-Text $h.Value); Size = $size; Format = $fmt })
  }
  $out
}

# ----------------------------------------------------------------------------
# Movie tree
# ----------------------------------------------------------------------------
function Get-MovieTree {
  param(
    [Parameter(Mandatory)][string]$Path,
    [int]$Depth = 0,
    [string]$Section = '',
    [string]$Quality = ''
  )
  if ($Depth -gt 4) { return @() }

  $url = if ($Path -match '^https?://') { $Path } else { $Base + $Path }
  if (-not (Test-HostAllowed $url)) { throw "Blocked host: $url" }

  $html = Get-Html $url
  $title = Get-PageTitle $html

  $folders = @(Get-FolderLinks $html)
  $coral   = @(Get-Anchors $html | Where-Object { $_.Class -match 'coral' -and $_.Href })

  $items = [System.Collections.Generic.List[object]]::new()

  if ($coral.Count -gt 0) {
    # leaf: /download/<slug>/
    $label = if ($Quality) { Format-Quality $Quality } else { Get-QualityLabel -Html $html -Fallback $title }
    if (-not $label -or $label -eq $title) {
      $m = [regex]::Match($Path, '(?i)(\d{3,4}p)')
      if ($m.Success) { $label = $m.Groups[1].Value.ToUpperInvariant() }
    }
    foreach ($c in $coral) {
      $vf = $label
      $mm = [regex]::Match($c.Text, '\((\d+(?:\.\d+)?\s*[MG]B)\)')
      if ($mm.Success) { $vf = "$label · $($mm.Groups[1].Value)" }
      $items.Add([pscustomobject]@{
        Section = $Section
        Quality = $vf
        File    = $c.Text
        Size    = ''
        Format  = ''
        DPath   = $c.Href
        Depth   = $Depth
      })
    }
    return $items
  }

  if ($folders.Count -eq 0) { return $items }

  foreach ($f in $folders) {
    $isQuality = $f.Text -match '(?i)\(\s*\d{3,4}p|\(\s*(HD|4K)|720p|1080p|360p|480p|WEB-?DL|HDRip'
    if ($isQuality) {
      $children = Get-MovieTree -Path $f.Href -Depth ($Depth + 1) -Section $Section -Quality $f.Text
    } else {
      $children = Get-MovieTree -Path $f.Href -Depth ($Depth + 1) -Section $f.Text -Quality ''
    }
    foreach ($ch in $children) { $items.Add($ch) }
  }
  return $items
}

function Get-IsaiTree {
  param(
    [Parameter(Mandatory)][string]$Path,
    [int]$Depth = 0,
    [string]$Section = '',
    [string]$Quality = ''
  )
  if ($Depth -gt 5) { return @() }

  $url = if ($Path -match '^https?://') { $Path } else { $IsaiBase + $Path }
  if (-not (Test-HostAllowed $url)) { throw "Blocked host: $url" }

  $html = Get-Html $url

  $files = @(Get-IsaiFiles $html)
  if ($files.Count -gt 0) {
    $label = if ($Quality) { Format-Quality $Quality } else { Get-QualityLabel -Html $html -Fallback '' }
    if (-not $label) {
      $m = [regex]::Match($Path, '(?i)(\d{3,4}p)')
      if ($m.Success) { $label = $m.Groups[1].Value.ToUpperInvariant() }
    }
    $items = [System.Collections.Generic.List[object]]::new()
    foreach ($f in $files) {
      $vf = $label
      if ($f.Size) { $vf = "$label · $($f.Size)" }
      $items.Add([pscustomobject]@{
        Section = $Section
        Quality = $vf
        File    = $f.Text
        Size    = $f.Size
        Format  = $f.Format
        DPath   = $f.Href
        Depth   = $Depth
      })
    }
    return $items
  }

  $folders = @(Get-IsaiFolderLinks $html)
  if ($folders.Count -eq 0) { return @() }

  $items = [System.Collections.Generic.List[object]]::new()
  foreach ($f in $folders) {
    $isQuality = $f.Text -match '(?i)\(\s*\d{3,4}p|\(\s*(HD|4K)|720p|1080p|360p|480p|WEB-?DL|HDRip'
    if ($isQuality) {
      $children = Get-IsaiTree -Path $f.Href -Depth ($Depth + 1) -Section $Section -Quality $f.Text
    } else {
      $children = Get-IsaiTree -Path $f.Href -Depth ($Depth + 1) -Section $f.Text -Quality ''
    }
    foreach ($ch in $children) { $items.Add($ch) }
  }
  return $items
}

function Get-VariantDetails {
  param([string]$DownloadPath, [string]$Site = 'moviezda')
  $base = if ($Site -eq 'isaidub') { $IsaiBase } else { $Base }
  $url = if ($DownloadPath -match '^https?://') { $DownloadPath } else { $base + $DownloadPath }
  $html = Get-Html $url
  $f = Get-DetailFields $html

  if ($Site -eq 'isaidub') {
    $server = Get-FirstHref -Anchors (Get-Anchors $html) -Pattern 'dubpage\.xyz/download/view/\d+'
    $watch  = Get-FirstHref -Anchors (Get-Anchors $html) -Pattern 'dub\.onestream\.today'
  } else {
    $server = Get-FirstHref -Anchors (Get-Anchors $html) -Pattern '/download/file/\d+'
    $watch  = Get-FirstHref -Anchors (Get-Anchors $html) -Pattern 'onestream\.today'
  }

  [pscustomobject]@{
    Page       = $DownloadPath
    File       = if ($f['File Name']) { $f['File Name'] } else { '' }
    Size       = if ($f['File Size']) { $f['File Size'] } else { '' }
    Resolution = if ($f['Video Resolution']) { $f['Video Resolution'] } elseif ($f['Video Size']) { $f['Video Size'] } else { '' }
    Duration   = if ($f['Duration']) { $f['Duration'] } else { '' }
    Format     = if ($f['Download Format']) { $f['Download Format'] } elseif ($f['Format']) { $f['Format'] } else { '' }
    Added      = if ($f['Added On']) { $f['Added On'] } else { '' }
    Server     = $server
    Watch      = $watch
  }
}

function Resolve-Movie {
  param([string]$Path, [string]$Site = 'moviezda')
  $isai = ($Site -eq 'isaidub')
  $base = if ($isai) { $IsaiBase } else { $Base }
  $tree = if ($isai) { @(Get-IsaiTree -Path $Path) } else { @(Get-MovieTree -Path $Path) }
  $out  = [System.Collections.Generic.List[object]]::new()

  foreach ($t in $tree) {
    try   { $d = Get-VariantDetails -DownloadPath $t.DPath -Site $Site }
    catch {
      if ($env:MOVIEZDA_DEBUG) { Write-Host "  ! $($t.DPath): $($_.Exception.Message)" -ForegroundColor Red }
      $d = [pscustomobject]@{ Page=$t.DPath; File=$t.File; Size=''; Resolution=''; Duration=''; Format=''; Added=''; Server=''; Watch='' }
    }

    # isaiDub: if the download page had no dubpage link, fall back to the
    # download page itself - the chain resolver knows how to walk it.
    $server = $d.Server
    if ($isai -and -not $server) { $server = $base + $t.DPath }

    $out.Add([pscustomobject]@{
      section    = $t.Section
      quality    = $t.Quality
      file       = if ($d.File) { $d.File } else { $t.File }
      size       = if ($d.Size) { $d.Size } else { $t.Size }
      resolution = $d.Resolution
      duration   = $d.Duration
      format     = if ($d.Format) { $d.Format } else { $t.Format }
      added      = $d.Added
      page       = $base + $t.DPath
      server     = $server
      watch      = $d.Watch
    })
  }
  $out
}

# ----------------------------------------------------------------------------
# Resolve the download chain (ad-free)
# ----------------------------------------------------------------------------
function Resolve-Download {
  param([string]$Start, [string]$Site = 'moviezda')

  $chain = [System.Collections.Generic.List[object]]::new()
  $base  = if ($Site -eq 'isaidub') { $IsaiBase } else { $Base }
  $url   = if ($Start -match '^https?://') { $Start } else { $base + $Start }

  for ($i = 0; $i -lt 12; $i++) {
    if (-not (Test-HostAllowed $url)) {
      $chain.Add([pscustomobject]@{ url = $url; status = 0; note = 'BLOCKED (not in allow-list)' })
      return [pscustomobject]@{ ok = $false; final = $null; chain = $chain; error = "Blocked redirect to $url" }
    }

    # Final CDN object: never download it, just read the first 2 bytes.
    #   moviezda -> *.r2.cloudflarestorage.com/...   (S3 signed URL)
    #   isaiDub  -> *.uptodub.ch/files/... or any *.dubshare.one/*.mp4 etc.
    $isCdn = $url -match '\.r2\.cloudflarestorage\.com/' -or $url -match '\.uptodub\.ch/files/'
    if (-not $isCdn) {
      try { $isCdn = ([System.Uri]$url).AbsolutePath -match '\.(mp4|mkv|avi|webm|m4v|flv|mov|ts|mpg|mpeg|3gp|wmv)$' }
      catch { $isCdn = $false }
    }
    if ($isCdn) {
      $r = Invoke-Http -Url $url -Method GET -Range 0 -MaxBytes 1048576
      $total = $null
      if ($r.Headers['content-range'] -match '/(\d+)$') { $total = [int64]$Matches[1] }
      $chain.Add([pscustomobject]@{ url = $url; status = $r.Status; note = 'direct CDN file' })
      return [pscustomobject]@{
        ok = $true; final = $url; status = $r.Status; type = $r.ContentType; bytes = $total; chain = $chain
      }
    }

    $r = Invoke-Http -Url $url -Method GET
    $chain.Add([pscustomobject]@{ url = $url; status = $r.Status; note = $r.ContentType })

    if ($r.Status -in 301,302,303,307,308 -and $r.Location) {
      $url = [System.Uri]::new([System.Uri]$url, $r.Location).AbsoluteUri
      continue
    }

    # HTML interstitial: pull the next real link
    if ($r.ContentType -match 'text/html') {
      $next = $null
      $anchors = Get-Anchors $r.Text
      if ($url -match 'isaidub\.green/download/') {
        $next = Get-FirstHref -Anchors $anchors -Pattern 'dubpage\.xyz/download/view/\d+'
      }
      elseif ($url -match 'dubpage\.xyz') {
        $next = Get-FirstHref -Anchors $anchors -Pattern 'dubmv\.xyz/download/file/\d+'
      }
      elseif ($url -match 'dubmv\.xyz') {
        # two file backends seen: dub.uptodub.ch/download.php?dl=.. and
        # download.isaidub.dad/download.php?url=..  (watch links are onestream - skipped)
        $next = Get-FirstHref -Anchors $anchors -Pattern '(dub\.uptodub\.ch|download\.isaidub\.dad)/download\.php'
      }
      elseif ($url -match 'moviezda\.me/download/') {
        $next = Get-FirstHref -Anchors $anchors -Pattern 'download\.moviespage\.xyz/download/file/\d+'
      }
      elseif ($url -match 'moviespage\.xyz') {
        $next = Get-FirstHref -Anchors $anchors -Pattern 'movies\.downloadpage\.xyz/download/page/\d+'
      }
      elseif ($url -match 'downloadpage\.xyz') {
        $next = Get-FirstHref -Anchors $anchors -Pattern 'fastbytes\.xyz/download\.php'
      }
      if ($next) { $url = $next; continue }
      return [pscustomobject]@{ ok=$false; final=$null; chain=$chain; error='Could not find the next download link.' }
    }

    # Binary / media reached
    $total = $null
    if ($r.Headers['content-range'] -match '/(\d+)$') { $total = [int64]$Matches[1] }
    elseif ($r.Headers['content-length'])            { $total = [int64]$r.Headers['content-length'] }

    return [pscustomobject]@{
      ok     = $true
      final  = $url
      status = $r.Status
      type   = $r.ContentType
      bytes  = $total
      chain  = $chain
    }
  }

  [pscustomobject]@{ ok=$false; final=$null; chain=$chain; error='Too many hops.' }
}

# ----------------------------------------------------------------------------
# Poster lookup - keyless metadata sources (wikipedia / tvmaze)
# ----------------------------------------------------------------------------
$script:Posters = @{}
if (Test-Path $PosterFile) {
  try { $script:Posters = Get-Content $PosterFile -Raw | ConvertFrom-Json -AsHashtable } catch { $script:Posters = @{} }
}
$script:PosterDirty = $false

function Invoke-MetaHttp {
  param([Parameter(Mandatory)][string]$Url, [int]$TimeoutSec = 12)
  try { $h = ([System.Uri]$Url).Host } catch { throw "bad url" }
  $ok = $false
  foreach ($a in $MetaHosts) { if ($h -eq $a) { $ok = $true; break } }
  if (-not $ok) { throw "Meta host not allowed: $h" }

  # metadata APIs rate-limit aggressively - retry 429/5xx with backoff
  for ($attempt = 0; $attempt -lt 3; $attempt++) {
    $req = [System.Net.Http.HttpRequestMessage]::new([System.Net.Http.HttpMethod]::GET, $Url)
    $cts = [System.Threading.CancellationTokenSource]::new([TimeSpan]::FromSeconds($TimeoutSec))
    try {
      $resp = $script:Http.SendAsync($req, $cts.Token).GetAwaiter().GetResult()
      try {
        $status = [int]$resp.StatusCode
        if (($status -eq 429 -or $status -ge 500) -and $attempt -lt 2) {
          $wait = ($attempt + 1) * 2
          try {
            $ra = $resp.Headers.RetryAfter
            if ($ra -and $null -ne $ra.Delta) { $wait = [int]$ra.Delta.Value.TotalSeconds }
          } catch { }
          Start-Sleep -Seconds ([Math]::Min(8, $wait))
          continue
        }
        $bytes = $resp.Content.ReadAsByteArrayAsync().GetAwaiter().GetResult()
        $ct = ''
        foreach ($hh in $resp.Content.Headers) { if ($hh.Key -eq 'content-type') { $ct = ($hh.Value -join ', ') } }
        return [pscustomobject]@{ Status = $status; ContentType = $ct; Text = [System.Text.Encoding]::UTF8.GetString($bytes) }
      } finally { $resp.Dispose() }
    } finally { $req.Dispose(); $cts.Dispose() }
  }
  return [pscustomobject]@{ Status = 0; ContentType = ''; Text = '' }
}

function Get-CleanTitle {
  param([string]$Title)
  $t = [string]$Title
  $t = $t -replace '\(\d{4}\)', ' '
  $t = $t -replace '\b(19|20)\d{2}\b', ' '
  $t = $t -replace '\b(tamil|telugu|hindi|english|kannada|malayalam|dubbed|dual|audio)\b', ' '
  $t = $t -replace '\b(download|isaidub|isaimini|moviezda|moviesda|isai\s?dub|full|movie|movies|web|series|episodes?|season|hq|hdrip|bluray|web-?dl|pre-?hd|hd|fhd|4k|480p|720p|1080p)\b', ' '
  $t = [regex]::Replace($t, '[^\w\s&]', ' ')
  [regex]::Replace($t, '\s+', ' ').Trim()
}

function Get-WikiPage {
  param([string]$Query)
  try {
    $qs  = [uri]::EscapeDataString($Query)
    $api = 'https://en.wikipedia.org/w/api.php?action=query&generator=search&gsrsearch=' + $qs +
           '&gsrnamespace=0&gsrlimit=1&prop=pageprops|images|categories&imlimit=50&pplimit=1&cllimit=50&format=json&formatversion=2&redirects=1'
    $r = Invoke-MetaHttp -Url $api
    if ($r.Status -ne 200) { return $null }
    $j    = $r.Text | ConvertFrom-Json
    $page = @($j.query.pages) | Select-Object -First 1
    if (-not $page) { return $null }
    $mp = $page.PSObject.Properties['missing']
    if ($mp -and $mp.Value) { return $null }
    return $page
  } catch { return $null }
}

function Test-FilmPage {
  param($Page)
  if (-not $Page) { return $false }
  # reject mythology/disambiguation hits - the image must come from a
  # film/TV article, otherwise we'd show a mountain or a coat of arms
  try {
    $cp = $Page.PSObject.Properties['categories']
    if (-not $cp -or -not $cp.Value) { return $true }   # no category data -> stay lenient
    $cats = @($cp.Value | ForEach-Object { [string]$_.title })
    foreach ($c in $cats) {
      if ($c -match '(?i)films?$|movies?$|television|series|miniseries|web|animated|documentary|silent|short film') { return $true }
    }
    return $false
  } catch { return $true }
}

function Get-WikiSuggestion {
  param([string]$Query)
  try {
    $qs  = [uri]::EscapeDataString($Query)
    $api = 'https://en.wikipedia.org/w/api.php?action=query&list=search&srsearch=' + $qs +
           '&srlimit=1&format=json&formatversion=2'
    $r = Invoke-MetaHttp -Url $api
    if ($r.Status -ne 200) { return $null }
    $j = $r.Text | ConvertFrom-Json
    $si = $j.query.searchinfo
    if ($si -and $si.suggestion) { return [string]$si.suggestion }
    return $null
  } catch { return $null }
}

function Get-WikiP18 {
  param([string]$Qid)
  try {
    $api = 'https://en.wikipedia.org/w/api.php?action=wbgetentities&ids=' + $Qid +
           '&props=claims&format=json'
    $r = Invoke-MetaHttp -Url $api
    if ($r.Status -ne 200) { return $null }
    $j   = $r.Text | ConvertFrom-Json
    $ent = $j.entities.PSObject.Properties[[string]$Qid].Value
    if (-not $ent) { return $null }
    $p18 = $ent.claims.P18
    if (-not $p18) { return $null }
    $v = @($p18)[0].mainsnak.datavalue.value
    if ($v) { return ([string]$v) -replace '^File:', '' }
    return $null
  } catch { return $null }
}

function Get-FileThumb {
  param([string]$FileName, [int]$Width = 480)
  try {
    $fn = [uri]::EscapeDataString("File:$FileName")
    $ii = 'https://en.wikipedia.org/w/api.php?action=query&titles=' + $fn +
          '&prop=imageinfo&iiprop=url&iiurlwidth=' + $Width + '&format=json&formatversion=2'
    $r2 = Invoke-MetaHttp -Url $ii
    if ($r2.Status -ne 200) { return $null }
    $j2   = $r2.Text | ConvertFrom-Json
    $info = @(@($j2.query.pages)[0].imageinfo) | Select-Object -First 1
    if (-not $info) { return $null }
    $u = $null
    if ($info.PSObject.Properties['thumburl']) { $u = $info.thumburl }
    if (-not $u -and $info.PSObject.Properties['url']) { $u = $info.url }
    if ($u) { return [string]$u }
    return $null
  } catch { return $null }
}

function Find-PosterWiki {
  param([string]$Title)
  $ym    = [regex]::Match($Title, '\b(19\d{2}|20\d{2})\b')
  $clean = Get-CleanTitle $Title
  if (-not $clean) { return $null }
  $query = $clean + $(if ($ym.Success) { ' ' + $ym.Value } else { '' })

  $page = Get-WikiPage $query
  if (-not $page -or -not (Test-FilmPage $page)) {
    # zero results OR a non-film hit (mythology/disambiguation) - let
    # wikipedia's own spell-check suggest a better query once
    $sug = Get-WikiSuggestion $query
    $p2  = if ($sug) { Get-WikiPage $sug } else { $null }
    $page = if ($p2 -and (Test-FilmPage $p2)) { $p2 } else { $null }
  }
  if (-not $page) { return $null }

  # 1) authoritative poster: the article's wikidata P18 (infobox image)
  try {
    $pp   = $page.PSObject.Properties['pageprops']
    $wbi  = if ($pp) { $pp.Value.PSObject.Properties['wikibase_item'] } else { $null }
    $qid  = if ($wbi) { [string]$wbi.Value } else { $null }
    if ($qid) {
      $f = Get-WikiP18 $qid
      if ($f) { $u = Get-FileThumb $f; if ($u) { return @{ img = $u } } }
    }
  } catch { }

  # 2) fallback: score image filenames - poster-like + title-token overlap
  $images = @()
  try {
    $ip = $page.PSObject.Properties['images']
    if ($ip) { $images = @($ip.Value | Where-Object { $_ }) }
  } catch { }
  if (-not $images) { return $null }

  $ttoks = @()
  foreach ($w in ([regex]::Replace($clean.ToLower(), '[^a-z0-9]+', ' ') -split '\s+')) {
    if ($w.Length -ge 2 -or $w -match '^\d+$') { $ttoks += $w }
  }
  $pick = $null; $best = -999
  foreach ($im in $images) {
    try {
      $it = $im.PSObject.Properties['title']
      if (-not $it) { continue }
      $n = [string]$it.Value -replace '^File:', ''
      $base = $n -replace '\.(jpe?g|png|webp)$', ''
      $fn  = ([regex]::Replace(([regex]::Replace($base.ToLower(), '(?<=\w)\.(?=\w)', '')), '[^a-z0-9]+', ' ')).Trim()
      $ftoks = @($fn -split '\s+' | Where-Object { $_ })
      $score = 0
      if ($n -match '(?i)poster') { $score += 4 }
      if ($n -match '(?i)theatrical|teaser|promotional|promote|banner|key art|one sheet') { $score += 2 }
      if ($n -match '(?i)screenshot|screen shot|cover|dvd|blu-?ray|logotype|poster for|advert|wallpaper|stills|behind|interview|event|launch|ceremony|award|red.?carpet|airport') { $score -= 10 }
      if ($n -match '(?i)\.(jpe?g|png|webp)$') { $score += 1 }
      $hit = 0; foreach ($w in $ttoks) { if ($ftoks -contains $w) { $hit++ } }
      $score += [Math]::Min(8, $hit * 2)
      $extra = $ftoks.Count - $ttoks.Count
      if ($extra -le 1 -and $hit -gt 0) { $score += 3 }
      elseif ($extra -gt 4) { $score -= 2 }
      if ($score -gt $best) { $best = $score; $pick = $n }
    } catch { continue }
  }
  if (-not $pick -or $best -le 0) { return $null }
  $u = Get-FileThumb $pick
  if ($u) { return @{ img = $u } }
  return $null
}

function Test-TvmazeMatch {
  param([string]$Title, $Show)
  if (-not $Show) { return $false }
  try {
    $name = [string]$Show.name
    if (-not $name) { return $false }
    $nset = @{}
    foreach ($w in ([regex]::Replace($name.ToLower(), '[^a-z0-9]+', ' ') -split '\s+')) {
      if ($w) { $nset[$w] = $true }
    }
    $clean = Get-CleanTitle $Title
    $ttoks = @([regex]::Replace($clean.ToLower(), '[^a-z0-9]+', ' ') -split '\s+' |
              Where-Object { $_.Length -ge 3 -and $_ -notmatch '^\d+$' })
    if ($ttoks.Count -gt 0) {
      foreach ($w in $ttoks) { if (-not $nset.ContainsKey($w)) { return $false } }
    }
    $ty = [regex]::Match($Title, '\b(19\d{2}|20\d{2})\b')
    $prem = $null
    $pp = $Show.PSObject.Properties['premiered']
    if ($pp -and $pp.Value) { $prem = [string]$pp.Value }
    if ($ty.Success -and $prem -and $prem.Length -ge 4) {
      $py = 0
      if ([int]::TryParse($prem.Substring(0, 4), [ref]$py)) {
        if ([Math]::Abs([int]$ty.Value - $py) -gt 2) { return $false }
      }
    }
    return $true
  } catch { return $false }
}

function Find-PosterTvmaze {
  param([string]$Title)
  try {
    $clean = Get-CleanTitle $Title
    if (-not $clean) { return $null }
    $qs = [uri]::EscapeDataString($clean)
    $r  = Invoke-MetaHttp -Url ('https://api.tvmaze.com/search/shows?q=' + $qs)
    if ($r.Status -ne 200) { return $null }
    $arr = @($r.Text | ConvertFrom-Json)
    foreach ($hit in @($arr | Select-Object -First 6)) {
      try {
        $show = $hit.show
        if (-not $show -or -not (Test-TvmazeMatch $Title $show)) { continue }
        $img = $show.image
        if (-not $img) { continue }
        $u = $null
        if ($img.PSObject.Properties['original']) { $u = $img.original }
        if (-not $u -and $img.PSObject.Properties['medium']) { $u = $img.medium }
        if ($u) { return @{ img = [string]$u } }
      } catch { continue }
    }
    return $null
  } catch { return $null }
}

function Get-PosterImage {
  param([string]$Title, [string]$Path)
  if (-not $Title) { return $null }
  $key = ($Title + '|' + $Path).ToLowerInvariant()
  if ($script:Posters.ContainsKey($key)) { return $script:Posters[$key] }
  if ($script:Posters.Count -gt 20000) { $script:Posters.Clear() }

  $series = ($Path -match 'series|season|episode') -or
            ($Title -match '(?i)\b(web\s*)?series\b|\bseason\s*\d|\bs\d{1,2}e\d')
  $img = $null
  try {
    if ($series) { $img = Find-PosterTvmaze $Title }
    if (-not $img)   { $img = Find-PosterWiki $Title }
    if (-not $img -and -not $series) { $img = Find-PosterTvmaze $Title }
  } catch { $img = $null }

  $script:Posters[$key] = $img
  $script:PosterDirty = $true
  return $img
}

function Save-Posters {
  if (-not $script:PosterDirty) { return }
  try {
    $script:Posters | ConvertTo-Json -Depth 4 -Compress | Set-Content -Path $PosterFile -Encoding utf8
    $script:PosterDirty = $false
  } catch { }
}

# ----------------------------------------------------------------------------
# Index
# ----------------------------------------------------------------------------
function Get-Index {
  if (Test-Path $IndexFile) {
    try { return @(Get-Content $IndexFile -Raw | ConvertFrom-Json) } catch { }
  }
  @()
}

function Build-Index {
  param([switch]$Fresh)

  $progressFile = Join-Path $CacheDir 'progress.json'

  Write-Host 'Building catalog (a-z)...' -ForegroundColor Cyan

  $all  = [System.Collections.Generic.List[object]]::new()
  $seen = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
  $done = @()

  if (-not $Fresh -and (Test-Path $IndexFile) -and (Test-Path $progressFile)) {
    try { foreach ($e in @(Get-Content $IndexFile -Raw | ConvertFrom-Json)) { if ($seen.Add($e.u)) { $all.Add($e) } } } catch { }
    try { $done = @(Get-Content $progressFile -Raw | ConvertFrom-Json) } catch { $done = @() }
    if ($done.Count) { Write-Host ("  resuming, {0} letters already done ({1} titles)" -f $done.Count, $all.Count) -ForegroundColor DarkGray }
  }

  function Save-Progress {
    $json = ConvertTo-Json -InputObject @($all) -Depth 4 -Compress
    [System.IO.File]::WriteAllText($IndexFile, $json, [System.Text.UTF8Encoding]::new($false))
    $pj = ConvertTo-Json -InputObject @($done) -Depth 4 -Compress
    [System.IO.File]::WriteAllText($progressFile, $pj, [System.Text.UTF8Encoding]::new($false))
  }

  $letters = @([char[]](97..122) | ForEach-Object { [string]$_ })

  foreach ($l in $letters) {
    if ($done -contains $l) { continue }

    $page = 1
    $total = 1
    while ($page -le $total) {
      $url = "$Base/tamil-movies/$l/?page=$page"
      try { $r = Invoke-Http -Url $url -Method GET } catch { break }
      if ($r.Status -ne 200) { break }

      if ($page -eq 1) {
        $t = [regex]::Match($r.Text, 'id="totalPages">(\d+)<').Groups[1].Value
        $total = if ($t) { [int]$t } else { 1 }
      }

      $items = @(Get-FolderLinks $r.Text)
      if ($items.Count -eq 0) { break }

      foreach ($it in $items) {
        if ($seen.Add($it.Href)) {
          $all.Add([pscustomobject]@{ t = $it.Text; u = $it.Href; l = $l })
        }
      }
      Write-Host ("  {0}  page {1}/{2}  (+{3})  total {4}" -f $l, $page, $total, $items.Count, $all.Count) -ForegroundColor DarkGray
      $page++
      Start-Sleep -Milliseconds 120
    }

    $done = @($done) + $l
    Save-Progress
  }

  Save-Progress
  Write-Host ("Catalog saved: {0} titles -> {1}" -f $all.Count, $IndexFile) -ForegroundColor Green

  if (Test-Path $HtmlFile) {
    $html = [System.IO.File]::ReadAllText($HtmlFile)
    $pattern = '(?s)<script id="catalog" type="application/json">.*?</script>'
    if ($html -match $pattern) {
      $json = ConvertTo-Json -InputObject @($all) -Depth 4 -Compress
      $replacement = '<script id="catalog" type="application/json">' + $json + '</script>'
      $html = [regex]::Replace($html, $pattern, [System.Text.RegularExpressions.MatchEvaluator]{ param($m) $replacement })
      [System.IO.File]::WriteAllText($HtmlFile, $html, [System.Text.UTF8Encoding]::new($false))
      Write-Host 'Embedded the catalog into moviezda-crawler.html' -ForegroundColor Green
    }
  }
  $all.Count
}

# ----------------------------------------------------------------------------
# isaiDub index  (A-Z listing: /tamil-atoz-dubbed-movies/<letter>/<page>)
# ----------------------------------------------------------------------------
function Get-IsaiIndex {
  if (Test-Path $IsaiIndexFile) {
    try { return @(Get-Content $IsaiIndexFile -Raw | ConvertFrom-Json) } catch { }
  }
  @()
}

function Build-IsaiIndex {
  param([switch]$Fresh)

  $progressFile = Join-Path $CacheDir 'isai-progress.json'

  Write-Host 'Building isaiDub catalog (a-z)...' -ForegroundColor Cyan

  $all  = [System.Collections.Generic.List[object]]::new()
  $seen = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
  $done = @()

  if (-not $Fresh -and (Test-Path $IsaiIndexFile) -and (Test-Path $progressFile)) {
    try { foreach ($e in @(Get-Content $IsaiIndexFile -Raw | ConvertFrom-Json)) { if ($seen.Add($e.u)) { $all.Add($e) } } } catch { }
    try { $done = @(Get-Content $progressFile -Raw | ConvertFrom-Json) } catch { $done = @() }
    if ($done.Count) { Write-Host ("  resuming, {0} letters already done ({1} titles)" -f $done.Count, $all.Count) -ForegroundColor DarkGray }
  }

  function Save-IsaiProgress {
    $json = ConvertTo-Json -InputObject @($all) -Depth 4 -Compress
    [System.IO.File]::WriteAllText($IsaiIndexFile, $json, [System.Text.UTF8Encoding]::new($false))
    $pj = ConvertTo-Json -InputObject @($done) -Depth 4 -Compress
    [System.IO.File]::WriteAllText($progressFile, $pj, [System.Text.UTF8Encoding]::new($false))
  }

  $letters = @([char[]](97..122) | ForEach-Object { [string]$_ })

  foreach ($l in $letters) {
    if ($done -contains $l) { continue }

    $page = 1
    $total = 1
    while ($page -le $total) {
      $url = if ($page -eq 1) { "$IsaiBase/tamil-atoz-dubbed-movies/$l" }
             else              { "$IsaiBase/tamil-atoz-dubbed-movies/$l/$page" }
      try { $r = Invoke-Http -Url $url -Method GET } catch { break }
      if ($r.Status -ne 200) { break }

      if ($page -eq 1) {
        $t = [regex]::Match($r.Text, 'id="totalPages">(\d+)<').Groups[1].Value
        $total = if ($t) { [int]$t } else { 1 }
      }

      $items = @(Get-IsaiFolderLinks $r.Text | Where-Object {
        $_.Href -match '^/movie/' -and $_.Text -match '\(\d{4}\)'
      })
      if ($items.Count -eq 0) { break }

      foreach ($it in $items) {
        if ($seen.Add($it.Href)) {
          $all.Add([pscustomobject]@{ t = $it.Text; u = $it.Href; l = $l })
        }
      }
      Write-Host ("  {0}  page {1}/{2}  (+{3})  total {4}" -f $l, $page, $total, $items.Count, $all.Count) -ForegroundColor DarkGray
      $page++
      Start-Sleep -Milliseconds 120
    }

    $done = @($done) + $l
    Save-IsaiProgress
  }

  Save-IsaiProgress
  Write-Host ("isaiDub catalog saved: {0} titles -> {1}" -f $all.Count, $IsaiIndexFile) -ForegroundColor Green

  if (Test-Path $HtmlFile) {
    $html = [System.IO.File]::ReadAllText($HtmlFile)
    $pattern = '(?s)<script id="isaiCatalog" type="application/json">.*?</script>'
    if ($html -match $pattern) {
      $json = ConvertTo-Json -InputObject @($all) -Depth 4 -Compress
      $replacement = '<script id="isaiCatalog" type="application/json">' + $json + '</script>'
      $html = [regex]::Replace($html, $pattern, [System.Text.RegularExpressions.MatchEvaluator]{ param($m) $replacement })
      [System.IO.File]::WriteAllText($HtmlFile, $html, [System.Text.UTF8Encoding]::new($false))
      Write-Host 'Embedded the isaiDub catalog into moviezda-crawler.html' -ForegroundColor Green
    }
  }
  $all.Count
}

function Search-Index {
  param([string]$Query, [int]$Limit = 60)
  $idx = Get-Index
  if (-not $Query) { return @() }

  $tokens = @($Query.ToLowerInvariant() -split '\s+' | Where-Object { $_ })
  $scored = foreach ($e in $idx) {
    $t = $e.t.ToLowerInvariant()
    $score = 0
    $all = $true
    foreach ($tok in $tokens) {
      if ($t.Contains($tok)) { $score += (10 - [Math]::Min(9, $t.IndexOf($tok))) } else { $all = $false }
    }
    if (-not $all) { continue }
    if ($t.StartsWith($tokens[0])) { $score += 25 }
    [pscustomobject]@{ score = $score; t = $e.t; u = $e.u }
  }
  @($scored | Sort-Object score -Descending | Select-Object -First $Limit)
}

# ----------------------------------------------------------------------------
# HTTP server
# ----------------------------------------------------------------------------
function Write-Response {
  param($Ctx, [int]$Status, [string]$ContentType, [byte[]]$Body)
  $res = $Ctx.Response
  $res.StatusCode  = $Status
  $res.ContentType = $ContentType
  $res.Headers['Cache-Control'] = 'no-store'
  $res.Headers['Access-Control-Allow-Origin'] = '*'
  $res.Headers['Access-Control-Allow-Headers'] = '*'
  $res.Headers['Access-Control-Allow-Private-Network'] = 'true'
  if ($Status -eq 204) {
    $res.ContentLength64 = 0
  } else {
    $res.ContentLength64 = $Body.Length
    if ($Body.Length -gt 0) { $res.OutputStream.Write($Body, 0, $Body.Length) }
  }
  $res.OutputStream.Close()
}

function Write-Json {
  param($Ctx, $Object, [int]$Status = 200)
  $json = ConvertTo-Json -InputObject $Object -Depth 8 -Compress
  Write-Response -Ctx $Ctx -Status $Status -ContentType 'application/json; charset=utf-8' -Body ([System.Text.Encoding]::UTF8.GetBytes($json))
}

function Start-Server {
  $listener = [System.Net.HttpListener]::new()
  $listener.Prefixes.Add("http://127.0.0.1:$Port/")
  $listener.Prefixes.Add("http://localhost:$Port/")
  try { $listener.Start() }
  catch {
    Write-Host "Could not listen on port $Port - $($_.Exception.Message)" -ForegroundColor Red
    Write-Host 'Another copy may already be running, or pick another port: -Port 8790' -ForegroundColor Yellow
    return
  }

  Write-Host ''
  Write-Host '  moviezda crawler is running' -ForegroundColor Green
  Write-Host "  http://127.0.0.1:$Port/" -ForegroundColor Cyan
  Write-Host '  Press Ctrl+C to stop.' -ForegroundColor DarkGray
  Write-Host ''

  if (-not $NoBrowser) { Start-Process "http://127.0.0.1:$Port/" | Out-Null }

  $idxCount = @(Get-Index).Count
  $isaiIdxCount = @(Get-IsaiIndex).Count

  while ($listener.IsListening) {
    $ctx = $null
    try { $ctx = $listener.GetContext() } catch { break }

    $method = $ctx.Request.HttpMethod
    $path   = $ctx.Request.Url.AbsolutePath
    $q      = $ctx.Request.QueryString

    Write-Host ("  {0,-6} {1}" -f $method, $ctx.Request.RawUrl) -ForegroundColor DarkGray

    try {
      if ($method -eq 'OPTIONS') {
        Write-Response -Ctx $ctx -Status 204 -ContentType 'text/plain' -Body ([byte[]]@())
        continue
      }

      switch ($path) {

        '/' {
          if (Test-Path $HtmlFile) {
            Write-Response -Ctx $ctx -Status 200 -ContentType 'text/html; charset=utf-8' -Body ([System.IO.File]::ReadAllBytes($HtmlFile))
          } else {
            Write-Response -Ctx $ctx -Status 404 -ContentType 'text/plain' -Body ([System.Text.Encoding]::UTF8.GetBytes('moviezda-crawler.html not found'))
          }
        }

        '/api/health' {
          Write-Json -Ctx $ctx -Object @{ ok = $true; index = $idxCount; isaiIndex = $isaiIdxCount; port = $Port; version = 3 }
        }

        '/api/search' {
          $qText = $q['q']
          $lim   = if ($q['limit']) { [int]$q['limit'] } else { 60 }
          if (-not $qText) { Write-Json -Ctx $ctx -Object @{ results = @() }; break }
          $res = @(Search-Index -Query $qText -Limit $lim)
          Write-Json -Ctx $ctx -Object @{ query = $qText; count = $res.Count; results = $res }
        }

        '/api/movie' {
          $u = $q['u']
          if (-not $u) { Write-Json -Ctx $ctx -Object @{ ok = $false; error = 'missing u' } 400; break }
          $site = if ($q['site'] -eq 'isaidub') { 'isaidub' } else { 'moviezda' }
          try {
            $variants = @(Resolve-Movie -Path $u -Site $site)
            $poster = Get-PosterImage -Title $q['t'] -Path $u
            Save-Posters
            $resp = @{ ok = $true; url = $u; site = $site; variants = $variants }
            if ($poster -and $poster.img) { $resp['img'] = $poster.img }
            Write-Json -Ctx $ctx -Object $resp
          } catch {
            Write-Json -Ctx $ctx -Object @{ ok = $false; error = $_.Exception.Message }
          }
        }

        '/api/link' {
          $u = $q['u']
          if (-not $u) { Write-Json -Ctx $ctx -Object @{ ok = $false; error = 'missing u' } 400; break }
          $site = if ($q['site'] -eq 'isaidub') { 'isaidub' } else { 'moviezda' }
          try {
            $res = Resolve-Download -Start $u -Site $site
            Write-Json -Ctx $ctx -Object $res
          } catch {
            Write-Json -Ctx $ctx -Object @{ ok = $false; error = $_.Exception.Message }
          }
        }

        '/api/check' {
          $u = $q['u']
          if (-not $u) { Write-Json -Ctx $ctx -Object @{ ok = $false; error = 'missing u' } 400; break }
          try {
            $r = Invoke-Http -Url $u -Method GET -Range 0
            $total = $null
            if ($r.Headers['content-range'] -match '/(\d+)$') { $total = [int64]$Matches[1] }
            Write-Json -Ctx $ctx -Object @{ ok = $true; status = $r.Status; type = $r.ContentType; bytes = $total }
          } catch { Write-Json -Ctx $ctx -Object @{ ok = $false; error = $_.Exception.Message } }
        }

        '/api/rebuild' {
          if ($q['site'] -eq 'isaidub') {
            $n = Build-IsaiIndex
            $isaiIdxCount = $n
            Write-Json -Ctx $ctx -Object @{ ok = $true; site = 'isaidub'; index = $n }
          } else {
            $n = Build-Index
            $idxCount = $n
            Write-Json -Ctx $ctx -Object @{ ok = $true; site = 'moviezda'; index = $n }
          }
        }

        default {
          Write-Response -Ctx $ctx -Status 404 -ContentType 'text/plain' -Body ([System.Text.Encoding]::UTF8.GetBytes('not found'))
        }
      }
    }
    catch {
      try { Write-Json -Ctx $ctx -Object @{ ok = $false; error = $_.Exception.Message } 500 } catch { }
    }
    finally {
      try { $ctx.Response.Close() } catch { }
    }
  }
  $listener.Close()
}
function Save-Media {
  param(
    [Parameter(Mandatory)][string]$Url,
    [Parameter(Mandatory)][string]$OutFile,
    [int64]$MaxBytes = 0
  )
  if (-not (Test-HostAllowed $Url)) { throw "Host not allowed: $Url" }

  $req  = [System.Net.Http.HttpRequestMessage]::new([System.Net.Http.HttpMethod]::Get, $Url)
  $task = $script:Http.SendAsync($req, [System.Net.Http.HttpCompletionOption]::ResponseHeadersRead)
  $resp = $task.GetAwaiter().GetResult()
  try {
    $in = $resp.Content.ReadAsStreamAsync().GetAwaiter().GetResult()
    $out = [System.IO.File]::Create($OutFile)
    try {
      $buf = [byte[]]::new(1MB)
      $written = [int64]0
      $sw = [Diagnostics.Stopwatch]::StartNew()
      while ($true) {
        $n = $in.Read($buf, 0, $buf.Length)
        if ($n -le 0) { break }
        if ($MaxBytes -gt 0 -and ($written + $n) -gt $MaxBytes) {
          $n = [int]($MaxBytes - $written)
          $out.Write($buf, 0, $n)
          $written += $n
          break
        }
        $out.Write($buf, 0, $n)
        $written += $n
        if ($sw.Elapsed.TotalSeconds -ge 1) {
          $mb = [Math]::Round($written / 1MB, 1)
          Write-Host ("`r  {0,8:N1} MB  ({1:N0} MB/s)" -f $mb, ($written / 1MB / $sw.Elapsed.TotalSeconds)) -NoNewline -ForegroundColor DarkCyan
          $sw.Restart()
        }
      }
      Write-Host ''
    }
    finally { $out.Close(); $in.Dispose() }
    [pscustomobject]@{ ok = $true; file = $OutFile; bytes = (Get-Item $OutFile).Length; status = [int]$resp.StatusCode; type = $resp.Content.Headers.ContentType }
  }
  finally { $resp.Dispose(); $req.Dispose() }
}

# ----------------------------------------------------------------------------
# Entry
# ----------------------------------------------------------------------------
if ($Movie) {
  $variants = @(Resolve-Movie -Path $Movie -Site $Site)
  $variants | Format-Table section, quality, size, resolution, duration -AutoSize

  $pick = if ($Quality) { $variants | Where-Object { $_.quality -match [regex]::Escape($Quality) } | Select-Object -First 1 }
          else          { $variants | Select-Object -First 1 }

  if (-not $pick) { Write-Host "No variant matched '$Quality'." -ForegroundColor Yellow; return }

  $res = Resolve-Download -Start $pick.server -Site $Site
  $res | ConvertTo-Json -Depth 6

  if ($Download -and $res.ok) {
    $dlDir = Join-Path $Root 'downloads'
    if (-not (Test-Path $dlDir)) { New-Item -ItemType Directory -Path $dlDir | Out-Null }
    $safe = ($pick.file -replace '[\\/:*?"<>|]', '_')
    if ($safe -notmatch '\.mp4$') { $safe = "$safe.mp4" }
    $out = Join-Path $dlDir $safe

    Write-Host ("Downloading {0}  ->  {1}" -f $pick.quality, $out) -ForegroundColor Cyan
    if ($MaxMB -gt 0) { Write-Host ("  limit: {0} MB (partial test)" -f $MaxMB) -ForegroundColor Yellow }

    $max = if ($MaxMB -gt 0) { [int64]$MaxMB * 1MB } else { 0 }
    $r = Save-Media -Url $res.final -OutFile $out -MaxBytes $max

    Write-Host ("Done: {0:N1} MB  ->  {1}" -f ($r.bytes / 1MB), $r.file) -ForegroundColor Green
  }
  return
}

if ($RebuildIndex) {
  if ($Site -eq 'isaidub') { Build-IsaiIndex | Out-Null } else { Build-Index | Out-Null }
}

if (@(Get-Index).Count -eq 0) {
  Write-Host 'No catalog yet - building it now (first run only).' -ForegroundColor Yellow
  Build-Index | Out-Null
}

Start-Server
