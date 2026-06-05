package cpw.mods.jarhandling.impl;

import cpw.mods.jarhandling.JarContents;
import cpw.mods.jarhandling.SecureJar;
import cpw.mods.niofs.union.UnionFileSystem;
import cpw.mods.niofs.union.UnionFileSystemProvider;
import cpw.mods.niofs.union.UnionPathFilter;

import java.io.IOException;
import java.io.UncheckedIOException;
import java.net.URI;
import java.nio.file.FileVisitResult;
import java.nio.file.Files;
import java.nio.file.Path;
import java.nio.file.SimpleFileVisitor;
import java.nio.file.attribute.BasicFileAttributes;
import java.nio.file.spi.FileSystemProvider;
import java.util.Arrays;
import java.util.HashMap;
import java.util.HashSet;
import java.util.List;
import java.util.Map;
import java.util.Optional;
import java.util.Set;
import java.util.function.Supplier;
import java.util.jar.JarFile;
import java.util.jar.JarInputStream;
import java.util.jar.Manifest;

public class JarContentsImpl implements JarContents {
    private static final UnionFileSystemProvider UFSP = (UnionFileSystemProvider) FileSystemProvider.installedProviders()
            .stream()
            .filter(fsp -> fsp.getScheme().equals("union"))
            .findFirst()
            .orElseThrow(() -> new IllegalStateException("Couldn't find UnionFileSystemProvider"));
    private static final Set<String> NAUGHTY_SERVICE_FILES = Set.of("org.codehaus.groovy.runtime.ExtensionModule");

    final UnionFileSystem filesystem;
    final JarSigningData signingData = new JarSigningData();
    private final Manifest manifest;
    private final Map<Path, Integer> nameOverrides;

    private Set<String> packages;
    private List<SecureJar.Provider> providers;

    public JarContentsImpl(Path[] paths, Supplier<Manifest> defaultManifest, UnionPathFilter pathFilter) {
        var validPaths = Arrays.stream(paths).filter(Files::exists).toArray(Path[]::new);
        if (validPaths.length == 0) {
            throw new UncheckedIOException(new IOException("Invalid paths argument, contained no existing paths: " + Arrays.toString(paths)));
        }
        this.filesystem = UFSP.newFileSystem(pathFilter, validPaths);
        this.manifest = readManifestAndSigningData(defaultManifest, validPaths);
        this.nameOverrides = readMultiReleaseInfo();
    }

    private Manifest readManifestAndSigningData(Supplier<Manifest> defaultManifest, Path[] validPaths) {
        try {
            for (int x = validPaths.length - 1; x >= 0; x--) {
                var path = validPaths[x];
                if (Files.isDirectory(path)) {
                    var manfile = path.resolve(JarFile.MANIFEST_NAME);
                    if (Files.exists(manfile)) {
                        try (var is = Files.newInputStream(manfile)) {
                            return new Manifest(is);
                        }
                    }
                } else {
                    try (var jis = new JarInputStream(Files.newInputStream(path))) {
                        signingData.readJarSigningData(jis);

                        if (jis.getManifest() != null) {
                            return new Manifest(jis.getManifest());
                        }
                    }
                }
            }
        } catch (IOException e) {
            throw new UncheckedIOException(e);
        }
        return defaultManifest.get();
    }

    private Map<Path, Integer> readMultiReleaseInfo() {
        boolean isMultiRelease = Boolean.parseBoolean(getManifest().getMainAttributes().getValue("Multi-Release"));
        if (!isMultiRelease) {
            return Map.of();
        }

        var vers = filesystem.getRoot().resolve("META-INF/versions");
        if (!Files.isDirectory(vers)) {
            return Map.of();
        }

        try (var walk = Files.walk(vers)) {
            Map<Path, Integer> pathToJavaVersion = new HashMap<>();
            walk
                    .filter(p -> !Files.isDirectory(p))
                    .forEach(p -> {
                        int javaVersion = Integer.parseInt(p.getName(2).toString());
                        Path remainder = p.subpath(3, p.getNameCount());
                        if (javaVersion <= Runtime.version().feature()) {
                            pathToJavaVersion.merge(remainder, javaVersion, Integer::max);
                        }
                    });
            return pathToJavaVersion;
        } catch (IOException ioe) {
            throw new UncheckedIOException(ioe);
        }
    }

    @Override
    public Path getPrimaryPath() {
        return filesystem.getPrimaryPath();
    }

    @Override
    public Optional<URI> findFile(String name) {
        var rel = filesystem.getPath(name);
        if (this.nameOverrides.containsKey(rel)) {
            rel = this.filesystem.getPath("META-INF", "versions", this.nameOverrides.get(rel).toString()).resolve(rel);
        }
        var unionPath = this.filesystem.getRoot().resolve(rel);
        if (Files.exists(unionPath)) {
            return Optional.of(unionPath.toUri());
        }

        return findBackingFileUri(name);
    }

    @Override
    public Manifest getManifest() {
        return manifest;
    }

    @Override
    public Set<String> getPackagesExcluding(String... excludedRootPackages) {
        Set<String> ignoredRootPackages = new HashSet<>(excludedRootPackages.length + 1);
        ignoredRootPackages.add("META-INF");
        ignoredRootPackages.addAll(List.of(excludedRootPackages));

        Set<String> packages = new HashSet<>();
        final Path root = this.filesystem.getRoot();
        try {
            Files.walkFileTree(root, new SimpleFileVisitor<>() {
                @Override
                public FileVisitResult visitFile(Path file, BasicFileAttributes attrs) {
                    if (file.getFileName().toString().endsWith(".class")) {
                        var pkg = packageNameFor(root, file);
                        if (!pkg.isEmpty()) {
                            packages.add(pkg);
                        }
                    }
                    return FileVisitResult.CONTINUE;
                }

                @Override
                public FileVisitResult preVisitDirectory(Path path, BasicFileAttributes attrs) {
                    if (path.getNameCount() > 0 && ignoredRootPackages.contains(path.getName(0).toString())) {
                        return FileVisitResult.SKIP_SUBTREE;
                    }
                    return FileVisitResult.CONTINUE;
                }
            });
            addPackagesFromBackingJars(packages, ignoredRootPackages);
            logPackageScan(root, packages);
            return Set.copyOf(packages);
        } catch (IOException e) {
            throw new UncheckedIOException(e);
        }
    }

    private void logPackageScan(Path root, Set<String> packages) {
        if (!Boolean.getBoolean("banditvault.securejarhandler.debug")) {
            return;
        }

        System.err.println("[banditvault] JarContentsImpl UWP package scan primary=" + getPrimaryPath()
                + " root=" + root
                + " packages=" + packages.size()
                + " net.minecraft.core=" + packages.contains("net.minecraft.core")
                + " net.minecraft.core.registries=" + packages.contains("net.minecraft.core.registries"));
        for (Path path : getBackingPaths()) {
            System.err.println("[banditvault] JarContentsImpl backing path=" + path);
        }
    }

    private static String packageNameFor(Path root, Path file) {
        Path parent = file.getParent();
        if (parent == null) {
            return "";
        }

        String pathText;
        try {
            pathText = root.relativize(parent).toString();
        } catch (IllegalArgumentException ex) {
            pathText = parent.toString();
        }

        pathText = pathText.replace('\\', '/');
        while (pathText.startsWith("/")) {
            pathText = pathText.substring(1);
        }
        if (pathText.isEmpty() || ".".equals(pathText)) {
            return "";
        }
        return pathText.replace('/', '.');
    }

    private void addPackagesFromBackingJars(Set<String> packages, Set<String> ignoredRootPackages) {
        for (Path basePath : getBackingPaths()) {
            if (Files.isDirectory(basePath)) {
                addPackagesFromDirectory(packages, ignoredRootPackages, basePath);
            } else {
                addPackagesFromJar(packages, ignoredRootPackages, basePath);
            }
        }
    }

    @SuppressWarnings("unchecked")
    public List<Path> getBackingPaths() {
        try {
            var method = UnionFileSystem.class.getDeclaredMethod("getBasePaths");
            method.setAccessible(true);
            return (List<Path>) method.invoke(this.filesystem);
        } catch (ReflectiveOperationException | RuntimeException ex) {
            return List.of(this.filesystem.getPrimaryPath());
        }
    }

    public byte[] readBackingFileBytes(String name) {
        for (Path basePath : getBackingPaths()) {
            try {
                if (Files.isDirectory(basePath)) {
                    Path file = basePath.resolve(name.replace('/', basePath.getFileSystem().getSeparator().charAt(0)));
                    if (Files.exists(file)) {
                        return Files.readAllBytes(file);
                    }
                } else {
                    try (var jar = new JarFile(basePath.toFile())) {
                        var entry = jar.getJarEntry(name);
                        if (entry != null && !entry.isDirectory()) {
                            try (var in = jar.getInputStream(entry)) {
                                return in.readAllBytes();
                            }
                        }
                    }
                }
            } catch (IOException ignored) {
            }
        }
        return new byte[0];
    }

    private Optional<URI> findBackingFileUri(String name) {
        for (Path basePath : getBackingPaths()) {
            try {
                if (Files.isDirectory(basePath)) {
                    Path file = basePath.resolve(name.replace('/', basePath.getFileSystem().getSeparator().charAt(0)));
                    if (Files.exists(file)) {
                        return Optional.of(file.toUri());
                    }
                } else {
                    try (var jar = new JarFile(basePath.toFile())) {
                        var entry = jar.getJarEntry(name);
                        if (entry != null && !entry.isDirectory()) {
                            if (Boolean.getBoolean("banditvault.securejarhandler.debug")
                                    && (name.endsWith("mods.toml") || name.startsWith("META-INF/services/"))) {
                                System.err.println("[banditvault] JarContentsImpl UWP backing resource "
                                        + name + " -> " + basePath);
                            }
                            return Optional.of(URI.create("jar:" + basePath.toUri() + "!/" + name));
                        }
                    }
                }
            } catch (IOException | RuntimeException ignored) {
            }
        }
        return Optional.empty();
    }

    private static void addPackagesFromJar(Set<String> packages, Set<String> ignoredRootPackages, Path jarPath) {
        try (var jar = new JarFile(jarPath.toFile())) {
            var entries = jar.entries();
            while (entries.hasMoreElements()) {
                var entry = entries.nextElement();
                if (entry.isDirectory()) {
                    continue;
                }
                addPackageFromEntryName(packages, ignoredRootPackages, entry.getName());
            }
        } catch (IOException ignored) {
        }
    }

    private static void addPackagesFromDirectory(Set<String> packages, Set<String> ignoredRootPackages, Path directory) {
        try (var walk = Files.walk(directory)) {
            walk
                    .filter(path -> !Files.isDirectory(path))
                    .forEach(path -> addPackageFromEntryName(packages, ignoredRootPackages,
                            directory.relativize(path).toString().replace('\\', '/')));
        } catch (IOException ignored) {
        }
    }

    private static void addPackageFromEntryName(Set<String> packages, Set<String> ignoredRootPackages, String name) {
        if (!name.endsWith(".class")) {
            return;
        }

        while (name.startsWith("/")) {
            name = name.substring(1);
        }

        int slash = name.indexOf('/');
        if (slash < 0) {
            return;
        }
        if (ignoredRootPackages.contains(name.substring(0, slash))) {
            return;
        }

        int lastSlash = name.lastIndexOf('/');
        if (lastSlash <= 0) {
            return;
        }
        packages.add(name.substring(0, lastSlash).replace('/', '.'));
    }

    @Override
    public Set<String> getPackages() {
        if (this.packages == null) {
            this.packages = getPackagesExcluding();
        }
        return this.packages;
    }

    @Override
    public List<SecureJar.Provider> getMetaInfServices() {
        if (this.providers == null) {
            final var services = this.filesystem.getRoot().resolve("META-INF/services/");
            if (Files.exists(services)) {
                try (var walk = Files.walk(services, 1)) {
                    this.providers = walk.filter(path -> !Files.isDirectory(path))
                            .filter(path -> !NAUGHTY_SERVICE_FILES.contains(path.getFileName().toString()))
                            .map((Path path1) -> SecureJar.Provider.fromPath(path1, filesystem.getFilesystemFilter()))
                            .toList();
                } catch (IOException e) {
                    throw new UncheckedIOException(e);
                }
            } else {
                this.providers = List.of();
            }
        }
        return this.providers;
    }

    @Override
    public void close() throws IOException {
        filesystem.close();
    }
}
