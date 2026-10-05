# Общие функции лаунчера и публикации ZEMLIBOGA.
# Файлы сравниваются по «git-хешу» (SHA-1 от "blob <размер>\0" + содержимое) — так же, как их хранит GitHub,
# поэтому скачиваются и отправляются только изменившиеся файлы.

[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
$ErrorActionPreference = 'Stop'

$Root = Split-Path -Parent $PSScriptRoot
$ConfigPath = Join-Path $PSScriptRoot 'config.json'
$ManifestPath = Join-Path $PSScriptRoot 'installed.json'
$HashCachePath = Join-Path $PSScriptRoot 'hashcache.json'

# Что не отправляется на GitHub и не трогается при обновлении (настройки, логи, кэш движка, распакованный движок).
$Excluded = @(
	'^\.git/', '^game/\.godot/', '^logs/', '^build/', '^engine/[^/]+\.exe$', '^engine/godot\.zip$',
	'^launcher/installed\.json$', '^launcher/hashcache\.json$', '^launcher/update_tmp/', '\.tmp$', '(^|/)Thumbs\.db$'
)

function Test-Excluded([string]$rel) {
	foreach ($p in $Excluded) { if ($rel -match $p) { return $true } }
	return $false
}

function Read-Json([string]$path) {
	if (-not (Test-Path $path)) { return $null }
	return [IO.File]::ReadAllText($path, [Text.Encoding]::UTF8) | ConvertFrom-Json
}

function Write-Json([string]$path, $obj) {
	[IO.File]::WriteAllText($path, ($obj | ConvertTo-Json -Depth 6), (New-Object Text.UTF8Encoding($false)))
}

function Get-Config {
	$c = Read-Json $ConfigPath
	if ($null -eq $c) { $c = [pscustomobject]@{ owner = ''; repo = ''; branch = 'main' } }
	return $c
}

# git-хеш файла (кэшируется по размеру и времени изменения, чтобы не пересчитывать большие файлы)
$script:HashCache = @{}
function Load-HashCache {
	$c = Read-Json $HashCachePath
	if ($null -ne $c) { foreach ($p in $c.PSObject.Properties) { $script:HashCache[$p.Name] = $p.Value } }
}
function Save-HashCache { Write-Json $HashCachePath $script:HashCache }

function Get-BlobSha([string]$full, [string]$rel) {
	$fi = Get-Item -LiteralPath $full
	$key = "$($fi.Length):$($fi.LastWriteTimeUtc.Ticks)"
	$cached = $script:HashCache[$rel]
	if ($null -ne $cached -and $cached.key -eq $key) { return $cached.sha }
	$bytes = [IO.File]::ReadAllBytes($full)
	$head = [Text.Encoding]::ASCII.GetBytes("blob $($bytes.Length)`0")
	$sha1 = [Security.Cryptography.SHA1]::Create()
	[void]$sha1.TransformBlock($head, 0, $head.Length, $null, 0)
	[void]$sha1.TransformFinalBlock($bytes, 0, $bytes.Length)
	$sha = -join ($sha1.Hash | ForEach-Object { $_.ToString('x2') })
	$script:HashCache[$rel] = [pscustomobject]@{ key = $key; sha = $sha }
	return $sha
}

# Все файлы игры (относительные пути через «/»), кроме исключённых.
function Get-LocalFiles {
	$out = @{}
	foreach ($f in Get-ChildItem -LiteralPath $Root -Recurse -File -Force) {
		$rel = $f.FullName.Substring($Root.Length + 1).Replace('\', '/')
		if (-not (Test-Excluded $rel)) { $out[$rel] = $f.FullName }
	}
	return $out
}

function Invoke-GitHub([string]$method, [string]$url, $body = $null, [string]$token = '') {
	$headers = @{ 'User-Agent' = 'ZEMLIBOGA-launcher'; 'Accept' = 'application/vnd.github+json' }
	if ($token -ne '') { $headers['Authorization'] = "Bearer $token" }
	if ($null -eq $body) {
		return Invoke-RestMethod -Method $method -Uri $url -Headers $headers -UseBasicParsing
	}
	$json = $body | ConvertTo-Json -Depth 8 -Compress
	return Invoke-RestMethod -Method $method -Uri $url -Headers $headers -UseBasicParsing `
		-Body ([Text.Encoding]::UTF8.GetBytes($json)) -ContentType 'application/json; charset=utf-8'
}

function Get-ApiBase($cfg) { return "https://api.github.com/repos/$($cfg.owner)/$($cfg.repo)" }

# Версия игры (Online.VERSION) — для подписи коммитов и окна лаунчера.
function Get-GameVersion {
	$f = Join-Path $Root 'game/scripts/online.gd'
	if (-not (Test-Path $f)) { return '?' }
	$m = Select-String -LiteralPath $f -Pattern 'const VERSION := "([^"]+)"' -Encoding UTF8 | Select-Object -First 1
	if ($m) { return $m.Matches[0].Groups[1].Value }
	return '?'
}

# Последний раздел «НОВОЕ В ЭТАПЕ» из README — новости для окна лаунчера.
function Get-News {
	$f = Join-Path $Root 'README.txt'
	if (-not (Test-Path $f)) { return '' }
	$text = [IO.File]::ReadAllText($f, [Text.Encoding]::UTF8)
	$i = $text.LastIndexOf('НОВОЕ В ЭТАПЕ')
	if ($i -lt 0) { return '' }
	return $text.Substring($i).Trim()
}
