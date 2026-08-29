param(
    [Parameter(Mandatory = $true)]
    [string]$Source,

    [Parameter(Mandatory = $true)]
    [string]$UpstreamRoot
)

$ErrorActionPreference = "Stop"

$sourcePath = (Resolve-Path $Source).Path
$upstreamPath = (Resolve-Path $UpstreamRoot).Path
$runtimeIcon = Join-Path $upstreamPath "icon.png"
$resourceIcon = Join-Path $upstreamPath "icon.ico"
$tempPng = Join-Path $env:RUNNER_TEMP "seal-pairing-icon-256.png"

Add-Type -AssemblyName System.Drawing

$image = [System.Drawing.Image]::FromFile($sourcePath)
try {
    if ($image.Width -lt 256 -or $image.Height -lt 256) {
        throw "Seal app icon must be at least 256x256, got $($image.Width)x$($image.Height)"
    }

    Copy-Item $sourcePath $runtimeIcon -Force

    $bitmap = New-Object System.Drawing.Bitmap 256, 256, ([System.Drawing.Imaging.PixelFormat]::Format32bppArgb)
    try {
        $graphics = [System.Drawing.Graphics]::FromImage($bitmap)
        try {
            $graphics.Clear([System.Drawing.Color]::Transparent)
            $graphics.CompositingMode = [System.Drawing.Drawing2D.CompositingMode]::SourceOver
            $graphics.CompositingQuality = [System.Drawing.Drawing2D.CompositingQuality]::HighQuality
            $graphics.InterpolationMode = [System.Drawing.Drawing2D.InterpolationMode]::HighQualityBicubic
            $graphics.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::HighQuality
            $graphics.PixelOffsetMode = [System.Drawing.Drawing2D.PixelOffsetMode]::HighQuality
            $graphics.DrawImage(
                $image,
                [System.Drawing.Rectangle]::new(0, 0, 256, 256),
                0,
                0,
                $image.Width,
                $image.Height,
                [System.Drawing.GraphicsUnit]::Pixel
            )
        }
        finally {
            $graphics.Dispose()
        }

        $bitmap.Save($tempPng, [System.Drawing.Imaging.ImageFormat]::Png)
    }
    finally {
        $bitmap.Dispose()
    }
}
finally {
    $image.Dispose()
}

$pngBytes = [System.IO.File]::ReadAllBytes($tempPng)
$stream = [System.IO.File]::Create($resourceIcon)
try {
    $writer = New-Object System.IO.BinaryWriter($stream)
    try {
        # ICONDIR
        $writer.Write([UInt16]0) # reserved
        $writer.Write([UInt16]1) # icon
        $writer.Write([UInt16]1) # one image

        # ICONDIRENTRY. Width/height 0 means 256 pixels.
        $writer.Write([Byte]0)
        $writer.Write([Byte]0)
        $writer.Write([Byte]0)   # palette size
        $writer.Write([Byte]0)   # reserved
        $writer.Write([UInt16]1) # color planes
        $writer.Write([UInt16]32)
        $writer.Write([UInt32]$pngBytes.Length)
        $writer.Write([UInt32]22)
        $writer.Write($pngBytes)
    }
    finally {
        $writer.Dispose()
    }
}
finally {
    $stream.Dispose()
}

Remove-Item $tempPng -Force -ErrorAction SilentlyContinue

$sourceHash = (Get-FileHash $sourcePath -Algorithm SHA256).Hash
$runtimeHash = (Get-FileHash $runtimeIcon -Algorithm SHA256).Hash
if ($sourceHash -ne $runtimeHash) {
    throw "Runtime icon did not preserve the Seal app icon bytes"
}
if ((Get-Item $resourceIcon).Length -lt 1024) {
    throw "Generated Windows icon resource is unexpectedly small"
}

Write-Host "Seal app icon staged for runtime and Windows PE resource."
Write-Host "Source: $sourcePath"
Write-Host "Runtime PNG: $runtimeIcon"
Write-Host "Windows ICO: $resourceIcon"
