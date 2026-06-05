import java.io.IOException;
import java.io.InputStream;
import java.io.OutputStream;
import java.nio.file.Files;
import java.nio.file.Path;
import java.util.HashSet;
import java.util.Set;
import java.util.zip.ZipEntry;
import java.util.zip.ZipFile;
import java.util.zip.ZipOutputStream;

import net.neoforged.accesstransformer.api.AccessTransformerEngine;
import org.objectweb.asm.ClassReader;
import org.objectweb.asm.ClassWriter;
import org.objectweb.asm.Type;
import org.objectweb.asm.tree.ClassNode;

public final class ApplyAccessTransformers {
    private ApplyAccessTransformers() {
    }

    public static void main(String[] args) throws Exception {
        if (args.length != 3) {
            throw new IllegalArgumentException("Usage: ApplyAccessTransformers <input.jar> <accessTransformer.cfg> <output.jar>");
        }

        Path inputJar = Path.of(args[0]);
        Path atConfig = Path.of(args[1]);
        Path outputJar = Path.of(args[2]);

        AccessTransformerEngine engine = AccessTransformerEngine.newEngine();
        engine.loadATFromPath(atConfig);

        Set<String> targets = new HashSet<>();
        for (Type target : engine.getTargets()) {
            targets.add(target.getInternalName());
        }

        int transformed = 0;
        Files.createDirectories(outputJar.getParent());
        try (ZipFile input = new ZipFile(inputJar.toFile());
             OutputStream fileOut = Files.newOutputStream(outputJar);
             ZipOutputStream output = new ZipOutputStream(fileOut)) {
            var entries = input.entries();
            while (entries.hasMoreElements()) {
                ZipEntry entry = entries.nextElement();
                ZipEntry next = new ZipEntry(entry.getName());
                next.setTime(entry.getTime());
                output.putNextEntry(next);

                if (!entry.isDirectory() && entry.getName().endsWith(".class")) {
                    String className = entry.getName().substring(0, entry.getName().length() - ".class".length());
                    if (targets.contains(className)) {
                        byte[] bytes = readAll(input, entry);
                        ClassReader reader = new ClassReader(bytes);
                        ClassNode node = new ClassNode();
                        reader.accept(node, 0);

                        boolean changed = engine.transform(node, Type.getObjectType(className));
                        if (changed) {
                            ClassWriter writer = new ClassWriter(0);
                            node.accept(writer);
                            output.write(writer.toByteArray());
                            transformed++;
                        } else {
                            output.write(bytes);
                        }
                    } else {
                        copy(input, entry, output);
                    }
                } else {
                    copy(input, entry, output);
                }

                output.closeEntry();
            }
        }

        System.out.println("Applied access transformers to " + transformed + " classes");
        if (transformed == 0) {
            throw new IllegalStateException("No classes were transformed; check the access transformer config and input jar");
        }
    }

    private static byte[] readAll(ZipFile zip, ZipEntry entry) throws IOException {
        try (InputStream input = zip.getInputStream(entry)) {
            return input.readAllBytes();
        }
    }

    private static void copy(ZipFile zip, ZipEntry entry, ZipOutputStream output) throws IOException {
        if (entry.isDirectory()) {
            return;
        }
        try (InputStream input = zip.getInputStream(entry)) {
            input.transferTo(output);
        }
    }
}
