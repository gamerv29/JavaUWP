package banditvault.xboxcompat;

import java.io.IOException;
import java.nio.file.Files;
import java.nio.file.Path;

public final class PathUtilResolver {
    private PathUtilResolver() {
    }

    public static void createDirectories(Path path) throws IOException {
        Files.createDirectories(path);
    }
}
