<#
  generate_value_map.ps1
  Fetches the public Biwenger LaLiga dataset, fits a per-position OLS model of
  price vs. average points per appearance, and renders the self-contained
  "LaLiga Fantasy Value Map" HTML from templates/value_map_template.html.

  No auth required. No external modules. Windows PowerShell 5.1+ or pwsh.

  Output (relative to the project root = this script's parent folder):
    laliga_value_map.html                          - the artifact
    data/laliga_raw_<yyyy-MM-dd>.json               - raw API response (newest for that day)
    data/laliga_players_<yyyy-MM-dd>.csv            - flat player table (newest for that day)
    data/laliga_raw_latest.json                     - copy of the most recent raw response
    data/archive/laliga_raw_<yyyy-MM-dd>_<hash>.json - permanent backlog, one file per DISTINCT
                                                     dataset (content-hash deduplicated)
    data/archive/index.csv                          - manifest: one row per archived snapshot
#>

[CmdletBinding()]
param(
  [int]    $Score      = 1,                         # 1 = AS.com scoring (official LaLiga Fantasy)
  [string] $ProjectRoot = (Split-Path -Parent $PSScriptRoot),
  [string] $ApiUrl     = ''
)

$ErrorActionPreference = 'Stop'
if (-not $ApiUrl) {
  $ApiUrl = "https://biwenger.as.com/api/v2/competitions/la-liga/data?lang=en&score=$Score"
}

$templatePath = Join-Path $ProjectRoot 'templates/value_map_template.html'
$outHtmlPath  = Join-Path $ProjectRoot 'laliga_value_map.html'
$dataDir      = Join-Path $ProjectRoot 'data'
$archiveDir   = Join-Path $dataDir 'archive'
if (-not (Test-Path $templatePath)) { throw "Template not found: $templatePath" }
if (-not (Test-Path $dataDir))    { New-Item -ItemType Directory -Path $dataDir    | Out-Null }
if (-not (Test-Path $archiveDir)) { New-Item -ItemType Directory -Path $archiveDir | Out-Null }

$POS = @{ 1 = 'Goalkeeper'; 2 = 'Defender'; 3 = 'Midfielder'; 4 = 'Forward' }  # 5 = coach -> excluded

Write-Host "Fetching $ApiUrl"
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
$resp = Invoke-WebRequest -Uri $ApiUrl -Headers @{ 'X-Version' = '628'; 'Accept' = 'application/json' } -UseBasicParsing
# Windows PowerShell 5.1 mis-decodes bodies with no charset header (defaults to Latin-1),
# which turns "Mbappé" into "MbappÃ©". Re-decode the raw bytes as UTF-8.
if ($resp.RawContentStream) {
  $rawJson = [System.Text.Encoding]::UTF8.GetString($resp.RawContentStream.ToArray())
} else {
  $rawJson = [System.Text.Encoding]::UTF8.GetString([System.Text.Encoding]::GetEncoding('ISO-8859-1').GetBytes($resp.Content))
}
$root = $rawJson | ConvertFrom-Json
if ($root.status -ne 200 -or -not $root.data -or -not $root.data.players) {
  throw "Unexpected API response (status=$($root.status))"
}
$data = $root.data

# ---- date stamp from the API's own 'update' field (falls back to now) ----------
# Shown to viewers in Central European Time (CET in winter, CEST in summer).
$updUnix = [int64]$data.update
if ($updUnix -gt 0) { $updDt = [DateTimeOffset]::FromUnixTimeSeconds($updUnix).UtcDateTime }
else                { $updDt = [DateTime]::UtcNow }
# 'Central European Standard Time' is the Windows id; 'Europe/Madrid' the IANA id (Linux/macOS + CI).
$cetTz     = try   { [System.TimeZoneInfo]::FindSystemTimeZoneById('Central European Standard Time') }
             catch { [System.TimeZoneInfo]::FindSystemTimeZoneById('Europe/Madrid') }
$updCet    = [System.TimeZoneInfo]::ConvertTimeFromUtc($updDt, $cetTz)
$cetAbbr   = if ($cetTz.IsDaylightSavingTime($updCet)) { 'CEST' } else { 'CET' }
$stampDate  = $updCet.ToString('yyyy-MM-dd')
$stampLabel = $updCet.ToString('yyyy-MM-dd HH:mm') + " $cetAbbr"
$fileDate   = [DateTime]::UtcNow.ToString('yyyy-MM-dd')

# ---- when THIS refresh ran (wall clock), also in CET/CEST --------------------
$nowCet         = [System.TimeZoneInfo]::ConvertTimeFromUtc([DateTime]::UtcNow, $cetTz)
$nowAbbr        = if ($cetTz.IsDaylightSavingTime($nowCet)) { 'CEST' } else { 'CET' }
$refreshedLabel = $nowCet.ToString('yyyy-MM-dd HH:mm') + " $nowAbbr"

# ---- teams: id -> name --------------------------------------------------------
$teamName = @{}
foreach ($t in $data.teams.PSObject.Properties) { $teamName[[int]$t.Value.id] = [string]$t.Value.name }

# ---- flatten players --------------------------------------------------------
$players = New-Object System.Collections.Generic.List[object]
foreach ($pp in $data.players.PSObject.Properties) {
  $p = $pp.Value
  $posId = [int]$p.position
  if (-not $POS.ContainsKey($posId)) { continue }               # skip coaches / unknown
  $gp = [int]$p.playedHome + [int]$p.playedAway
  $pts = [int]$p.points
  $avg = if ($gp -gt 0) { [math]::Round($pts / $gp, 2) } else { 0.0 }
  $players.Add([pscustomobject]@{
    player = [string]$p.name
    team   = $(if ($teamName.ContainsKey([int]$p.teamID)) { $teamName[[int]$p.teamID] } else { '?' })
    pos    = $POS[$posId]
    price  = [double]$p.price
    points = $pts
    gp     = $gp
    avg    = $avg
    active = ($gp -ge 1)
  })
}
if ($players.Count -lt 100) { throw "Only $($players.Count) players parsed - aborting (schema change?)" }

# ---- per-position OLS: price ~ avg, over active players ---------------------
function Fit-OLS([object[]]$rows) {
  $n = $rows.Count
  $sx = 0.0; $sy = 0.0; $sxx = 0.0; $sxy = 0.0
  foreach ($r in $rows) { $sx += $r.avg; $sy += $r.price; $sxx += $r.avg * $r.avg; $sxy += $r.avg * $r.price }
  $denom = ($n * $sxx) - ($sx * $sx)
  if ([math]::Abs($denom) -lt 1e-9) { return @{ b0 = ($sy / [math]::Max($n,1)); b1 = 0.0 } }
  $b1 = (($n * $sxy) - ($sx * $sy)) / $denom
  $b0 = ($sy - ($b1 * $sx)) / $n
  return @{ b0 = $b0; b1 = $b1 }
}

$fit = @{}
foreach ($posName in 'Forward','Midfielder','Defender','Goalkeeper') {
  $activeRows = @($players | Where-Object { $_.pos -eq $posName -and $_.active })
  if ($activeRows.Count -lt 2) { throw "Position $posName has only $($activeRows.Count) active players" }
  $f = Fit-OLS $activeRows
  $f.xmax = [double](@($activeRows | ForEach-Object { $_.avg }) | Measure-Object -Maximum).Maximum
  $f.n = $activeRows.Count
  $fit[$posName] = $f
}

# ---- attach model outputs to every player --------------------------------
foreach ($r in $players) {
  $f = $fit[$r.pos]
  $pred = $f.b0 + ($f.b1 * $r.avg)
  $resid = $r.price - $pred
  $residPct = if ([math]::Abs($pred) -gt 1e-9) { ($resid / $pred) * 100.0 } else { 0.0 }
  Add-Member -InputObject $r -NotePropertyName pred     -NotePropertyValue $pred     -Force
  Add-Member -InputObject $r -NotePropertyName resid    -NotePropertyValue $resid    -Force
  Add-Member -InputObject $r -NotePropertyName residPct -NotePropertyValue $residPct -Force
}

# ---- pooled R^2 over active players (position-specific predictions) --------
$activeAll = @($players | Where-Object { $_.active })
$meanPrice = ($activeAll | Measure-Object price -Average).Average
$ssRes = 0.0; $ssTot = 0.0
foreach ($r in $activeAll) { $ssRes += [math]::Pow($r.price - $r.pred, 2); $ssTot += [math]::Pow($r.price - $meanPrice, 2) }
$r2 = if ($ssTot -gt 0) { [math]::Round(1.0 - ($ssRes / $ssTot), 2) } else { 0.0 }
$nRounds = [int](@($players | ForEach-Object { $_.gp }) | Measure-Object -Maximum).Maximum
$nInactive = $players.Count - $activeAll.Count

# ---- assemble DATA (active only) and ALLPLAYERS (everyone) ----------------

$DATA = [ordered]@{}
foreach ($posName in 'Forward','Midfielder','Defender','Goalkeeper') {
  $f = $fit[$posName]
  $rows = @($players | Where-Object { $_.pos -eq $posName -and $_.active } |
           Sort-Object -Property @{Expression='points';Descending=$true}, @{Expression='resid';Descending=$true})
  $pointsArr = foreach ($r in $rows) {
    [ordered]@{ player=$r.player; team=$r.team; price=$r.price; points=$r.points; gp=$r.gp;
               avg=$r.avg; pred=$r.pred; resid=$r.resid; residPct=$r.residPct }
  }
  $DATA[$posName] = [ordered]@{ b0=$f.b0; b1=$f.b1; xmax=$f.xmax; points=@($pointsArr); n=$f.n }
}

$allSorted = @($players | Sort-Object -Property @{Expression='points';Descending=$true}, @{Expression='resid';Descending=$true})
$ALLPLAYERS = foreach ($r in $allSorted) {
  [ordered]@{ player=$r.player; team=$r.team; pos=$r.pos; price=$r.price; points=$r.points; gp=$r.gp;
             avg=$r.avg; active=$r.active; pred=$r.pred; resid=$r.resid; residPct=$r.residPct }
}

$dataJson = $DATA       | ConvertTo-Json -Depth 12 -Compress
$allJson  = @($ALLPLAYERS) | ConvertTo-Json -Depth 12 -Compress

# ---- render template -----------------------------------------------------
$html = [System.IO.File]::ReadAllText($templatePath)
$html = $html.Replace('__DATA_JSON__', $dataJson)
$html = $html.Replace('__ALLPLAYERS_JSON__', $allJson)
$html = $html.Replace('__UPDATED__', $stampLabel)
$html = $html.Replace('__REFRESHED__', $refreshedLabel)
$html = $html.Replace('__NPLAYERS__', [string]$players.Count)
$html = $html.Replace('__NINACTIVE__', [string]$nInactive)
$html = $html.Replace('__NROUNDS__', [string]$nRounds)
$html = $html.Replace('__R2__', $r2.ToString('0.00'))
foreach ($ph in '__DATA_JSON__','__ALLPLAYERS_JSON__','__UPDATED__','__REFRESHED__','__NPLAYERS__','__NINACTIVE__','__NROUNDS__','__R2__') {
  if ($html.Contains($ph)) { throw "Placeholder substitution failed: $ph" }
}
$utf8 = New-Object System.Text.UTF8Encoding($false)
[System.IO.File]::WriteAllText($outHtmlPath, $html, $utf8)

# ---- snapshots (newest-for-the-day working copies) --------------------
[System.IO.File]::WriteAllText((Join-Path $dataDir "laliga_raw_$fileDate.json"), $rawJson, $utf8)
$allSorted |
  Select-Object player, team, pos, price, points, gp, avg, active,
    @{n='pred';e={[math]::Round($_.pred)}}, @{n='resid';e={[math]::Round($_.resid)}}, @{n='residPct';e={[math]::Round($_.residPct,1)}} |
  Export-Csv -Path (Join-Path $dataDir "laliga_players_$fileDate.csv") -NoTypeInformation -Encoding UTF8

# ---- permanent archive of the raw response (content-hash deduplicated) -
# Every distinct dataset is kept forever under data/archive/. Re-runs on an
# unchanged Biwenger response are detected by SHA-256 and skipped, so the
# backlog holds one file per real data change, not one per script run.
$sha256 = [System.Security.Cryptography.SHA256]::Create()
try   { $hashBytes = $sha256.ComputeHash($utf8.GetBytes($rawJson)) }
finally { $sha256.Dispose() }
$hashShort = (-join ($hashBytes | ForEach-Object { $_.ToString('x2') })).Substring(0, 12)

# "latest" pointer is always refreshed
[System.IO.File]::WriteAllText((Join-Path $dataDir 'laliga_raw_latest.json'), $rawJson, $utf8)

$dup = Get-ChildItem -Path $archiveDir -Filter "*_$hashShort.json" -ErrorAction SilentlyContinue | Select-Object -First 1
if ($dup) {
  $archiveNote = "Archive: unchanged since $($dup.Name)  (sha $hashShort)"
} else {
  $archiveName = "laliga_raw_${fileDate}_$hashShort.json"
  [System.IO.File]::WriteAllText((Join-Path $archiveDir $archiveName), $rawJson, $utf8)
  [pscustomobject][ordered]@{
    fetched_utc    = [DateTime]::UtcNow.ToString("yyyy-MM-ddTHH:mm:ssZ")
    biwenger_stamp = $stampLabel
    sha256_12      = $hashShort
    players        = $players.Count
    active         = @($players | Where-Object { $_.active }).Count
    bytes          = $utf8.GetByteCount($rawJson)
    file           = "archive/$archiveName"
  } | Export-Csv -Path (Join-Path $archiveDir 'index.csv') -NoTypeInformation -Encoding UTF8 -Append
  $archiveNote = "Archive: NEW $archiveName"
}

# ---- summary ---------------------------------------------------------
$activeCount = @($players | Where-Object { $_.active }).Count
Write-Host ""
Write-Host ("Players: {0}  (active {1} / inactive {2})  data stamp {3}" -f $players.Count, $activeCount, ($players.Count - $activeCount), $stampLabel)
foreach ($posName in 'Forward','Midfielder','Defender','Goalkeeper') {
  $f = $fit[$posName]
  Write-Host ("  {0,-11} n={1,-4} b0={2,12:N0}  b1={3,11:N0} /avg pt   xmax={4}" -f $posName, $f.n, $f.b0, $f.b1, $f.xmax)
}
Write-Host ""
Write-Host ("Wrote {0} ({1:N0} bytes)" -f $outHtmlPath, (Get-Item $outHtmlPath).Length)
Write-Host ("Wrote data/laliga_raw_$fileDate.json, data/laliga_players_$fileDate.csv")
Write-Host $archiveNote
