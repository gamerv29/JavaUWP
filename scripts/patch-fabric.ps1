param(
    [string]$LoaderVersion
)

# patch-fabric.ps1 - Patch fabric-loader to fix Xbox toRealPath() issue
$ErrorActionPreference = "Stop"

. (Join-Path $PSScriptRoot "common.ps1")

$root   = Resolve-RepoRoot
$java   = Resolve-JavaHome
$gameDir = Get-ConfigPath "GameDir"
$buildDir = Get-ConfigPath "BuildDir"
$loaderVersion = if ($LoaderVersion) { $LoaderVersion } else { $ProjectConfig.FabricLoaderVersion }
$loader = Join-Path $gameDir "libraries\net\fabricmc\fabric-loader\$loaderVersion\fabric-loader-$loaderVersion.jar"
$patch  = Join-Path $root "patch"
$tmp    = Join-Path $buildDir "patch\$loaderVersion"
$classesTmp = Join-Path $tmp "classes"
$jarTmp = Join-Path $tmp "jar"
$patchedLoader = Join-Path $tmp "fabric-loader-$loaderVersion-patched.jar"

Remove-Item -Recurse -Force $tmp -ErrorAction SilentlyContinue
New-Item -ItemType Directory -Force $classesTmp | Out-Null
New-Item -ItemType Directory -Force $jarTmp | Out-Null

if (-not (Test-Path $loader)) {
    throw "Fabric loader jar not found: $loader"
}

# Compile the patched classes against the original JAR.
Write-Host "Compiling patched Fabric loader classes..."
$jarExe = Join-Path $java "bin\jar.exe"
$patchSources = @(
    (Join-Path $patch "LoaderUtil.java"),
    (Join-Path $patch "FileSystemUtil.java"),
    (Join-Path $patch "FabricLauncherBase.java")
)
$hasTinyRemapperOutputConsumer = & $jarExe tf $loader |
    Select-String -SimpleMatch "net/fabricmc/loader/impl/lib/tinyremapper/OutputConsumerPath.class" -Quiet
if ($hasTinyRemapperOutputConsumer) {
    $patchSources += @(
        (Join-Path $patch "FileSystemReference.java"),
        (Join-Path $patch "OutputConsumerPath.java")
    )
} else {
    Write-Host "TinyRemapper OutputConsumerPath is not bundled in fabric-loader-$loaderVersion; skipping that patch."
}

& (Join-Path $java "bin\javac.exe") --release 21 -cp $loader -d $classesTmp $patchSources
if ($LASTEXITCODE -ne 0) { throw "Compile failed" }

# Repack a fresh JAR instead of updating in place. Repeated ZipArchive updates
# can leave headers that jar.exe tolerates but .NET refuses to open later.
Write-Host "Extracting Fabric loader JAR..."
Push-Location $jarTmp
& $jarExe xf $loader
if ($LASTEXITCODE -ne 0) { throw "JAR extract failed" }
Pop-Location

Write-Host "Overlaying patched classes..."
$classFiles = Get-ChildItem -LiteralPath $classesTmp -Recurse -Filter "*.class"
foreach ($classFile in $classFiles) {
    $relativePath = $classFile.FullName.Substring($classesTmp.Length).TrimStart('\', '/')
    $dst = Join-Path $jarTmp $relativePath
    New-Item -ItemType Directory -Force -Path (Split-Path $dst -Parent) | Out-Null
    Copy-Item -LiteralPath $classFile.FullName -Destination $dst -Force
    Write-Host "  injected $($relativePath.Replace('\', '/'))"
}

Write-Host "Stripping JAR signature..."
$metaInf = Join-Path $jarTmp "META-INF"
if (Test-Path $metaInf) {
    Get-ChildItem -LiteralPath $metaInf -File |
        Where-Object { $_.Name -match '\.(SF|RSA|DSA|EC)$' } |
        ForEach-Object {
            Write-Host "  removing META-INF/$($_.Name)"
            Remove-Item -LiteralPath $_.FullName -Force
        }
}

$manifest = Join-Path $jarTmp "META-INF\MANIFEST.MF"
$manifestCopy = Join-Path $tmp "MANIFEST.MF"
if (Test-Path $manifest) {
    Copy-Item -LiteralPath $manifest -Destination $manifestCopy -Force
    Remove-Item -LiteralPath $manifest -Force
}

Write-Host "Repacking patched Fabric loader JAR..."
if (Test-Path $manifestCopy) {
    & $jarExe cfm $patchedLoader $manifestCopy -C $jarTmp .
} else {
    & $jarExe cf $patchedLoader -C $jarTmp .
}
if ($LASTEXITCODE -ne 0) { throw "JAR repack failed" }
Move-Item -LiteralPath $patchedLoader -Destination $loader -Force

Write-Host "Done - fabric-loader-$loaderVersion.jar patched"
Write-Host "Classes injected from compiled patch output: $($classFiles.Count)"
