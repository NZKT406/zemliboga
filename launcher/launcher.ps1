# Лаунчер ZEMLIBOGA (запускается через LAUNCHER.bat).
# Проверяет обновление на GitHub, скачивает только изменившиеся файлы, показывает новости и запускает игру.
# Работает без git и без ключей: репозиторий с игрой публичный, скачивание идёт как у обычного браузера.
param([switch]$NoUpdate, [string]$Shot = '')

. (Join-Path $PSScriptRoot 'common.ps1')
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
[Windows.Forms.Application]::EnableVisualStyles()

$Gold = [Drawing.Color]::FromArgb(255, 210, 74)
$Bg = [Drawing.Color]::FromArgb(22, 26, 32)
$Panel = [Drawing.Color]::FromArgb(34, 40, 48)
$TextC = [Drawing.Color]::FromArgb(230, 226, 214)

$form = New-Object Windows.Forms.Form
$form.Text = 'ZEMLIBOGA — лаунчер'
$form.Size = New-Object Drawing.Size(820, 600)
$form.StartPosition = 'CenterScreen'
$form.BackColor = $Bg
$form.FormBorderStyle = 'FixedSingle'
$form.MaximizeBox = $false

$title = New-Object Windows.Forms.Label
$title.Text = 'ZEMLIBOGA'
$title.Font = New-Object Drawing.Font('Segoe UI', 30, [Drawing.FontStyle]::Bold)
$title.ForeColor = $Gold
$title.Location = New-Object Drawing.Point(24, 14)
$title.AutoSize = $true
$form.Controls.Add($title)

$sub = New-Object Windows.Forms.Label
$sub.Text = 'Земли Бога'
$sub.Font = New-Object Drawing.Font('Segoe UI', 12)
$sub.ForeColor = [Drawing.Color]::FromArgb(170, 176, 186)
$sub.Location = New-Object Drawing.Point(30, 72)
$sub.AutoSize = $true
$form.Controls.Add($sub)

$ver = New-Object Windows.Forms.Label
$ver.Font = New-Object Drawing.Font('Segoe UI', 11)
$ver.ForeColor = $TextC
$ver.Location = New-Object Drawing.Point(470, 30)
$ver.Size = New-Object Drawing.Size(320, 50)
$ver.TextAlign = 'TopRight'
$form.Controls.Add($ver)

$news = New-Object Windows.Forms.TextBox
$news.Multiline = $true
$news.ReadOnly = $true
$news.ScrollBars = 'Vertical'
$news.BackColor = $Panel
$news.ForeColor = $TextC
$news.BorderStyle = 'FixedSingle'
$news.Font = New-Object Drawing.Font('Segoe UI', 10)
$news.Location = New-Object Drawing.Point(24, 106)
$news.Size = New-Object Drawing.Size(756, 330)
$form.Controls.Add($news)

$status = New-Object Windows.Forms.Label
$status.Font = New-Object Drawing.Font('Segoe UI', 10)
$status.ForeColor = [Drawing.Color]::FromArgb(159, 224, 255)
$status.Location = New-Object Drawing.Point(24, 446)
$status.Size = New-Object Drawing.Size(756, 22)
$form.Controls.Add($status)

$bar = New-Object Windows.Forms.ProgressBar
$bar.Location = New-Object Drawing.Point(24, 472)
$bar.Size = New-Object Drawing.Size(756, 14)
$form.Controls.Add($bar)

function New-Button([string]$text, [int]$x, [int]$w, [bool]$main) {
	$b = New-Object Windows.Forms.Button
	$b.Text = $text
	$b.Location = New-Object Drawing.Point($x, 500)
	$b.Size = New-Object Drawing.Size($w, 46)
	$b.FlatStyle = 'Flat'
	$b.Font = New-Object Drawing.Font('Segoe UI', $(if ($main) { 15 } else { 10 }), $(if ($main) { [Drawing.FontStyle]::Bold } else { [Drawing.FontStyle]::Regular }))
	$b.BackColor = $(if ($main) { [Drawing.Color]::FromArgb(70, 56, 20) } else { $Panel })
	$b.ForeColor = $(if ($main) { $Gold } else { $TextC })
	$b.FlatAppearance.BorderColor = $Gold
	$form.Controls.Add($b)
	return $b
}
$play = New-Button 'ИГРАТЬ' 560 220 $true
$check = New-Button 'Проверить обновления' 24 200 $false
$folder = New-Button 'Открыть папку' 234 150 $false

function Say([string]$text) {
	$status.Text = $text
	[Windows.Forms.Application]::DoEvents()
}

function Show-Local {
	$ver.Text = "Версия игры: $(Get-GameVersion)"
	$n = Get-News
	$news.Text = $(if ($n -ne '') { $n.Replace("`r`n", "`n").Replace("`n", "`r`n") } else { 'Новостей пока нет.' })
	$news.SelectionStart = 0
	$news.SelectionLength = 0
	$play.Focus() | Out-Null
}

# Проверка и установка обновления. Возвращает $true, если всё в порядке (или обновлений нет).
function Update-Game {
	$cfg = Get-Config
	if ($cfg.owner -eq '' -or $cfg.repo -eq '') {
		Say 'Обновления не настроены (нет launcher\config.json). Можно просто играть.'
		return $true
	}
	$check.Enabled = $false
	$play.Enabled = $false
	try {
		$api = Get-ApiBase $cfg
		Say "Проверяю обновления на GitHub ($($cfg.owner)/$($cfg.repo))..."
		$ref = Invoke-GitHub GET "$api/commits/$($cfg.branch)"
		$sha = $ref.sha
		$manifest = Read-Json $ManifestPath
		$tree = Invoke-GitHub GET "$api/git/trees/$sha`?recursive=1"
		Load-HashCache
		$todo = New-Object System.Collections.ArrayList
		$remote = @{}
		foreach ($e in $tree.tree) {
			if ($e.type -ne 'blob' -or (Test-Excluded $e.path) -or $e.path -eq 'README.md') { continue }
			$remote[$e.path] = $e.sha
			$full = Join-Path $Root $e.path
			if (-not (Test-Path -LiteralPath $full) -or (Get-BlobSha $full $e.path) -ne $e.sha) {
				[void]$todo.Add($e)
			}
		}
		if ($todo.Count -eq 0) {
			Save-HashCache
			Write-Json $ManifestPath @{ commit = $sha; files = $remote }
			Say "У вас последняя версия. Приятной игры!"
			return $true
		}
		$total = 0
		foreach ($e in $todo) { $total += [int64]$e.size }
		$bar.Maximum = [Math]::Max(1, [int]($total / 1024))
		$bar.Value = 0
		$tmp = Join-Path $PSScriptRoot 'update_tmp'
		New-Item -ItemType Directory -Force $tmp | Out-Null
		$web = New-Object Net.WebClient
		$web.Headers.Add('User-Agent', 'ZEMLIBOGA-launcher')
		$done = 0
		$i = 0
		foreach ($e in $todo) {
			$i++
			Say ("Загружаю обновление: {0} из {1} — {2}" -f $i, $todo.Count, $e.path)
			$enc = ($e.path -split '/' | ForEach-Object { [Uri]::EscapeDataString($_) }) -join '/'
			$dest = Join-Path $tmp ("f$i.part")
			$web.DownloadFile("https://raw.githubusercontent.com/$($cfg.owner)/$($cfg.repo)/$sha/$enc", $dest)
			$full = Join-Path $Root $e.path
			New-Item -ItemType Directory -Force (Split-Path -Parent $full) | Out-Null
			Move-Item -LiteralPath $dest -Destination $full -Force
			$done += [int64]$e.size
			$bar.Value = [Math]::Min($bar.Maximum, [int]($done / 1024))
		}
		# файлы, которые были в прошлой версии, а теперь удалены
		if ($null -ne $manifest -and $null -ne $manifest.files) {
			foreach ($p in $manifest.files.PSObject.Properties) {
				if (-not $remote.ContainsKey($p.Name)) {
					$old = Join-Path $Root $p.Name
					if (Test-Path -LiteralPath $old) { Remove-Item -LiteralPath $old -Force }
				}
			}
		}
		Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue
		Save-HashCache
		Write-Json $ManifestPath @{ commit = $sha; files = $remote }
		Show-Local
		Say "Обновление установлено (файлов: $($todo.Count)). Новости — выше."
		return $true
	} catch {
		Say "Не удалось обновиться: $($_.Exception.Message). Можно играть в текущую версию."
		return $false
	} finally {
		$check.Enabled = $true
		$play.Enabled = $true
	}
}

$play.Add_Click({
	Start-Process -FilePath (Join-Path $Root 'PLAY.bat') -WorkingDirectory $Root -WindowStyle Hidden
	$form.Close()
})
$check.Add_Click({ [void](Update-Game) })
$folder.Add_Click({ Start-Process explorer.exe $Root })
$form.Add_Shown({
	Show-Local
	if (-not $NoUpdate) { [void](Update-Game) }
	if ($Shot -ne '') {      # для проверки: снимок окна и выход
		$bmp = New-Object Drawing.Bitmap($form.Width, $form.Height)
		$form.DrawToBitmap($bmp, (New-Object Drawing.Rectangle(0, 0, $form.Width, $form.Height)))
		$bmp.Save($Shot)
		$form.Close()
	}
})

Show-Local
[void]$form.ShowDialog()
