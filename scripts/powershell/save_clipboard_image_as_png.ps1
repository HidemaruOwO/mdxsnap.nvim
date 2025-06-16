Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
$image = [System.Windows.Forms.Clipboard]::GetImage()
if ($image -ne $null) {
    $timestamp = Get-Date -Format "yyyyMMddHHmmssfff"
    $tempDir = [System.IO.Path]::GetTempPath()
    $fileName = "mdxsnap_clip_" + $timestamp + ".png"
    $filePath = [System.IO.Path]::Combine($tempDir, $fileName)
    try {
        $image.Save($filePath, [System.Drawing.Imaging.ImageFormat]::Png)
        Write-Output $filePath
    } catch {
        Write-Output "ErrorSavingImage"
    }
} else {
    Write-Output "NoImage"
}