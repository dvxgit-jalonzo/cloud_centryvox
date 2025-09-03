# Keep Flutter plugin communication
-keep class io.flutter.plugin.common.** { *; }
-keep class io.flutter.embedding.engine.** { *; }
-keep class io.flutter.embedding.android.** { *; }

# Keep WebRTC and Janus client internals
-keep class org.webrtc.** { *; }
-keep class com.cloudwebrtc.** { *; }
-keep class org.appspot.apprtc.** { *; }
-keep class janus.** { *; }

# Keep Flutter CallKit Incoming
-keep class com.hiennv.flutter_callkit_incoming.** { *; }

# Keep all annotations
-keepattributes *Annotation*

# Kotlin coroutines
-keep class kotlinx.coroutines.** { *; }
-dontwarn kotlinx.coroutines.**

# Needed for reflection and internal class loading
-keep class **.*PluginRegistrant { *; }

# Preserve class and method names used via reflection
-keepnames class * { *; }
-keepclassmembers class * {
    public <init>(...);
}

-dontwarn com.google.android.play.core.splitcompat.**
-dontwarn com.google.android.play.core.splitinstall.**
-dontwarn com.google.android.play.core.tasks.**