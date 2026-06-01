param(
    [string]$MinecraftVersion,
    [string]$FabricLoaderVersion,
    [string]$AssetIndex
)

# Prepare the ignored build cache needed by build.ps1 on a clean CI runner.
$ErrorActionPreference = "Stop"
$ProgressPreference = "SilentlyContinue"

if ($MinecraftVersion) { $env:MC_VERSION = $MinecraftVersion }
if ($FabricLoaderVersion) { $env:FABRIC_LOADER_VERSION = $FabricLoaderVersion }
if ($AssetIndex) { $env:MC_ASSET_INDEX = $AssetIndex }

. (Join-Path $PSScriptRoot "common.ps1")

$root = Resolve-RepoRoot
$gameDir = Get-ConfigPath "GameDir"
$assetsDir = Get-ConfigPath "AssetsDir"
$version = if ($MinecraftVersion) { $MinecraftVersion } else { $ProjectConfig.MinecraftVersion }
$loaderVersion = if ($FabricLoaderVersion) { $FabricLoaderVersion } else { $ProjectConfig.FabricLoaderVersion }
$nativesDir = if ($MinecraftVersion -and $MinecraftVersion -ne $ProjectConfig.MinecraftVersion) {
    Join-Path (Get-ConfigPath "CacheDir") ("natives-" + ($MinecraftVersion -replace '[^A-Za-z0-9_.-]', '_'))
} else {
    Get-ConfigPath "NativesDir"
}
$toolsDir = Get-ConfigPath "ToolsDir"
$notesDir = Get-ConfigPath "NotesDir"
$assetIndex = if ($AssetIndex) { $AssetIndex } else { "" }
$javaHome = Resolve-JavaHome
$javaExe = Join-Path $javaHome "bin\java.exe"

function Get-SafeFileName {
    param([Parameter(Mandatory = $true)][string]$Value)
    return ($Value -replace '[^A-Za-z0-9_.-]', '_')
}

function Get-MinecraftVersionJson {
    $manifest = Invoke-WebRequest -UseBasicParsing -Uri "https://piston-meta.mojang.com/mc/game/version_manifest_v2.json" | ConvertFrom-Json
    $entry = $manifest.versions | Where-Object { $_.id -eq $version } | Select-Object -First 1
    if (-not $entry) {
        throw "Minecraft version $version not found in Mojang manifest."
    }

    return Invoke-WebRequest -UseBasicParsing -Uri $entry.url | ConvertFrom-Json
}

function Save-RemoteFile {
    param(
        [Parameter(Mandatory = $true)][string]$Uri,
        [Parameter(Mandatory = $true)][string]$Path
    )

    if (Test-Path $Path) {
        return
    }

    New-Item -ItemType Directory -Force -Path (Split-Path $Path -Parent) | Out-Null
    Invoke-WebRequest -UseBasicParsing -Uri $Uri -OutFile $Path
}

function Expand-NativeJar {
    param(
        [Parameter(Mandatory = $true)][string]$Path
    )

    $extracted = 0
    $zip = [System.IO.Compression.ZipFile]::OpenRead($Path)
    try {
        foreach ($entry in $zip.Entries) {
            if (-not $entry.Name -or -not $entry.Name.EndsWith(".dll", [System.StringComparison]::OrdinalIgnoreCase)) {
                continue
            }

            $dest = Join-Path $nativesDir $entry.Name
            [System.IO.Compression.ZipFileExtensions]::ExtractToFile($entry, $dest, $true)
            Write-Host "Native: $($entry.Name)"
            $extracted++
        }
    } finally {
        $zip.Dispose()
    }

    return $extracted
}

function ConvertTo-QuotedProcessArgument {
    param([Parameter(Mandatory = $true)][string]$Value)

    if ($Value -notmatch '[\s"]') {
        return $Value
    }

    return '"' + $Value.Replace('"', '\"') + '"'
}

function Convert-MavenNameToPath {
    param([Parameter(Mandatory = $true)][string]$Name)

    $parts = $Name.Split(":")
    if ($parts.Length -lt 3) {
        throw "Unsupported Maven coordinate: $Name"
    }

    $group = $parts[0].Replace(".", "\")
    $artifact = $parts[1]
    $versionPart = $parts[2]
    $classifier = if ($parts.Length -ge 4) { "-$($parts[3])" } else { "" }
    return "$group\$artifact\$versionPart\$artifact-$versionPart$classifier.jar"
}

function Add-LibraryJar {
    param(
        [System.Collections.Generic.List[string]]$Jars,
        [Parameter(Mandatory = $true)][string]$RelativePath
    )

    $jarPath = Join-Path $gameDir ("libraries\" + $RelativePath.Replace('/', '\'))
    if (Test-Path $jarPath) {
        $Jars.Add($jarPath)
    } else {
        Write-Warning "Classpath library missing: $jarPath"
    }
}

New-Item -ItemType Directory -Force -Path $gameDir, $assetsDir, $nativesDir, $toolsDir, $notesDir | Out-Null

Write-Host "=== Downloading Minecraft libraries ==="
& (Join-Path $root "scripts\download-libs.ps1")

$versionJson = Get-MinecraftVersionJson
if (-not $assetIndex) {
    $assetIndex = $versionJson.assetIndex.id
}

Write-Host "=== Downloading Minecraft native DLLs ==="
Add-Type -AssemblyName System.IO.Compression.FileSystem
foreach ($library in $versionJson.libraries) {
    if (-not $library.natives -or -not $library.natives.windows -or -not $library.downloads.classifiers) {
        continue
    }

    $classifierName = $library.natives.windows.Replace('${arch}', '64')
    $classifierProperty = $library.downloads.classifiers.PSObject.Properties[$classifierName]
    if (-not $classifierProperty -or -not $classifierProperty.Value.url) {
        continue
    }

    $classifier = $classifierProperty.Value
    $zipName = Get-SafeFileName -Value $classifier.path
    $zipPath = Join-Path $toolsDir "natives-$zipName"
    Save-RemoteFile -Uri $classifier.url -Path $zipPath

    Expand-NativeJar -Path $zipPath | Out-Null
}

foreach ($library in $versionJson.libraries) {
    if (-not $library.downloads -or -not $library.downloads.artifact) {
        continue
    }

    $artifact = $library.downloads.artifact
    $libraryName = [string]$library.name
    $artifactPath = [string]$artifact.path
    $isWindowsX64Native =
        $libraryName.EndsWith(":natives-windows", [System.StringComparison]::OrdinalIgnoreCase) -or
        $artifactPath.EndsWith("-natives-windows.jar", [System.StringComparison]::OrdinalIgnoreCase)

    if (-not $isWindowsX64Native) {
        continue
    }

    $jarPath = Join-Path $gameDir ("libraries\" + $artifactPath.Replace('/', '\'))
    Save-RemoteFile -Uri $artifact.url -Path $jarPath
    Expand-NativeJar -Path $jarPath | Out-Null
}

$nativeDlls = @(Get-ChildItem -LiteralPath $nativesDir -Filter "*.dll" -ErrorAction SilentlyContinue)
if (-not $nativeDlls) {
    throw "No native DLLs were prepared under $nativesDir."
}

Write-Host "=== Downloading Fabric installer ==="
$fabricMetadata = [xml](Invoke-WebRequest -UseBasicParsing -Uri "https://maven.fabricmc.net/net/fabricmc/fabric-installer/maven-metadata.xml").Content
$installerVersion = $fabricMetadata.metadata.versioning.release
if (-not $installerVersion) {
    $installerVersion = $fabricMetadata.metadata.versioning.latest
}
if (-not $installerVersion) {
    throw "Could not determine Fabric installer version from Maven metadata."
}

$installerJar = Join-Path $toolsDir "fabric-installer.jar"
$installerUrl = "https://maven.fabricmc.net/net/fabricmc/fabric-installer/$installerVersion/fabric-installer-$installerVersion.jar"
Save-RemoteFile -Uri $installerUrl -Path $installerJar

Write-Host "=== Installing Fabric loader $loaderVersion for Minecraft $version ==="
& $javaExe -jar $installerJar client -dir $gameDir -mcversion $version -loader $loaderVersion -launcher win32 -noprofile
if ($LASTEXITCODE -ne 0) {
    throw "Fabric installer failed."
}

Write-Host "=== Patching Fabric loader $loaderVersion for cache preparation ==="
& (Join-Path $root "scripts\patch-fabric.ps1") -LoaderVersion $loaderVersion
if ($LASTEXITCODE -ne 0) {
    throw "Fabric loader patch failed."
}

Write-Host "=== Downloading asset index ==="
$indexDir = Join-Path $assetsDir "indexes"
New-Item -ItemType Directory -Force -Path $indexDir | Out-Null
$assetIndexId = $versionJson.assetIndex.id
$assetIndexPath = Join-Path $indexDir "$assetIndexId.json"
Save-RemoteFile -Uri $versionJson.assetIndex.url -Path $assetIndexPath
if ($assetIndexId -ne $assetIndex) {
    Write-Warning "Configured asset index is $assetIndex, but Mojang metadata for $version reports $assetIndexId."
}

Write-Host "=== Generating Fabric remapped client jar ==="
$remappedJar = Join-Path $gameDir ".fabric\remappedJars\minecraft-$version-$loaderVersion\client-intermediary.jar"
$existingRemappedJar = Get-Item -LiteralPath $remappedJar -ErrorAction SilentlyContinue
if ($existingRemappedJar -and $existingRemappedJar.Length -le 0) {
    Write-Warning "Discarding empty cached remapped client jar at $remappedJar."
    Remove-Item -LiteralPath $remappedJar -Force
    $existingRemappedJar = $null
}
if ($existingRemappedJar) {
    Write-Host "Using cached Fabric remapped client jar -> $remappedJar"
}
if (-not (Test-Path $remappedJar)) {
    $clientJar = Join-Path $gameDir "versions\$version\$version.jar"
    if (-not (Test-Path $clientJar)) {
        throw "Client jar missing at $clientJar."
    }

    $jars = [System.Collections.Generic.List[string]]::new()
    foreach ($library in $versionJson.libraries) {
        if ($library.downloads -and $library.downloads.artifact) {
            Add-LibraryJar -Jars $jars -RelativePath ([string]$library.downloads.artifact.path)
        }
    }

    $fabricVersionJsonPath = Join-Path $gameDir "versions\fabric-loader-$loaderVersion-$version\fabric-loader-$loaderVersion-$version.json"
    if (-not (Test-Path $fabricVersionJsonPath)) {
        throw "Fabric version JSON missing at $fabricVersionJsonPath."
    }
    $fabricVersionJson = Get-Content -Raw -Path $fabricVersionJsonPath | ConvertFrom-Json
    foreach ($library in $fabricVersionJson.libraries) {
        Add-LibraryJar -Jars $jars -RelativePath (Convert-MavenNameToPath ([string]$library.name))
    }
    $jars += $clientJar
    $classpath = $jars -join ";"
    $remapLog = Join-Path $notesDir "fabric-remap.log"
    $remapStdoutLog = Join-Path $notesDir "fabric-remap.stdout.log"
    $remapStderrLog = Join-Path $notesDir "fabric-remap.stderr.log"
    $emptyModsDir = Join-Path $gameDir ".fabric\empty-mods-$version-$loaderVersion"
    New-Item -ItemType Directory -Force -Path $emptyModsDir | Out-Null
    New-Item -ItemType Directory -Force -Path (Join-Path $gameDir "logs") | Out-Null

    $javaArgs = @(
        "-Dfabric.gameJarPath=$clientJar",
        "-Dfabric.modsFolder=$emptyModsDir",
        "-Djava.library.path=$nativesDir",
        "-Dorg.lwjgl.librarypath=$nativesDir",
        "-Duser.dir=$gameDir",
        "-cp", $classpath,
        "net.fabricmc.loader.impl.launch.knot.KnotClient",
        "--gameDir", $gameDir,
        "--assetsDir", $assetsDir,
        "--assetIndex", $assetIndex,
        "--version", "fabric-loader-$loaderVersion-$version",
        "--username", "DevPlayer",
        "--uuid", "00000000-0000-0000-0000-000000000000",
        "--accessToken", "0",
        "--versionType", "release"
    )

    $javaArgumentLine = ($javaArgs | ForEach-Object { ConvertTo-QuotedProcessArgument ([string]$_) }) -join " "
    Remove-Item -LiteralPath $remapStdoutLog, $remapStderrLog -Force -ErrorAction SilentlyContinue
    $javaProcess = Start-Process `
        -FilePath $javaExe `
        -ArgumentList $javaArgumentLine `
        -WorkingDirectory $gameDir `
        -NoNewWindow `
        -PassThru `
        -RedirectStandardOutput $remapStdoutLog `
        -RedirectStandardError $remapStderrLog

    $fabricExitCode = $null
    $remapReady = $false
    $lastRemappedSize = -1
    $stableChecks = 0
    $deadline = (Get-Date).AddMinutes(10)
    $nextStatus = (Get-Date).AddSeconds(15)

    while (-not $javaProcess.HasExited) {
        if (Test-Path $remappedJar) {
            try {
                $remappedFile = Get-Item -LiteralPath $remappedJar
                if ($remappedFile.Length -gt 0 -and $remappedFile.Length -eq $lastRemappedSize) {
                    $stableChecks++
                } else {
                    $stableChecks = 0
                    $lastRemappedSize = $remappedFile.Length
                }

                if ($stableChecks -ge 2) {
                    $remapReady = $true
                    Write-Host "Fabric remapped client jar is ready -> $remappedJar"
                    break
                }
            } catch {
                $stableChecks = 0
            }
        }

        if ((Get-Date) -ge $deadline) {
            Write-Warning "Fabric remap launch timed out after 10 minutes."
            break
        }

        if ((Get-Date) -ge $nextStatus) {
            Write-Host "Waiting for Fabric to finish generating the remapped client jar..."
            $nextStatus = (Get-Date).AddSeconds(15)
        }

        Start-Sleep -Seconds 2
        $javaProcess.Refresh()
    }

    if ($javaProcess.HasExited) {
        $fabricExitCode = $javaProcess.ExitCode
    } else {
        if ($remapReady) {
            Write-Host "Stopping Fabric remap launcher process after jar generation."
            $fabricExitCode = 0
        } else {
            Write-Warning "Stopping Fabric remap launcher process before jar generation completed."
            $fabricExitCode = 1
        }

        Stop-Process -Id $javaProcess.Id -Force -ErrorAction SilentlyContinue
        $javaProcess.WaitForExit(10000) | Out-Null
    }

    $remapOutput = @()
    if (Test-Path $remapStdoutLog) {
        $remapOutput += @(Get-Content -Path $remapStdoutLog)
    }
    if (Test-Path $remapStderrLog) {
        $remapOutput += @(Get-Content -Path $remapStderrLog)
    }
    if ($remapOutput.Count -gt 0) {
        $remapOutput | Set-Content -Path $remapLog
        $remapOutput | ForEach-Object { Write-Host $_ }
    }

    if (-not (Test-Path $remappedJar)) {
        throw "Fabric remapped client jar was not created. See $remapLog."
    }
    if ($fabricExitCode -ne 0) {
        Write-Warning "Fabric launch exited with code $fabricExitCode after creating the remapped jar."
    }
}

Write-Host "CI cache is ready."
