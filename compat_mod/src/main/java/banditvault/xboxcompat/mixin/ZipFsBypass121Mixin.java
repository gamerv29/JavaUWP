package banditvault.xboxcompat.mixin;

import banditvault.xboxcompat.ZipFsPathResolver;
import java.io.IOException;
import java.net.URI;
import java.nio.file.Path;
import org.spongepowered.asm.mixin.Mixin;
import org.spongepowered.asm.mixin.Overwrite;

@Mixin(targets = "net.minecraft.class_7665")
public abstract class ZipFsBypass121Mixin {
    /**
     * @author Codex
     * @reason ZipFileSystemProvider's URI path calls toRealPath(), which fails in Xbox Dev Mode.
     */
    @Overwrite
    public static Path method_45203(URI uri) throws IOException {
        return ZipFsPathResolver.resolve(uri);
    }
}
