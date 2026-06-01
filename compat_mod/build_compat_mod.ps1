param(
    [string]$MinecraftVersion,
    [string]$LoaderVersion,
    [string]$OutputDir
)

$ErrorActionPreference = "Stop"

. (Join-Path (Split-Path $PSScriptRoot -Parent) "scripts\common.ps1")

$root = Resolve-RepoRoot
$srcJava = Join-Path $PSScriptRoot "src\main\java"
$srcResources = Join-Path $PSScriptRoot "src\main\resources"
if (-not $MinecraftVersion) { $MinecraftVersion = $ProjectConfig.MinecraftVersion }
if (-not $LoaderVersion) { $LoaderVersion = $ProjectConfig.FabricLoaderVersion }
$buildRoot = Join-Path (Get-ConfigPath "BuildDir") "compat_mod\$MinecraftVersion-$LoaderVersion"
$classesDir = Join-Path $buildRoot "classes"
$compatJarName = "$($ProjectConfig.CompatModId)-$($ProjectConfig.CompatModVersion).jar"
$jarPath = Join-Path $buildRoot $compatJarName
$gameDir = Get-ConfigPath "GameDir"
$modsDir = Join-Path $gameDir "mods"

$javaHome = Resolve-JavaHome
$javac = Join-Path $javaHome "bin\javac.exe"
$jar = Join-Path $javaHome "bin\jar.exe"
$mixinVersion = $ProjectConfig.MixinVersion
$mixinJar = Join-Path $gameDir "libraries\net\fabricmc\sponge-mixin\$mixinVersion\sponge-mixin-$mixinVersion.jar"
$clientJar = Join-Path $gameDir ".fabric\remappedJars\minecraft-$MinecraftVersion-$LoaderVersion\client-intermediary.jar"
if (-not (Test-Path $clientJar)) {
    Write-Host "Remapped client jar missing for $MinecraftVersion-${LoaderVersion}; preparing Fabric cache."
    & (Join-Path $root "scripts\prepare-ci-cache.ps1") `
        -MinecraftVersion $MinecraftVersion `
        -FabricLoaderVersion $LoaderVersion
}
if (-not (Test-Path $clientJar)) {
    throw "Remapped client jar not found for $MinecraftVersion-${LoaderVersion}: $clientJar."
}

Remove-Item -Recurse -Force $buildRoot -ErrorAction SilentlyContinue
New-Item -ItemType Directory -Force -Path $classesDir | Out-Null
New-Item -ItemType Directory -Force -Path $modsDir | Out-Null

$sources = Get-ChildItem $srcJava -Recurse -Filter "*.java" | Select-Object -ExpandProperty FullName
$disabledMixins = @()
if ($MinecraftVersion -eq $ProjectConfig.MinecraftVersion) {
    $disabledMixins += "ZipFsBypass121Mixin"
} else {
    $disabledMixins += @(
        "WorldLoadProgressTrackerMixin",
        "SystemDetailsOshiBypassMixin"
    )
    if ($MinecraftVersion -eq "1.21.1") {
        $disabledMixins += "ZipFsBypassMixin"
    } elseif ($MinecraftVersion -eq "1.20.4") {
        $disabledMixins += @("MinecraftClientProbeMixin", "ZipFsBypassMixin")
    } else {
        $disabledMixins += @("MinecraftClientProbeMixin", "PathUtilBypassMixin", "ZipFsBypassMixin", "ZipFsBypass121Mixin")
    }
}
$sources = @($sources | Where-Object {
    $name = [System.IO.Path]::GetFileNameWithoutExtension($_)
    $disabledMixins -notcontains $name
})
if (-not $sources) { throw "No compatibility mod sources found" }

$cp = @($clientJar, $mixinJar) -join ";"
$javaRelease = if ($MinecraftVersion -eq $ProjectConfig.MinecraftVersion) { 21 } else { 8 }
& $javac --release $javaRelease -proc:none -cp $cp -d $classesDir $sources
if ($LASTEXITCODE -ne 0) { throw "compatibility mod compile failed" }

Copy-Item -Recurse "$srcResources\*" $classesDir -Force
$fmj = Join-Path $classesDir "fabric.mod.json"
(Get-Content $fmj -Raw).
    Replace("__MINECRAFT_VERSION__", $MinecraftVersion).
    Replace("__FABRIC_LOADER_VERSION__", $LoaderVersion) |
    Set-Content $fmj -NoNewline

if ($disabledMixins.Count -gt 0 -or $MinecraftVersion -ne $ProjectConfig.MinecraftVersion) {
    $mixinsPath = Join-Path $classesDir "banditvault-xbox-compat.mixins.json"
    $mixins = Get-Content -Raw -Path $mixinsPath | ConvertFrom-Json
    if ($MinecraftVersion -ne $ProjectConfig.MinecraftVersion) {
        $mixins.compatibilityLevel = "JAVA_8"
    }
    if ($disabledMixins.Count -gt 0) {
        $mixins.client = @($mixins.client | Where-Object { $disabledMixins -notcontains $_ })
    }
    $mixins | ConvertTo-Json -Depth 10 | Set-Content -Path $mixinsPath
}

Push-Location $classesDir
& $jar cf $jarPath .
if ($LASTEXITCODE -ne 0) {
    Pop-Location
    throw "compatibility mod jar failed"
}
Pop-Location

if ($OutputDir) {
    New-Item -ItemType Directory -Force -Path $OutputDir | Out-Null
    Copy-Item $jarPath (Join-Path $OutputDir $compatJarName) -Force
} else {
    Copy-Item $jarPath (Join-Path $modsDir $compatJarName) -Force
}
Write-Host "Compatibility mod built ($MinecraftVersion) -> $jarPath"
