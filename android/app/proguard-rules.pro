# Flutter
-keep class io.flutter.** { *; }
-keep class io.flutter.plugins.** { *; }

# dartssh2
-keep class com.jcraft.** { *; }

# Kotlin
-keep class kotlin.** { *; }
-keepclassmembers class kotlin.Metadata { *; }

# Manter nomes de classes nativas
-keepattributes *Annotation*
-keepattributes SourceFile,LineNumberTable
-keepattributes Signature
-keepattributes Exceptions

# http / okhttp (usado pelo Flutter internamente)
-dontwarn okhttp3.**
-dontwarn okio.**
-dontwarn javax.annotation.**