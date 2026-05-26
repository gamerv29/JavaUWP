package net.fabricmc.loader.impl.lib.tinyremapper;

import java.io.Closeable;
import java.io.IOException;
import java.lang.reflect.Field;
import java.net.URI;
import java.nio.file.AccessDeniedException;
import java.nio.file.FileSystem;
import java.nio.file.FileSystemAlreadyExistsException;
import java.nio.file.FileSystems;
import java.nio.file.Path;
import java.nio.file.Paths;
import java.util.Collections;
import java.util.IdentityHashMap;
import java.util.Map;
import java.util.Set;

/**
 * Patched TinyRemapper FileSystemReference for Xbox UWP.
 *
 * The upstream implementation opens jar files through FileSystems.newFileSystem(URI).
 * On Xbox that route calls Path.toRealPath() inside ZipFileSystemProvider and fails
 * when Fabric creates remap output jars under LocalState. The Path overload avoids
 * that blocked call. Xbox can also report freshly-created LocalState jars as not
 * writable, causing ZipFS to mark them read-only, so new output jars are forced
 * writable after creation. ZipFS close also calls Path.toRealPath while removing
 * itself from the provider registry; when using the Path overload there is no
 * provider registry entry to remove, so that Xbox-only cleanup failure can be
 * safely ignored after ZipFS has synced its contents.
 */
public final class FileSystemReference implements Closeable {
    private static final Map<FileSystem, Set<FileSystemReference>> openFsMap = new IdentityHashMap<>();

    private final FileSystem fileSystem;
    private volatile boolean closed;

    public static FileSystemReference openJar(Path path) throws IOException {
        return openJar(path, false);
    }

    public static FileSystemReference openJar(Path path, boolean create) throws IOException {
        return open(path.toAbsolutePath().normalize(), create);
    }

    public static FileSystemReference open(URI uri, boolean create) throws IOException {
        String raw = uri.getRawSchemeSpecificPart();
        if ("jar".equalsIgnoreCase(uri.getScheme()) && raw != null) {
            int sep = raw.indexOf("!/");
            if (sep >= 0) {
                raw = raw.substring(0, sep);
            }
            return open(Paths.get(URI.create(raw)).toAbsolutePath().normalize(), create);
        }

        return open(Paths.get(uri).toAbsolutePath().normalize(), create);
    }

    private static FileSystemReference open(Path path, boolean create) throws IOException {
        synchronized (openFsMap) {
            boolean opened = false;
            FileSystem fs;
            try {
                fs = FileSystems.newFileSystem(path, create
                    ? Collections.singletonMap("create", "true")
                    : Collections.emptyMap());
                opened = true;
                if (create) {
                    forceWritable(fs, path);
                }
            } catch (FileSystemAlreadyExistsException ignored) {
                fs = FileSystems.getFileSystem(URI.create("jar:" + path.toUri()));
            }

            FileSystemReference ref = new FileSystemReference(fs);
            Set<FileSystemReference> refs = openFsMap.get(fs);
            if (refs == null) {
                refs = Collections.newSetFromMap(new IdentityHashMap<>());
                openFsMap.put(fs, refs);
                if (!opened) {
                    refs.add(null);
                }
            } else if (opened) {
                throw new IllegalStateException("opened but already in refs?");
            }

            refs.add(ref);
            return ref;
        }
    }

    private static void forceWritable(FileSystem fs, Path path) throws IOException {
        if (!fs.isReadOnly()) {
            return;
        }

        try {
            Field readOnly = fs.getClass().getDeclaredField("readOnly");
            readOnly.setAccessible(true);
            readOnly.setBoolean(fs, false);
        } catch (ReflectiveOperationException | RuntimeException ex) {
            throw new IOException("created ZipFS for " + path + " was marked read-only", ex);
        }

        if (fs.isReadOnly()) {
            throw new IOException("created ZipFS for " + path + " is still read-only");
        }
    }

    private FileSystemReference(FileSystem fileSystem) {
        this.fileSystem = fileSystem;
    }

    public boolean isReadOnly() {
        if (closed) {
            throw new IllegalStateException("fs closed");
        }
        return fileSystem.isReadOnly();
    }

    public Path getPath(String first, String... more) {
        if (closed) {
            throw new IllegalStateException("fs closed");
        }
        return fileSystem.getPath(first, more);
    }

    @Override
    public void close() throws IOException {
        synchronized (openFsMap) {
            if (closed) {
                return;
            }
            closed = true;

            Set<FileSystemReference> refs = openFsMap.get(fileSystem);
            if (refs == null || !refs.remove(this)) {
                throw new IllegalStateException("fs " + fileSystem + " was already closed");
            }

            if (refs.isEmpty()) {
                openFsMap.remove(fileSystem);
                try {
                    fileSystem.close();
                } catch (AccessDeniedException ex) {
                    if (!isZipFsRemoveRealPathFailure(ex)) {
                        throw ex;
                    }
                }
            } else if (refs.size() == 1 && refs.contains(null)) {
                openFsMap.remove(fileSystem);
            }
        }
    }

    static boolean isZipFsRemoveRealPathFailure(AccessDeniedException ex) {
        for (StackTraceElement frame : ex.getStackTrace()) {
            if ("jdk.nio.zipfs.ZipFileSystemProvider".equals(frame.getClassName())
                && (frame.getMethodName().equals("removeFileSystem")
                    || frame.getMethodName().startsWith("lambda$removeFileSystem$"))) {
                return true;
            }
        }

        return false;
    }

    @Override
    public String toString() {
        synchronized (openFsMap) {
            Set<FileSystemReference> refs = openFsMap.getOrDefault(fileSystem, Collections.emptySet());
            return String.format("%s=%dx,%s", fileSystem, refs.size(), refs.contains(null) ? "existing" : "new");
        }
    }
}
