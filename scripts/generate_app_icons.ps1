# Генерация иконок приложения «Easy Pack Pro» для Windows и Android.
#
# Нарезает логотип компании под все размеры, чтобы их не приходилось править
# вручную в пяти папках. Тот же файл показывает и само приложение
# (lib/widgets/brand_mark.dart), поэтому иконка и логотип на экранах запуска
# и входа не разъезжаются.
#
# Запуск:  powershell -ExecutionPolicy Bypass -File scripts/generate_app_icons.ps1
#
# Источники (лежат в репозитории, правятся только заменой файла):
#   assets/branding/app_icon.png — логотип, из него режутся размеры Android;
#   assets/branding/app_icon.ico — многоразмерная иконка Windows. Если файл
#     есть, он копируется как есть: кадры под 16/32/48 px нарисованы отдельно
#     и читаются лучше, чем автоматическое уменьшение большого логотипа.
#
# Ключ -Redraw рисует запасной знак вместо логотипа (нужен, только если
# исходников нет).

param([switch]$Redraw)

Add-Type -AssemblyName System.Drawing

$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$brandingDir = Join-Path $root 'assets\branding'
$sourcePath = Join-Path $brandingDir 'app_icon.png'

function New-BrandIcon {
    param([int]$Size)

    $bmp = New-Object System.Drawing.Bitmap($Size, $Size)
    $g = [System.Drawing.Graphics]::FromImage($bmp)
    $g.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::AntiAlias
    $g.InterpolationMode = [System.Drawing.Drawing2D.InterpolationMode]::HighQualityBicubic

    # Скруглённый квадрат с градиентом (те же цвета, что в BrandColors).
    $radius = [int]($Size * 0.24)
    $path = New-Object System.Drawing.Drawing2D.GraphicsPath
    $d = $radius * 2
    $path.AddArc(0, 0, $d, $d, 180, 90)
    $path.AddArc($Size - $d, 0, $d, $d, 270, 90)
    $path.AddArc($Size - $d, $Size - $d, $d, $d, 0, 90)
    $path.AddArc(0, $Size - $d, $d, $d, 90, 90)
    $path.CloseFigure()

    $brush = New-Object System.Drawing.Drawing2D.LinearGradientBrush(
        (New-Object System.Drawing.Point(0, 0)),
        (New-Object System.Drawing.Point($Size, $Size)),
        [System.Drawing.Color]::FromArgb(255, 106, 108, 247),
        [System.Drawing.Color]::FromArgb(255, 139, 92, 246))
    $g.FillPath($brush, $path)

    # Коробка в изометрии — те же пропорции, что у _BoxGlyphPainter.
    $glyph = $Size * 0.56
    $ox = ($Size - $glyph) / 2.0
    $oy = ($Size - $glyph) / 2.0
    function P([double]$fx, [double]$fy) {
        New-Object System.Drawing.PointF(
            [float]($ox + $glyph * $fx), [float]($oy + $glyph * $fy))
    }

    $top = @((P 0.5 0.06), (P 0.94 0.30), (P 0.5 0.54), (P 0.06 0.30))
    $left = @((P 0.06 0.30), (P 0.5 0.54), (P 0.5 0.96), (P 0.06 0.72))
    $right = @((P 0.94 0.30), (P 0.5 0.54), (P 0.5 0.96), (P 0.94 0.72))

    $fillSoft = New-Object System.Drawing.SolidBrush(
        [System.Drawing.Color]::FromArgb(46, 255, 255, 255))
    $fillTop = New-Object System.Drawing.SolidBrush(
        [System.Drawing.Color]::FromArgb(87, 255, 255, 255))
    $g.FillPolygon($fillSoft, $left)
    $g.FillPolygon($fillTop, $top)

    $pen = New-Object System.Drawing.Pen(
        [System.Drawing.Color]::White, [float]($glyph * 0.09))
    $pen.LineJoin = [System.Drawing.Drawing2D.LineJoin]::Round
    $pen.StartCap = [System.Drawing.Drawing2D.LineCap]::Round
    $pen.EndCap = [System.Drawing.Drawing2D.LineCap]::Round
    $g.DrawPolygon($pen, $top)
    $g.DrawPolygon($pen, $left)
    $g.DrawPolygon($pen, $right)

    $pen.Dispose(); $brush.Dispose(); $path.Dispose()
    $fillSoft.Dispose(); $fillTop.Dispose(); $g.Dispose()
    return $bmp
}

function Resize-Bitmap {
    param([System.Drawing.Bitmap]$Source, [int]$Size)
    $bmp = New-Object System.Drawing.Bitmap($Size, $Size)
    $g = [System.Drawing.Graphics]::FromImage($bmp)
    $g.InterpolationMode = [System.Drawing.Drawing2D.InterpolationMode]::HighQualityBicubic
    $g.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::AntiAlias
    $g.PixelOffsetMode = [System.Drawing.Drawing2D.PixelOffsetMode]::HighQuality
    $g.DrawImage($Source, 0, 0, $Size, $Size)
    $g.Dispose()
    return $bmp
}

# ---------------------------------------------------------------- источник
New-Item -ItemType Directory -Force -Path $brandingDir | Out-Null

if (-not $Redraw -and (Test-Path $sourcePath)) {
    # Bitmap держит файл открытым — читаем в память, чтобы скрипт мог
    # перезаписать тот же путь при повторном запуске.
    $srcBytes = [System.IO.File]::ReadAllBytes($sourcePath)
    $srcStream = New-Object System.IO.MemoryStream(, $srcBytes)
    $master = [System.Drawing.Bitmap]::FromStream($srcStream)
    Write-Host "Логотип: $sourcePath ($($master.Width)x$($master.Height))"
} else {
    $master = New-BrandIcon -Size 1024
    $master.Save($sourcePath, [System.Drawing.Imaging.ImageFormat]::Png)
    Write-Host "Нарисован запасной знак: $sourcePath (1024x1024)"
}

# ---------------------------------------------------------------- Android
$androidSizes = @{
    'mipmap-mdpi'    = 48
    'mipmap-hdpi'    = 72
    'mipmap-xhdpi'   = 96
    'mipmap-xxhdpi'  = 144
    'mipmap-xxxhdpi' = 192
}
foreach ($entry in $androidSizes.GetEnumerator()) {
    $dir = Join-Path $root "android\app\src\main\res\$($entry.Key)"
    New-Item -ItemType Directory -Force -Path $dir | Out-Null
    $target = Join-Path $dir 'ic_launcher.png'
    $scaled = Resize-Bitmap -Source $master -Size $entry.Value
    $scaled.Save($target, [System.Drawing.Imaging.ImageFormat]::Png)
    $scaled.Dispose()
    Write-Host "Android: $target ($($entry.Value)px)"
}

# ---------------------------------------------------------------- Windows
$icoPathOut = Join-Path $root 'windows\runner\resources\app_icon.ico'
$icoSource = Join-Path $brandingDir 'app_icon.ico'
if (-not $Redraw -and (Test-Path $icoSource)) {
    # Побайтно, а не Copy-Item: если приложение запущено, Windows держит
    # ресурс отображённым в память и копирование падает.
    [System.IO.File]::WriteAllBytes(
        $icoPathOut, [System.IO.File]::ReadAllBytes($icoSource))
    Write-Host "Windows: $icoPathOut (из $icoSource)"
    $master.Dispose()
    Write-Host 'Готово.'
    return
}

# ICO собираем вручную: .NET умеет читать .ico, но не писать многоразмерный.
# Внутрь кладём PNG-кадры — формат это допускает начиная с Vista.
$icoSizes = @(16, 24, 32, 48, 64, 128, 256)
$frames = @()
foreach ($size in $icoSizes) {
    $scaled = Resize-Bitmap -Source $master -Size $size
    $ms = New-Object System.IO.MemoryStream
    $scaled.Save($ms, [System.Drawing.Imaging.ImageFormat]::Png)
    $frames += , @{ Size = $size; Bytes = $ms.ToArray() }
    $ms.Dispose(); $scaled.Dispose()
}

$icoPath = $icoPathOut
$out = New-Object System.IO.MemoryStream
$writer = New-Object System.IO.BinaryWriter($out)
$writer.Write([uint16]0)                  # reserved
$writer.Write([uint16]1)                  # type: icon
$writer.Write([uint16]$frames.Count)

$offset = 6 + 16 * $frames.Count
foreach ($frame in $frames) {
    $dim = if ($frame.Size -ge 256) { 0 } else { $frame.Size }
    $writer.Write([byte]$dim)             # width
    $writer.Write([byte]$dim)             # height
    $writer.Write([byte]0)                # palette
    $writer.Write([byte]0)                # reserved
    $writer.Write([uint16]1)              # colour planes
    $writer.Write([uint16]32)             # bits per pixel
    $writer.Write([uint32]$frame.Bytes.Length)
    $writer.Write([uint32]$offset)
    $offset += $frame.Bytes.Length
}
foreach ($frame in $frames) { $writer.Write($frame.Bytes) }
$writer.Flush()
[System.IO.File]::WriteAllBytes($icoPath, $out.ToArray())
$writer.Dispose(); $out.Dispose()
Write-Host "Windows: $icoPath ($($frames.Count) размеров)"

$master.Dispose()
Write-Host 'Готово.'
