# patch-fabric.ps1 - Patch fabric-loader to fix Xbox toRealPath() issue
$ErrorActionPreference = "Stop"

. (Join-Path $PSScriptRoot "common.ps1")

$root   = Resolve-RepoRoot
$java   = Resolve-JavaHome
$gameDir = Get-ConfigPath "GameDir"
$buildDir = Get-ConfigPath "BuildDir"
$loaderVersion = $ProjectConfig.FabricLoaderVersion
$loader = Join-Path $gameDir "libraries\net\fabricmc\fabric-loader\$loaderVersion\fabric-loader-$loaderVersion.jar"
$patch  = Join-Path $root "patch"
$tmp    = Join-Path $buildDir "patch"
$classesTmp = Join-Path $tmp "classes"
$jarTmp = Join-Path $tmp "jar"
$patchedLoader = Join-Path $tmp "fabric-loader-$loaderVersion-patched.jar"

Remove-Item -Recurse -Force $tmp -ErrorAction SilentlyContinue
New-Item -ItemType Directory -Force $classesTmp | Out-Null
New-Item -ItemType Directory -Force $jarTmp | Out-Null

# Compile the patched classes against the original JAR.
Write-Host "Compiling patched Fabric loader classes..."
& (Join-Path $java "bin\javac.exe") -cp $loader -d $classesTmp @(
    (Join-Path $patch "LoaderUtil.java"),
    (Join-Path $patch "FileSystemUtil.java"),
    (Join-Path $patch "FileSystemReference.java"),
    (Join-Path $patch "OutputConsumerPath.java")
)
if ($LASTEXITCODE -ne 0) { throw "Compile failed" }

# Repack a fresh JAR instead of updating in place. Repeated ZipArchive updates
# can leave headers that jar.exe tolerates but .NET refuses to open later.
Write-Host "Extracting Fabric loader JAR..."
Push-Location $jarTmp
& (Join-Path $java "bin\jar.exe") xf $loader
if ($LASTEXITCODE -ne 0) { throw "JAR extract failed" }
Pop-Location

Write-Host "Overlaying patched classes..."
$classFiles = @(
    "net\fabricmc\loader\impl\util\LoaderUtil.class",
    "net\fabricmc\loader\impl\util\FileSystemUtil.class",
    "net\fabricmc\loader\impl\util\FileSystemUtil`$FileSystemDelegate.class",
    "net\fabricmc\loader\impl\lib\tinyremapper\FileSystemReference.class",
    "net\fabricmc\loader\impl\lib\tinyremapper\OutputConsumerPath.class",
    "net\fabricmc\loader\impl\lib\tinyremapper\OutputConsumerPath`$Builder.class",
    "net\fabricmc\loader\impl\lib\tinyremapper\OutputConsumerPath`$ResourceRemapper.class"
)
foreach ($classFile in $classFiles) {
    $src = Join-Path $classesTmp $classFile
    $dst = Join-Path $jarTmp $classFile
    New-Item -ItemType Directory -Force -Path (Split-Path $dst -Parent) | Out-Null
    Copy-Item -LiteralPath $src -Destination $dst -Force
    Write-Host "  injected $($classFile.Replace('\', '/'))"
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
    & (Join-Path $java "bin\jar.exe") cfm $patchedLoader $manifestCopy -C $jarTmp .
} else {
    & (Join-Path $java "bin\jar.exe") cf $patchedLoader -C $jarTmp .
}
if ($LASTEXITCODE -ne 0) { throw "JAR repack failed" }
Move-Item -LiteralPath $patchedLoader -Destination $loader -Force

Write-Host "Done - fabric-loader-$loaderVersion.jar patched"
Write-Host "Classes injected: LoaderUtil, FileSystemUtil, TinyRemapper FileSystemReference, OutputConsumerPath"
