# Публикация обновления ZEMLIBOGA на GitHub (запускается через PUBLISH.bat).
# Отправляет только изменившиеся файлы одним коммитом. Git устанавливать не нужно.
# Ключ доступа (token) вводится один раз и хранится зашифрованным средствами Windows (DPAPI) —
# расшифровать его может только ваша учётная запись на этом компьютере. На GitHub он не попадает.
# PUBLISH.bat -DryRun — только показать, какие файлы ушли бы на GitHub (ничего не отправляет).
param([switch]$DryRun)

. (Join-Path $PSScriptRoot 'common.ps1')

if ($DryRun) {
	Load-HashCache
	$files = Get-LocalFiles
	$total = 0
	foreach ($rel in ($files.Keys | Sort-Object)) {
		$len = (Get-Item -LiteralPath $files[$rel]).Length
		$total += $len
		Write-Host ("{0,10:N0} КБ  {1}  {2}" -f ($len / 1KB), (Get-BlobSha $files[$rel] $rel).Substring(0, 8), $rel)
	}
	Save-HashCache
	Write-Host ("Итого файлов: {0}, размер: {1:N1} МБ, версия игры: {2}" -f $files.Count, ($total / 1MB), (Get-GameVersion))
	return
}

$TokenPath = Join-Path $env:APPDATA 'ZEMLIBOGA\publish_token.dat'

function Get-Token {
	if (Test-Path $TokenPath) {
		$sec = Get-Content -LiteralPath $TokenPath | ConvertTo-SecureString
		return [Runtime.InteropServices.Marshal]::PtrToStringBSTR([Runtime.InteropServices.Marshal]::SecureStringToBSTR($sec))
	}
	Write-Host ''
	Write-Host 'Нужен ключ доступа GitHub (fine-grained personal access token):' -ForegroundColor Yellow
	Write-Host '  github.com -> Settings -> Developer settings -> Personal access tokens -> Fine-grained tokens'
	Write-Host '  -> Generate new token: Repository access = только ваш репозиторий игры,'
	Write-Host '     Permissions -> Contents = Read and write. Скопируйте ключ и вставьте сюда.'
	$sec = Read-Host 'Ключ (ввод не отображается)' -AsSecureString
	New-Item -ItemType Directory -Force (Split-Path $TokenPath) | Out-Null
	$sec | ConvertFrom-SecureString | Set-Content -LiteralPath $TokenPath
	return [Runtime.InteropServices.Marshal]::PtrToStringBSTR([Runtime.InteropServices.Marshal]::SecureStringToBSTR($sec))
}

try {
	Write-Host '=== Публикация ZEMLIBOGA на GitHub ===' -ForegroundColor Cyan
	$cfg = Get-Config
	if ($cfg.owner -eq '' -or $cfg.repo -eq '') {
		Write-Host 'Первый запуск: укажите, куда публиковать.'
		$cfg.owner = (Read-Host 'Имя пользователя GitHub').Trim()
		$cfg.repo = (Read-Host 'Название репозитория (например zemliboga)').Trim()
		$cfg.branch = 'main'
		Write-Json $ConfigPath $cfg
	}
	$api = Get-ApiBase $cfg
	$token = Get-Token
	$version = Get-GameVersion
	Write-Host "Репозиторий: $($cfg.owner)/$($cfg.repo), версия игры: $version"

	# текущее состояние ветки на GitHub
	$head = $null
	$remote = @{}
	try {
		$ref = Invoke-GitHub GET "$api/git/ref/heads/$($cfg.branch)" $null $token
		$head = $ref.object.sha
		$commit = Invoke-GitHub GET "$api/git/commits/$head" $null $token
		$tree = Invoke-GitHub GET "$api/git/trees/$($commit.tree.sha)?recursive=1" $null $token
		foreach ($e in $tree.tree) { if ($e.type -eq 'blob') { $remote[$e.path] = $e.sha } }
	} catch {
		Write-Host 'Ветка ещё пустая — создаю первый коммит.'
		$readme = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes("# ZEMLIBOGA`n`nRTS-игра. Скачайте архив (Code -> Download ZIP), распакуйте и запустите LAUNCHER.bat.`n"))
		Invoke-GitHub PUT "$api/contents/README.md" @{ message = 'Начало'; content = $readme; branch = $cfg.branch } $token | Out-Null
		$ref = Invoke-GitHub GET "$api/git/ref/heads/$($cfg.branch)" $null $token
		$head = $ref.object.sha
		$remote['README.md'] = 'keep'
	}

	Load-HashCache
	$local = Get-LocalFiles
	$entries = New-Object System.Collections.ArrayList
	$changed = 0
	$n = 0
	foreach ($rel in ($local.Keys | Sort-Object)) {
		$n++
		$sha = Get-BlobSha $local[$rel] $rel
		if ($remote.ContainsKey($rel) -and $remote[$rel] -eq $sha) { continue }
		Write-Host ("  отправляю {0} ({1:N0} КБ)" -f $rel, ((Get-Item -LiteralPath $local[$rel]).Length / 1KB))
		$b64 = [Convert]::ToBase64String([IO.File]::ReadAllBytes($local[$rel]))
		$blob = Invoke-GitHub POST "$api/git/blobs" @{ content = $b64; encoding = 'base64' } $token
		[void]$entries.Add(@{ path = $rel; mode = '100644'; type = 'blob'; sha = $blob.sha })
		$changed++
	}
	Save-HashCache
	$removed = 0
	foreach ($rel in $remote.Keys) {
		if (-not $local.ContainsKey($rel) -and $rel -ne 'README.md' -and -not (Test-Excluded $rel)) {
			[void]$entries.Add(@{ path = $rel; mode = '100644'; type = 'blob'; sha = $null })
			$removed++
		}
	}
	if ($entries.Count -eq 0) {
		Write-Host 'Изменений нет — на GitHub уже последняя версия.' -ForegroundColor Green
	} else {
		$note = Read-Host 'Короткое описание обновления (Enter — без описания)'
		$msg = "Версия $version" + $(if ($note.Trim() -ne '') { ": $($note.Trim())" } else { '' })
		$base = (Invoke-GitHub GET "$api/git/commits/$head" $null $token).tree.sha
		$newTree = Invoke-GitHub POST "$api/git/trees" @{ base_tree = $base; tree = $entries.ToArray() } $token
		$newCommit = Invoke-GitHub POST "$api/git/commits" @{ message = $msg; tree = $newTree.sha; parents = @($head) } $token
		Invoke-GitHub PATCH "$api/git/refs/heads/$($cfg.branch)" @{ sha = $newCommit.sha } $token | Out-Null
		# эта папка теперь совпадает с опубликованной версией: лаунчер считает её файлы своими,
		# а всё, что изменится здесь позже, при обновлении не затрёт
		$mine = @{}
		foreach ($rel in $local.Keys) { $mine[$rel] = Get-BlobSha $local[$rel] $rel }
		Save-HashCache
		Write-Json $ManifestPath @{ commit = $newCommit.sha; files = $mine }
		Write-Host ''
		Write-Host "Готово: опубликовано (изменено файлов: $changed, удалено: $removed)." -ForegroundColor Green
		Write-Host 'Друзья получат обновление при следующем запуске LAUNCHER.bat.'
	}
} catch {
	Write-Host ''
	Write-Host "Ошибка: $($_.Exception.Message)" -ForegroundColor Red
	if ($_.Exception.Message -match '401|403') {
		Write-Host 'Похоже, ключ неверный или у него нет права Contents: Read and write. Удаляю сохранённый ключ — при следующем запуске введите новый.'
		Remove-Item -LiteralPath $TokenPath -ErrorAction SilentlyContinue
	}
}
