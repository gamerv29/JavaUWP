package banditvault.xboxcompat.mixin;

import banditvault.xboxcompat.ReturnToLauncherSignal;
import banditvault.xboxcompat.XboxCompatLog;
import net.minecraft.class_310;
import org.spongepowered.asm.mixin.Mixin;
import org.spongepowered.asm.mixin.injection.At;
import org.spongepowered.asm.mixin.injection.Inject;
import org.spongepowered.asm.mixin.injection.callback.CallbackInfo;

@Mixin(class_310.class)
public abstract class MinecraftClientExitMixin {
    @Inject(method = "method_1514", at = @At("TAIL"))
    private void banditvault$returnToLauncherWhenMainLoopExits(CallbackInfo ci) {
        XboxCompatLog.log("MinecraftClient main loop exited; signaling launcher return");
        throw new ReturnToLauncherSignal();
    }
}
