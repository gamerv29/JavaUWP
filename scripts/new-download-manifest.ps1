param(
    [string]$MinecraftVersion,
    [string]$FabricLoaderVersion,
    [string]$OutputPath
)

$ErrorActionPreference = "Stop"

. (Join-Path $PSScriptRoot "common.ps1")

if (-not $MinecraftVersion) {
    $MinecraftVersion = $ProjectConfig.MinecraftVersion
}
if (-not $FabricLoaderVersion) {
    $FabricLoaderVersion = $ProjectConfig.FabricLoaderVersion
}
if (-not $OutputPath) {
    $OutputPath = Join-Path (Get-ConfigPath "PackageContentDir") "download_manifest.tsv"
}

function Get-Json([string]$Url) {
    Write-Host "Fetch $Url"
    return Invoke-RestMethod -UseBasicParsing -Uri $Url -TimeoutSec 60
}

function Convert-MavenNameToPath([string]$Name) {
    $parts = $Name.Split(":")
    if ($parts.Length -lt 3) {
        throw "Unsupported Maven coordinate: $Name"
    }

    $group = $parts[0].Replace(".", "/")
    $artifact = $parts[1]
    $version = $parts[2]
    $classifier = if ($parts.Length -ge 4) { "-$($parts[3])" } else { "" }
    return "$group/$artifact/$version/$artifact-$version$classifier.jar"
}

function Get-RemoteTextOrEmpty([string]$Url) {
    try {
        $content = (Invoke-WebRequest -UseBasicParsing -Uri $Url -TimeoutSec 30).Content
        if ($content -is [byte[]]) {
            return [System.Text.Encoding]::ASCII.GetString($content).Trim()
        }

        return ([string]$content).Trim()
    } catch {
        return ""
    }
}

function Get-RemoteSizeOrZero([string]$Url) {
    try {
        $response = Invoke-WebRequest -UseBasicParsing -Method Head -Uri $Url -TimeoutSec 30
        $length = $response.Headers["Content-Length"]
        if ($length) {
            return [UInt64]$length
        }
    } catch {
    }

    return [UInt64]0
}

function Add-Entry(
    [System.Collections.Generic.List[object]]$Entries,
    [string]$Path,
    [string]$Sha1,
    [UInt64]$Size,
    [string]$Url) {
    if (-not $Path -or -not $Url) {
        return
    }

    $Entries.Add([pscustomobject]@{
        Path = $Path.Replace("\", "/")
        Sha1 = if ($Sha1) { $Sha1.Trim().ToLowerInvariant() } else { "" }
        Size = $Size
        Url = $Url
    })
}

function Test-LibraryAllowed($Library) {
    if (-not $Library.rules) {
        return $true
    }

    $allowed = $false
    foreach ($rule in $Library.rules) {
        $applies = $true
        if ($rule.os) {
            if ($rule.os.name -and $rule.os.name -ne "windows") {
                $applies = $false
            }
            if ($rule.os.arch -and $rule.os.arch -notin @("x64", "amd64")) {
                $applies = $false
            }
        }

        if ($applies) {
            $allowed = $rule.action -eq "allow"
        }
    }

    return $allowed
}

function Add-MinecraftLibraries($VersionJson, [System.Collections.Generic.List[object]]$Entries) {
    foreach ($library in $VersionJson.libraries) {
        if (-not (Test-LibraryAllowed $library)) {
            continue
        }

        if ($library.downloads.artifact) {
            $artifact = $library.downloads.artifact
            Add-Entry $Entries "game/libraries/$($artifact.path)" $artifact.sha1 ([UInt64]$artifact.size) $artifact.url
        }

        if ($library.natives -and $library.natives.windows -and $library.downloads.classifiers) {
            $classifier = $library.natives.windows.Replace('${arch}', '64')
            $native = $library.downloads.classifiers.$classifier
            if ($native) {
                Add-Entry $Entries "game/libraries/$($native.path)" $native.sha1 ([UInt64]$native.size) $native.url
            }
        }
    }
}

function Add-FabricLibraries($FabricProfile, [System.Collections.Generic.List[object]]$Entries) {
    foreach ($library in $FabricProfile.libraries) {
        if ($library.name -like "net.fabricmc:fabric-loader:*") {
            continue
        }

        $path = Convert-MavenNameToPath $library.name
        $baseUrl = if ($library.url) { $library.url } else { "https://maven.fabricmc.net/" }
        if (-not $baseUrl.EndsWith("/")) {
            $baseUrl += "/"
        }

        $url = "$baseUrl$path"
        $sha1 = if ($library.sha1) { $library.sha1 } else { Get-RemoteTextOrEmpty "$url.sha1" }
        $size = if ($library.size) { [UInt64]$library.size } else { Get-RemoteSizeOrZero $url }
        Add-Entry $Entries "game/libraries/$path" $sha1 $size $url
    }
}

function Add-Assets($VersionJson, [System.Collections.Generic.List[object]]$Entries) {
    $assetIndex = $VersionJson.assetIndex
    Add-Entry $Entries "assets/indexes/$($assetIndex.id).json" $assetIndex.sha1 ([UInt64]$assetIndex.size) $assetIndex.url

    $assetJson = Get-Json $assetIndex.url
    foreach ($property in $assetJson.objects.PSObject.Properties) {
        $hash = [string]$property.Value.hash
        $size = if ($property.Value.size) { [UInt64]$property.Value.size } else { [UInt64]0 }
        $prefix = $hash.Substring(0, 2)
        Add-Entry $Entries "assets/objects/$prefix/$hash" $hash $size "https://resources.download.minecraft.net/$prefix/$hash"
    }
}

$manifest = Get-Json "https://piston-meta.mojang.com/mc/game/version_manifest_v2.json"
$version = $manifest.versions | Where-Object { $_.id -eq $MinecraftVersion } | Select-Object -First 1
if (-not $version) {
    throw "Minecraft version '$MinecraftVersion' was not found in the official version manifest."
}

$versionJson = Get-Json $version.url
$fabricProfile = Get-Json "https://meta.fabricmc.net/v2/versions/loader/$MinecraftVersion/$FabricLoaderVersion/profile/json"

$entries = [System.Collections.Generic.List[object]]::new()
Add-Entry $entries "game/versions/$MinecraftVersion/$MinecraftVersion.json" $version.sha1 ([UInt64]0) $version.url
Add-Entry $entries "game/versions/$MinecraftVersion/$MinecraftVersion.jar" $versionJson.downloads.client.sha1 ([UInt64]$versionJson.downloads.client.size) $versionJson.downloads.client.url
Add-MinecraftLibraries $versionJson $entries
Add-FabricLibraries $fabricProfile $entries
Add-Assets $versionJson $entries

$deduped = $entries |
    Group-Object Path |
    ForEach-Object { $_.Group | Select-Object -First 1 } |
    Sort-Object Path

$weakEntries = @($deduped | Where-Object { -not $_.Sha1 })
if ($weakEntries.Count -gt 0) {
    Write-Warning "$($weakEntries.Count) manifest entries do not have SHA1 metadata and will be existence-checked only."
}

New-Item -ItemType Directory -Force -Path (Split-Path $OutputPath -Parent) | Out-Null
$lines = [System.Collections.Generic.List[string]]::new()
$lines.Add("# MinecraftJavaUWP official download manifest")
$lines.Add("# minecraftVersion`t$MinecraftVersion")
$lines.Add("# fabricLoaderVersion`t$FabricLoaderVersion")
$lines.Add("# path`tsha1`tsize`turl")
foreach ($entry in $deduped) {
    $lines.Add("$($entry.Path)`t$($entry.Sha1)`t$($entry.Size)`t$($entry.Url)")
}

[System.IO.File]::WriteAllLines($OutputPath, $lines, [System.Text.UTF8Encoding]::new($false))
Write-Host "Wrote $($deduped.Count) download entries to $OutputPath"
