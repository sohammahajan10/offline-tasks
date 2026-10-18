# R8 keep rules for release builds.
#
# shared_preferences_android calls its Kotlin API from Dart through JNI
# (package:jni), so R8 can't see those calls. Without these rules release
# builds crashed at startup with NoSuchMethodError (Supabase keeps the
# session in shared preferences). Keep the plugin's API and the JNI glue.
-keep class io.flutter.plugins.sharedpreferences.** { *; }
-keep class com.github.dart_lang.jni.** { *; }
-keep class com.github.dart_lang.jni_flutter.** { *; }

# The JNI bindings look methods up by their exact JVM signature, and suspend
# functions take a kotlin.coroutines.Continuation (results come back as
# kotlin.Result). R8 renamed Continuation (to "d8"), so the lookup failed
# even with the plugin's classes kept. Keep the coroutine types' names.
-keep class kotlin.coroutines.** { *; }
-keep class kotlin.Result { *; }
-keep class kotlin.Result$Failure { *; }
