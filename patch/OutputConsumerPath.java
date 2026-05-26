package net.fabricmc.loader.impl.lib.tinyremapper;

import java.io.BufferedInputStream;
import java.io.Closeable;
import java.io.FileNotFoundException;
import java.io.IOException;
import java.io.InputStream;
import java.io.UncheckedIOException;
import java.nio.file.AccessDeniedException;
import java.nio.file.CopyOption;
import java.nio.file.FileAlreadyExistsException;
import java.nio.file.FileVisitResult;
import java.nio.file.Files;
import java.nio.file.LinkOption;
import java.nio.file.OpenOption;
import java.nio.file.Path;
import java.nio.file.SimpleFileVisitor;
import java.nio.file.StandardCopyOption;
import java.nio.file.attribute.BasicFileAttributes;
import java.util.List;
import java.util.Locale;
import java.util.concurrent.locks.Lock;
import java.util.concurrent.locks.ReentrantLock;
import java.util.function.BiConsumer;
import java.util.function.Predicate;

/**
 * Patched TinyRemapper OutputConsumerPath for Xbox UWP.
 *
 * The upstream class closes ZipFS instances directly when copying non-class
 * files out of source jars. Xbox blocks the ZipFS provider's close-time
 * toRealPath cleanup, so source jars must also go through FileSystemReference.
 */
public class OutputConsumerPath implements Closeable, BiConsumer<String, byte[]> {
    private final Path dstDir;
    private final FileSystemReference fsToClose;
    private final boolean isJarFs;
    private final Lock lock;
    private final Predicate<String> classNameFilter;
    private boolean closed;

    private OutputConsumerPath(Path destination, boolean archive, boolean threadSyncWrites,
            Predicate<String> classNameFilter) throws IOException {
        if (!archive) {
            Files.createDirectories(destination);
            this.fsToClose = null;
        } else {
            createParentDirs(destination);
            this.fsToClose = FileSystemReference.openJar(destination, true);

            if (this.fsToClose.isReadOnly()) {
                throw new IOException("the jar file " + destination + " can't be written");
            }

            destination = this.fsToClose.getPath("/");
        }

        this.dstDir = destination;
        this.isJarFs = archive;
        this.lock = threadSyncWrites ? new ReentrantLock() : null;
        this.classNameFilter = classNameFilter;
    }

    public void addNonClassFiles(Path src, NonClassCopyMode copyMode, TinyRemapper remapper) throws IOException {
        addNonClassFiles(src, remapper, copyMode.remappers);
    }

    public void addNonClassFiles(Path src, TinyRemapper remapper, List<ResourceRemapper> resourceRemappers)
            throws IOException {
        if (Files.isDirectory(src, new LinkOption[0])) {
            addNonClassFiles(src, remapper, false, resourceRemappers);
        } else if (Files.exists(src, new LinkOption[0])) {
            if (!src.getFileName().toString().endsWith(".class")) {
                try (FileSystemReference srcFs = FileSystemReference.openJar(src, false)) {
                    addNonClassFiles(srcFs.getPath("/"), remapper, false, resourceRemappers);
                }
            }
        } else {
            throw new FileNotFoundException("file " + src + " doesn't exist");
        }
    }

    public void addNonClassFiles(Path srcDir, TinyRemapper remapper, boolean closeFs,
            List<ResourceRemapper> resourceRemappers) throws IOException {
        if (lock != null) {
            lock.lock();
        }

        IOException pending = null;
        try {
            if (closed) {
                throw new IllegalStateException("consumer already closed");
            }

            Files.walkFileTree(srcDir, new SimpleFileVisitor<Path>() {
                @Override
                public FileVisitResult visitFile(Path file, BasicFileAttributes attrs) throws IOException {
                    if (file.getFileName().toString().endsWith(".class")) {
                        return FileVisitResult.CONTINUE;
                    }

                    Path relative = srcDir.relativize(file);
                    Path dst = dstDir.resolve(relative.toString());

                    for (ResourceRemapper resourceRemapper : resourceRemappers) {
                        if (resourceRemapper.canTransform(remapper, relative)) {
                            try (InputStream in = new BufferedInputStream(Files.newInputStream(file))) {
                                resourceRemapper.transform(dstDir, relative, in, remapper);
                            }

                            return FileVisitResult.CONTINUE;
                        }
                    }

                    createParentDirs(dst);
                    Files.copy(file, dst, new CopyOption[] { StandardCopyOption.REPLACE_EXISTING });
                    return FileVisitResult.CONTINUE;
                }
            });
        } catch (IOException ex) {
            pending = ex;
            throw ex;
        } finally {
            if (lock != null) {
                lock.unlock();
            }

            if (closeFs) {
                try {
                    closeFileSystem(srcDir);
                } catch (IOException ex) {
                    if (pending != null) {
                        pending.addSuppressed(ex);
                    } else {
                        throw ex;
                    }
                }
            }
        }
    }

    @Override
    public void accept(String clsName, byte[] data) {
        if (classNameFilter != null && !classNameFilter.test(clsName)) {
            return;
        }

        Path dstFile = null;
        if (lock != null) {
            lock.lock();
        }

        try {
            if (closed) {
                throw new IllegalStateException("consumer already closed");
            }

            dstFile = dstDir.resolve(clsName + ".class");

            if (isJarFs && Files.exists(dstFile, new LinkOption[0])) {
                if (Files.isDirectory(dstFile, new LinkOption[0])) {
                    throw new FileAlreadyExistsException("dst file " + dstFile + " is a directory");
                }

                Files.delete(dstFile);
            }

            createParentDirs(dstFile);
            Files.write(dstFile, data, new OpenOption[0]);
        } catch (IOException ex) {
            throw new UncheckedIOException("error writing to " + dstFile, ex);
        } finally {
            if (lock != null) {
                lock.unlock();
            }
        }
    }

    @Override
    public void close() throws IOException {
        if (closed) {
            return;
        }

        if (lock != null) {
            lock.lock();
        }

        try {
            if (fsToClose != null) {
                fsToClose.close();
            }

            closed = true;
        } finally {
            if (lock != null) {
                lock.unlock();
            }
        }
    }

    private static boolean isJar(Path path) {
        if (Files.exists(path, new LinkOption[0])) {
            return !Files.isDirectory(path, new LinkOption[0]);
        }

        String fileName = path.getFileName().toString().toLowerCase(Locale.ENGLISH);
        return fileName.endsWith(".jar") || fileName.endsWith(".zip");
    }

    private static void createParentDirs(Path path) throws IOException {
        Path parent = path.getParent();
        if (parent != null) {
            Files.createDirectories(parent);
        }
    }

    private static void closeFileSystem(Path path) throws IOException {
        try {
            path.getFileSystem().close();
        } catch (AccessDeniedException ex) {
            if (!FileSystemReference.isZipFsRemoveRealPathFailure(ex)) {
                throw ex;
            }
        }
    }

    public static class Builder {
        private final Path destination;
        private Boolean assumeArchive;
        private boolean threadSyncWrites;
        private Predicate<String> classNameFilter;

        public Builder(Path destination) {
            this.destination = destination;
        }

        public Builder assumeArchive(boolean assumeArchive) {
            this.assumeArchive = Boolean.valueOf(assumeArchive);
            return this;
        }

        public OutputConsumerPath build() throws IOException {
            boolean archive = assumeArchive == null || Files.exists(destination, new LinkOption[0])
                ? isJar(destination)
                : assumeArchive.booleanValue();

            return new OutputConsumerPath(destination, archive, threadSyncWrites, classNameFilter);
        }
    }

    public interface ResourceRemapper {
        boolean canTransform(TinyRemapper remapper, Path relativePath);

        void transform(Path destinationDirectory, Path relativePath, InputStream input, TinyRemapper remapper)
                throws IOException;
    }
}
