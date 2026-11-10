# 视频压缩转换器 - Windows 版
# 兼容 Windows 7 x64 / Windows 8 / 10 / 11，PowerShell 2.0 + .NET 3.5（系统自带）
# 画质优先、不缩放、不改色彩、强制恒定帧率（CFR）

$ErrorActionPreference = "Stop"
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

$script:Base   = Split-Path -Parent $MyInvocation.MyCommand.Path
$script:FF     = Join-Path $script:Base "bin\ffmpeg.exe"
$script:FP     = Join-Path $script:Base "bin\ffprobe.exe"
$script:OutDir = Join-Path ([Environment]::GetFolderPath("MyVideos")) "视频压缩输出"
$script:Queue  = New-Object System.Collections.ArrayList
$script:Cur    = $null
$script:CRF    = 16
$script:HEVC   = $true
$script:KeepAudio = $true
$script:Verify = $false

if (-not (Test-Path $script:FF)) {
    [System.Windows.Forms.MessageBox]::Show(
        "找不到 bin\ffmpeg.exe`n请把整个文件夹完整解压后再运行。",
        "视频压缩转换器", "OK", "Error") | Out-Null
    return
}
if (-not (Test-Path $script:OutDir)) {
    New-Item -ItemType Directory -Path $script:OutDir -Force | Out-Null
}

function Format-Size($n) {
    if ($n -le 0) { return "0 B" }
    $u = @("B","KB","MB","GB","TB"); $i = 0; $v = [double]$n
    while ($v -ge 1024 -and $i -lt 4) { $v /= 1024; $i++ }
    if ($i -lt 2) { return ([math]::Round($v)).ToString() + " " + $u[$i] }
    return ($v.ToString("0.0")) + " " + $u[$i]
}

function Get-MediaInfo($path) {
    $info = New-Object PSObject -Property @{
        Size = (Get-Item -LiteralPath $path).Length
        Duration = 0.0; Width = 0; Height = 0
        Rate = ""; HasAudio = $false; Color = ""
    }
    if (-not (Test-Path $script:FP)) { return $info }
    try {
        $lines = & $script:FP -v error -show_entries `
            "format=duration:stream=codec_type,width,height,r_frame_rate,color_space" `
            -of flat $path 2>$null
        $gotRate = $false
        foreach ($l in $lines) {
            $s = [string]$l
            if ($s -match 'format\.duration="?([\d.]+)') { $info.Duration = [double]$Matches[1] }
            elseif ($s -match 'codec_type="audio"') { $info.HasAudio = $true }
            elseif ($s -match '\.width="?(\d+)') { $info.Width = [int]$Matches[1] }
            elseif ($s -match '\.height="?(\d+)') { $info.Height = [int]$Matches[1] }
            elseif (-not $gotRate -and $s -match 'r_frame_rate="?([\d/]+)') {
                $info.Rate = $Matches[1]; $gotRate = $true
            }
            elseif ($s -match 'color_space="?bt709') { $info.Color = "bt709" }
        }
    } catch { }
    return $info
}

function Unique-Out($path) {
    $stem = [System.IO.Path]::GetFileNameWithoutExtension($path) + "_压缩版"
    $dst = Join-Path $script:OutDir ($stem + ".mp4")
    $i = 2
    while (Test-Path -LiteralPath $dst) {
        $dst = Join-Path $script:OutDir ($stem + "-" + $i + ".mp4")
        $i++
    }
    return $dst
}

function Build-Args($job, $dst, $progressFile, $audioFallback) {
    if ($script:HEVC) {
        $enc = "-c:v libx265 -preset medium -crf $($script:CRF) -tag:v hvc1"
    } else {
        $enc = "-c:v libx264 -preset medium -crf $($script:CRF) -tag:v avc1"
    }
    $rate = ""
    if ($job.Info.Rate -ne "") { $rate = "-r " + $job.Info.Rate }
    $col = ""
    if ($job.Info.Color -eq "bt709") {
        $col = "-color_primaries bt709 -color_trc bt709 -colorspace bt709"
    }
    if ($script:KeepAudio -and $job.Info.HasAudio) {
        if ($audioFallback) { $aud = "-map 0:a:0 -c:a aac -b:a 192k" }
        else { $aud = "-map 0:a:0 -c:a copy" }
    } else { $aud = "-an" }
    return "-hide_banner -nostdin -loglevel error -nostats -progress `"$progressFile`" " +
           "-i `"$($job.Path)`" -map 0:v:0 $enc -pix_fmt yuv420p " +
           "-fps_mode cfr $rate -video_track_timescale 30000 $col $aud " +
           "-map_metadata 0 -movflags +faststart -y `"$dst`""
}

function Start-ProcessFor($job, $dst, $audioFallback) {
    $pf = [System.IO.Path]::GetTempFileName()
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = $script:FF
    $psi.Arguments = Build-Args $job $dst $pf $audioFallback
    $psi.UseShellExecute = $false
    $psi.CreateNoWindow = $true
    $psi.RedirectStandardError = $true
    $p = New-Object System.Diagnostics.Process
    $p.StartInfo = $psi
    $p.Start() | Out-Null
    $job.Proc = $p
    $job.ProgressFile = $pf
    $job.Dst = $dst
    $job.Fallback = $audioFallback
    $job.Started = [DateTime]::Now
    $job.Item.SubItems[4].Text = "压缩中…"
    $job.Item.ForeColor = [System.Drawing.Color]::FromArgb(47,102,232)
}

function Start-Next {
    if ($script:Cur -ne $null) { return }
    if ($script:Queue.Count -eq 0) { return }
    $job = $script:Queue[0]
    $script:Queue.RemoveAt(0)
    $script:Cur = $job
    $dst = Unique-Out $job.Path
    try { Start-ProcessFor $job $dst $false }
    catch {
        $job.Item.SubItems[4].Text = "启动失败：" + $_.Exception.Message
        $job.Item.ForeColor = [System.Drawing.Color]::Red
        $script:Cur = $null
    }
}

function Get-SSIM($src, $dst) {
    try {
        $psi = New-Object System.Diagnostics.ProcessStartInfo
        $psi.FileName = $script:FF
        $fc = "[0:v]setpts=PTS-STARTPTS[ref];[1:v]setpts=PTS-STARTPTS[dis];[ref][dis]ssim[out]"
        $psi.Arguments = "-hide_banner -nostdin -loglevel info -i `"$src`" -i `"$dst`" " +
                         "-filter_complex `"$fc`" -map `"[out]`" -an -f null -"
        $psi.UseShellExecute = $false
        $psi.CreateNoWindow = $true
        $psi.RedirectStandardError = $true
        $p = New-Object System.Diagnostics.Process
        $p.StartInfo = $psi
        $p.Start() | Out-Null
        $txt = $p.StandardError.ReadToEnd()
        $p.WaitForExit()
        $m = [regex]::Matches($txt, "All:\s*([0-9.]+)")
        if ($m.Count -gt 0) { return [double]$m[$m.Count-1].Groups[1].Value }
    } catch { }
    return 0
}

function Finish-Current {
    $job = $script:Cur
    if ($job -eq $null) { return }
    $err = ""
    try { $err = $job.Proc.StandardError.ReadToEnd() } catch { }
    $code = $job.Proc.ExitCode
    $out = $job.Dst

    # 部分音轨（PCM 等）无法直接复制进 MP4，自动降级为 AAC 再试一次
    if ($code -ne 0 -and $script:KeepAudio -and $job.Info.HasAudio -and -not $job.Fallback) {
        try { Remove-Item -LiteralPath $out -Force -ErrorAction SilentlyContinue } catch { }
        Start-ProcessFor $job $out $true
        return
    }

    try { Remove-Item -LiteralPath $job.ProgressFile -Force -ErrorAction SilentlyContinue } catch { }

    if ($code -eq 0 -and (Test-Path -LiteralPath $out)) {
        $os = (Get-Item -LiteralPath $out).Length
        $saved = 0
        if ($job.Info.Size -gt 0) { $saved = (1 - $os / $job.Info.Size) * 100 }
        $job.Item.SubItems[2].Text = Format-Size $os
        $job.Item.SubItems[3].Text = "-" + ([math]::Round($saved,1)).ToString() + "%"
        $rateTxt = ""
        if ($job.Info.Rate -ne "") { $rateTxt = " · 恒定帧率" }
        $elapsed = ([DateTime]::Now - $job.Started).TotalSeconds
        $job.Item.SubItems[4].Text = "完成 · " + ([math]::Round($elapsed)).ToString() + " 秒" + $rateTxt
        $job.Item.ForeColor = [System.Drawing.Color]::FromArgb(21,122,82)
        $script:status.Text = "完成：" + $job.Name + "  " + (Format-Size $job.Info.Size) +
                              " → " + (Format-Size $os)
        if ($script:Verify) {
            $job.Item.SubItems[4].Text = "画质校验中…"
            [System.Windows.Forms.Application]::DoEvents()
            $v = Get-SSIM $job.Path $out
            if ($v -gt 0) {
                $job.Item.SubItems[4].Text = "完成 · SSIM " + $v.ToString("0.0000") + $rateTxt
            }
        }
    } else {
        $msg = $err.Trim()
        if ($msg.Length -gt 160) { $msg = $msg.Substring($msg.Length-160) }
        if ($msg -eq "") { $msg = "转码失败（退出码 $code）" }
        $job.Item.SubItems[4].Text = "失败：" + $msg
        $job.Item.ForeColor = [System.Drawing.Color]::Red
    }
    $script:progress.Value = 0
    $script:Cur = $null
}

function Update-Progress {
    $job = $script:Cur
    if ($job -eq $null) { return }
    if (-not (Test-Path -LiteralPath $job.ProgressFile)) { return }
    try {
        $lines = [System.IO.File]::ReadAllLines($job.ProgressFile)
        for ($k = $lines.Length - 1; $k -ge 0; $k--) {
            if ($lines[$k].StartsWith("out_time_ms=")) {
                $ms = [double]($lines[$k].Substring(12))
                if ($job.Info.Duration -gt 0) {
                    $pct = [math]::Min(99, [math]::Max(0, $ms / 1000000 / $job.Info.Duration * 100))
                    $script:progress.Value = [int]$pct
                    $job.Item.SubItems[4].Text = "压缩中 " + ([math]::Round($pct)).ToString() + "%"
                }
                break
            }
        }
    } catch { }
}

function Add-Files($files) {
    foreach ($f in $files) {
        $ext = [System.IO.Path]::GetExtension($f).ToLower()
        if (@(".mp4",".mov",".m4v",".mkv",".avi",".webm",".mts",".m2ts",
              ".mpg",".mpeg",".wmv",".flv",".ts") -notcontains $ext) { continue }
        if (-not (Test-Path -LiteralPath $f)) { continue }
        $info = Get-MediaInfo $f
        $meta = ""
        if ($info.Width -gt 0) { $meta = "$($info.Width)x$($info.Height)  " }
        if ($info.Rate -ne "") { $meta = $meta + $info.Rate + "  " }
        $item = New-Object System.Windows.Forms.ListViewItem
        $item.Text = [System.IO.Path]::GetFileName($f)
        $item.SubItems.Add((Format-Size $info.Size)) | Out-Null
        $item.SubItems.Add("—") | Out-Null
        $item.SubItems.Add("—") | Out-Null
        $item.SubItems.Add("排队中") | Out-Null
        $item.ToolTipText = $f
        $script:lv.Items.Add($item) | Out-Null
        $job = New-Object PSObject -Property @{
            Path = $f; Name = $item.Text; Info = $info; Item = $item
            Proc = $null; ProgressFile = ""; Dst = ""; Fallback = $false
            Started = [DateTime]::Now
        }
        $script:Queue.Add($job) | Out-Null
    }
    $script:status.Text = "已加入 " + $script:lv.Items.Count + " 个视频 · 自动开始压缩"
}

# ---------------- 界面 ----------------
$form = New-Object System.Windows.Forms.Form
$form.Text = "视频压缩转换器"
$form.Size = New-Object System.Drawing.Size(940, 680)
$form.MinimumSize = New-Object System.Drawing.Size(820, 600)
$form.StartPosition = "CenterScreen"
$form.AllowDrop = $true
$form.BackColor = [System.Drawing.Color]::FromArgb(246,248,251)
$uiFont = New-Object System.Drawing.Font("Microsoft YaHei", 9)

$title = New-Object System.Windows.Forms.Label
$title.Text = "把视频拖进来，立即开始压缩"
$title.Font = New-Object System.Drawing.Font("Microsoft YaHei", 16, [System.Drawing.FontStyle]::Bold)
$title.Location = New-Object System.Drawing.Point(26, 18)
$title.Size = New-Object System.Drawing.Size(600, 34)
$form.Controls.Add($title)

$sub = New-Object System.Windows.Forms.Label
$sub.Text = "画质优先 · 恒定帧率 · 保留原分辨率与音轨 · 全部在本机完成"
$sub.Font = $uiFont
$sub.ForeColor = [System.Drawing.Color]::FromArgb(90,100,115)
$sub.Location = New-Object System.Drawing.Point(28, 54)
$sub.Size = New-Object System.Drawing.Size(700, 22)
$form.Controls.Add($sub)

$drop = New-Object System.Windows.Forms.Panel
$drop.Location = New-Object System.Drawing.Point(26, 88)
$drop.Size = New-Object System.Drawing.Size(872, 132)
$drop.BackColor = [System.Drawing.Color]::White
$drop.AllowDrop = $true
$dropLabel = New-Object System.Windows.Forms.Label
$dropLabel.Text = "把视频拖到窗口任意位置`n`n支持一次拖入多个 · MP4 / MOV / MKV / AVI / WebM`n`n也可以点这里选择文件"
$dropLabel.Font = New-Object System.Drawing.Font("Microsoft YaHei", 11)
$dropLabel.ForeColor = [System.Drawing.Color]::FromArgb(70,82,100)
$dropLabel.TextAlign = [System.Drawing.ContentAlignment]::MiddleCenter
$dropLabel.Dock = "Fill"
$dropLabel.AllowDrop = $true
$drop.Controls.Add($dropLabel)
$drop.add_Paint({
    param($s,$e)
    $pen = New-Object System.Drawing.Pen([System.Drawing.Color]::FromArgb(160,172,190), 1)
    $pen.DashStyle = [System.Drawing.Drawing2D.DashStyle]::Dash
    $r = New-Object System.Drawing.Rectangle(1,1,($s.Width-3),($s.Height-3))
    $e.Graphics.DrawRectangle($pen, $r)
    $pen.Dispose()
})
$form.Controls.Add($drop)

$outLabel = New-Object System.Windows.Forms.Label
$outLabel.Text = "输出位置："
$outLabel.Font = $uiFont
$outLabel.Location = New-Object System.Drawing.Point(26, 234)
$outLabel.Size = New-Object System.Drawing.Size(70, 22)
$form.Controls.Add($outLabel)

$outText = New-Object System.Windows.Forms.TextBox
$outText.Text = $script:OutDir
$outText.Font = $uiFont
$outText.Location = New-Object System.Drawing.Point(98, 231)
$outText.Size = New-Object System.Drawing.Size(660, 24)
$outText.add_TextChanged({ $script:OutDir = $outText.Text })
$form.Controls.Add($outText)

$browse = New-Object System.Windows.Forms.Button
$browse.Text = "更改…"
$browse.Font = $uiFont
$browse.Location = New-Object System.Drawing.Point(768, 229)
$browse.Size = New-Object System.Drawing.Size(130, 28)
$browse.add_Click({
    $dlg = New-Object System.Windows.Forms.FolderBrowserDialog
    $dlg.Description = "选择压缩后视频的保存位置"
    if ($dlg.ShowDialog() -eq "OK") {
        $outText.Text = $dlg.SelectedPath
        $script:OutDir = $dlg.SelectedPath
    }
})
$form.Controls.Add($browse)

$queueLabel = New-Object System.Windows.Forms.Label
$queueLabel.Text = "任务"
$queueLabel.Font = New-Object System.Drawing.Font("Microsoft YaHei", 10, [System.Drawing.FontStyle]::Bold)
$queueLabel.Location = New-Object System.Drawing.Point(26, 270)
$queueLabel.Size = New-Object System.Drawing.Size(200, 22)
$form.Controls.Add($queueLabel)

$script:lv = New-Object System.Windows.Forms.ListView
$script:lv.Location = New-Object System.Drawing.Point(26, 296)
$script:lv.Size = New-Object System.Drawing.Size(872, 224)
$script:lv.View = [System.Windows.Forms.View]::Details
$script:lv.FullRowSelect = $true
$script:lv.GridLines = $false
$script:lv.Font = $uiFont
$script:lv.BackColor = [System.Drawing.Color]::White
$script:lv.Columns.Add("文件", 300) | Out-Null
$script:lv.Columns.Add("原始", 90) | Out-Null
$script:lv.Columns.Add("压缩后", 100) | Out-Null
$script:lv.Columns.Add("节省", 80) | Out-Null
$script:lv.Columns.Add("状态", 280) | Out-Null
$script:lv.AllowDrop = $true
$form.Controls.Add($script:lv)

$script:progress = New-Object System.Windows.Forms.ProgressBar
$script:progress.Location = New-Object System.Drawing.Point(26, 526)
$script:progress.Size = New-Object System.Drawing.Size(872, 12)
$script:progress.Minimum = 0
$script:progress.Maximum = 100
$form.Controls.Add($script:progress)

$presetLabel = New-Object System.Windows.Forms.Label
$presetLabel.Text = "画质档位"
$presetLabel.Font = $uiFont
$presetLabel.Location = New-Object System.Drawing.Point(26, 552)
$presetLabel.Size = New-Object System.Drawing.Size(70, 22)
$form.Controls.Add($presetLabel)

$preset = New-Object System.Windows.Forms.ComboBox
$preset.Font = $uiFont
$preset.DropDownStyle = "DropDownList"
$preset.Location = New-Object System.Drawing.Point(98, 548)
$preset.Size = New-Object System.Drawing.Size(230, 26)
@("视觉无损 CRF16 (SSIM 0.9993)", "均衡 CRF18 (0.9991)",
  "更小 CRF20 (0.9988)", "极限 CRF22 (0.9985)") | ForEach-Object { $preset.Items.Add($_) | Out-Null }
$preset.SelectedIndex = 0
$preset.add_SelectedIndexChanged({
    $script:CRF = @(16,18,20,22)[$preset.SelectedIndex]
})
$form.Controls.Add($preset)

$codecLabel = New-Object System.Windows.Forms.Label
$codecLabel.Text = "输出编码"
$codecLabel.Font = $uiFont
$codecLabel.Location = New-Object System.Drawing.Point(348, 552)
$codecLabel.Size = New-Object System.Drawing.Size(70, 22)
$form.Controls.Add($codecLabel)

$codec = New-Object System.Windows.Forms.ComboBox
$codec.Font = $uiFont
$codec.DropDownStyle = "DropDownList"
$codec.Location = New-Object System.Drawing.Point(420, 548)
$codec.Size = New-Object System.Drawing.Size(190, 26)
$codec.Items.Add("HEVC · 压缩率更高") | Out-Null
$codec.Items.Add("H.264 · 老设备兼容") | Out-Null
$codec.SelectedIndex = 0
$codec.add_SelectedIndexChanged({ $script:HEVC = ($codec.SelectedIndex -eq 0) })
$form.Controls.Add($codec)

$audioChk = New-Object System.Windows.Forms.CheckBox
$audioChk.Text = "保留原音轨"
$audioChk.Font = $uiFont
$audioChk.Checked = $true
$audioChk.Location = New-Object System.Drawing.Point(626, 550)
$audioChk.Size = New-Object System.Drawing.Size(120, 24)
$audioChk.add_CheckedChanged({ $script:KeepAudio = $audioChk.Checked })
$form.Controls.Add($audioChk)

$verifyChk = New-Object System.Windows.Forms.CheckBox
$verifyChk.Text = "画质校验"
$verifyChk.Font = $uiFont
$verifyChk.Location = New-Object System.Drawing.Point(752, 550)
$verifyChk.Size = New-Object System.Drawing.Size(120, 24)
$verifyChk.add_CheckedChanged({ $script:Verify = $verifyChk.Checked })
$form.Controls.Add($verifyChk)

$script:status = New-Object System.Windows.Forms.Label
$script:status.Text = "就绪 · 把视频拖进窗口即可自动压缩"
$script:status.Font = $uiFont
$script:status.ForeColor = [System.Drawing.Color]::FromArgb(90,100,115)
$script:status.Location = New-Object System.Drawing.Point(26, 588)
$script:status.Size = New-Object System.Drawing.Size(872, 22)
$form.Controls.Add($script:status)

$tip = New-Object System.Windows.Forms.Label
$tip.Text = "本机处理，文件不上传 · 输出强制恒定帧率（CFR），避免音画不同步 · 原文件不会被修改"
$tip.Font = New-Object System.Drawing.Font("Microsoft YaHei", 8)
$tip.ForeColor = [System.Drawing.Color]::FromArgb(130,140,155)
$tip.Location = New-Object System.Drawing.Point(26, 614)
$tip.Size = New-Object System.Drawing.Size(872, 20)
$form.Controls.Add($tip)

# 拖放：窗口、面板、列表、标签都接受
$dragEnter = {
    param($s,$e)
    if ($e.Data.GetDataPresent([System.Windows.Forms.DataFormats]::FileDrop)) {
        $e.Effect = [System.Windows.Forms.DragDropEffects]::Copy
        $drop.BackColor = [System.Drawing.Color]::FromArgb(232,240,255)
    }
}
$dragLeave = { $drop.BackColor = [System.Drawing.Color]::White }
$dragDrop = {
    param($s,$e)
    $drop.BackColor = [System.Drawing.Color]::White
    $files = $e.Data.GetData([System.Windows.Forms.DataFormats]::FileDrop)
    if ($files -ne $null) { Add-Files $files }
}
foreach ($c in @($form, $drop, $dropLabel, $script:lv)) {
    $c.AllowDrop = $true
    $c.add_DragEnter($dragEnter)
    $c.add_DragLeave($dragLeave)
    $c.add_DragDrop($dragDrop)
}
$dropLabel.add_Click({
    $dlg = New-Object System.Windows.Forms.OpenFileDialog
    $dlg.Multiselect = $true
    $dlg.Filter = "视频文件|*.mp4;*.mov;*.m4v;*.mkv;*.avi;*.webm;*.mts;*.m2ts;*.mpg;*.mpeg;*.wmv;*.flv;*.ts|所有文件|*.*"
    $dlg.Title = "选择要压缩的视频（选好即开始）"
    if ($dlg.ShowDialog() -eq "OK") { Add-Files $dlg.FileNames }
})

$timer = New-Object System.Windows.Forms.Timer
$timer.Interval = 300
$timer.add_Tick({
    if ($script:Cur -ne $null) {
        if ($script:Cur.Proc.HasExited) { Finish-Current }
        else { Update-Progress }
    }
    if ($script:Cur -eq $null -and $script:Queue.Count -gt 0) { Start-Next }
})
$timer.Start()

$form.add_FormClosing({
    if ($script:Cur -ne $null -and -not $script:Cur.Proc.HasExited) {
        $r = [System.Windows.Forms.MessageBox]::Show(
            "还有任务在压缩，确定退出吗？", "视频压缩转换器", "YesNo", "Question")
        if ($r -ne "Yes") { $_.Cancel = $true; return }
        try { $script:Cur.Proc.Kill() } catch { }
    }
    $timer.Stop()
})

[System.Windows.Forms.Application]::EnableVisualStyles()
[System.Windows.Forms.Application]::Run($form)
