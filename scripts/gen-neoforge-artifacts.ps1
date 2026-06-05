param(
    [string]$NeoForgeVersion = "21.1.233",
    [string]$McVersion = "1.21.1",
    [string]$NeoFormVersion = "20240808.144430",
    [string]$JavaExe = "C:\Program Files\Amazon Corretto\jdk25.0.3_9\bin\java.exe"
)

$ErrorActionPreference = "Stop"
$root = Split-Path $PSScriptRoot -Parent
$mcAndNeoForm = "$McVersion-$NeoFormVersion"
$work = Join-Path $env:TEMP "nfgen-$NeoForgeVersion"
$target = Join-Path $work "mc"
$installer = Join-Path $work "neoforge-$NeoForgeVersion-installer.jar"
$url = "https://maven.neoforged.net/releases/net/neoforged/neoforge/$NeoForgeVersion/neoforge-$NeoForgeVersion-installer.jar"

New-Item -ItemType Directory -Force -Path $target | Out-Null
'{"profiles":{},"settings":{},"version":3}' | Set-Content (Join-Path $target "launcher_profiles.json") -Encoding ascii

if (-not (Test-Path $installer)) {
    Write-Host "Downloading $url"
    Invoke-WebRequest -UseBasicParsing -Uri $url -OutFile $installer -TimeoutSec 180
}

Write-Host "Running NeoForge installer (downloads vanilla + runs processors)"
& $JavaExe -jar $installer --install-client $target
if ($LASTEXITCODE -ne 0) { throw "installer failed ($LASTEXITCODE)" }

$lib = Join-Path $target "libraries"
$srg = "net\minecraft\client\$mcAndNeoForm\client-$mcAndNeoForm-srg.jar"
$extra = "net\minecraft\client\$mcAndNeoForm\client-$mcAndNeoForm-extra.jar"
$patched = "net\neoforged\neoforge\$NeoForgeVersion\neoforge-$NeoForgeVersion-client.jar"
$universal = Join-Path $lib "net\neoforged\neoforge\$NeoForgeVersion\neoforge-$NeoForgeVersion-universal.jar"
$atConfig = Join-Path $work "accesstransformer.cfg"

$dstRoot = Join-Path $root "prebuilt\neoforge\libraries"
foreach ($rel in @($srg, $extra, $patched)) {
    $src = Join-Path $lib $rel
    if (-not (Test-Path $src)) { throw "installer did not produce $rel" }
    $dst = Join-Path $dstRoot $rel
    New-Item -ItemType Directory -Force -Path (Split-Path $dst -Parent) | Out-Null
    Copy-Item $src $dst -Force
    Write-Host ("staged {0}  ({1:N0} bytes)" -f $rel, (Get-Item $dst).Length)
}

if (-not (Test-Path $universal)) { throw "installer did not download $universal" }
Push-Location $work
try {
    & jar xf $universal META-INF/accesstransformer.cfg
    $extractedAt = Join-Path $work "META-INF\accesstransformer.cfg"
    if (-not (Test-Path $extractedAt)) { throw "NeoForge universal jar did not contain META-INF/accesstransformer.cfg" }
    Copy-Item $extractedAt $atConfig -Force
} finally {
    Pop-Location
}

$toolJars = @(
    "org\ow2\asm\asm\9.8\asm-9.8.jar",
    "org\ow2\asm\asm-tree\9.8\asm-tree-9.8.jar",
    "org\ow2\asm\asm-commons\9.8\asm-commons-9.8.jar",
    "org\ow2\asm\asm-analysis\9.8\asm-analysis-9.8.jar",
    "org\ow2\asm\asm-util\9.8\asm-util-9.8.jar",
    "org\antlr\antlr4-runtime\4.13.1\antlr4-runtime-4.13.1.jar",
    "org\slf4j\slf4j-api\2.0.9\slf4j-api-2.0.9.jar",
    "net\neoforged\accesstransformers\10.0.1\accesstransformers-10.0.1.jar"
) | ForEach-Object {
    $jarPath = Join-Path $lib $_
    if (-not (Test-Path $jarPath)) { throw "access transformer helper dependency missing: $jarPath" }
    $jarPath
}
$toolClasses = Join-Path $work "tool-classes"
$toolClassPath = ($toolJars + @($toolClasses)) -join [IO.Path]::PathSeparator
$toolSource = Join-Path $root "scripts\ApplyAccessTransformers.java"
$javacExe = Join-Path (Split-Path (Split-Path $JavaExe -Parent) -Parent) "bin\javac.exe"
if (-not (Test-Path $javacExe)) { throw "javac not found next to $JavaExe" }
New-Item -ItemType Directory -Force -Path $toolClasses | Out-Null
Write-Host "Compiling access transformer helper"
& $javacExe -cp ($toolJars -join [IO.Path]::PathSeparator) -d $toolClasses $toolSource
if ($LASTEXITCODE -ne 0) { throw "access transformer helper compile failed ($LASTEXITCODE)" }

$dstSrg = Join-Path $dstRoot $srg
$tmpSrg = "$dstSrg.at-tmp"
Remove-Item -Force $tmpSrg -ErrorAction SilentlyContinue
Write-Host "Applying NeoForge access transformers to staged SRG client jar"
& $JavaExe -cp $toolClassPath ApplyAccessTransformers $dstSrg $atConfig $tmpSrg
if ($LASTEXITCODE -ne 0) { throw "access transformer helper failed ($LASTEXITCODE)" }
Move-Item $tmpSrg $dstSrg -Force
Write-Host ("access-transformed {0}  ({1:N0} bytes)" -f $srg, (Get-Item $dstSrg).Length)

Remove-Item -Recurse -Force $work -ErrorAction SilentlyContinue
Write-Host "done. prebuilt jars updated under prebuilt\neoforge\libraries"
