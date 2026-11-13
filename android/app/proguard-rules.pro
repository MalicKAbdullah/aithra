# LiteRT-LM's native library calls back into its Kotlin classes by name and
# reads them through reflection (tools, JSON conversion).
-keep class com.google.ai.edge.litertlm.** { *; }
-keep class com.google.gson.** { *; }
-dontwarn com.google.ai.edge.litertlm.**

# aithra_llama.cpp binds these by JNI name and calls TokenCallback.onToken.
-keep class dev.abdullah.aithra.engine.LlamaNative { *; }
-keep interface dev.abdullah.aithra.engine.LlamaNative$TokenCallback { *; }
-keep class * implements dev.abdullah.aithra.engine.LlamaNative$TokenCallback { *; }
