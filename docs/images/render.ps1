# Renders every SVG in this folder to a 2x PNG (for Medium, which doesn't accept SVG) using headless Edge.
$edge = "${env:ProgramFiles(x86)}\Microsoft\Edge\Application\msedge.exe"
foreach ($svg in Get-ChildItem $PSScriptRoot -Filter *.svg) {
    $xml = [xml](Get-Content $svg.FullName -Raw)
    $w = [int]$xml.svg.width; $h = [int]$xml.svg.height
    $png = [IO.Path]::ChangeExtension($svg.FullName, '.png')
    $uri = ([uri]$svg.FullName).AbsoluteUri
    & $edge --headless=new --disable-gpu --hide-scrollbars --force-device-scale-factor=2 "--window-size=$w,$h" "--screenshot=$png" $uri 2>$null | Out-Null
    Start-Sleep -Milliseconds 300
    Write-Host "Rendered $($svg.Name) -> $([IO.Path]::GetFileName($png))"
}
