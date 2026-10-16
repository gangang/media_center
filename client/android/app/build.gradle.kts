import java.io.FileInputStream
import java.util.Properties

plugins {
    id("com.android.application")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

// 正式签名材料从 android/key.properties 读取；该文件与 app/upload-keystore.jks
// 都已被 .gitignore 排除，不会进入版本库。
//
// 找不到 key.properties 时**默认让构建失败**，而不是静默回退到 debug 密钥。
// 理由：debug 密钥签出的包与正式包签名不同，安装器会拒绝覆盖安装
// (INSTALL_FAILED_UPDATE_INCOMPATIBLE)——这正是"测试包无法升级"的成因。
// 静默产出一个"看起来是正式包、实际升不了级"的产物，比直接构建失败更糟。
//
// 关于告警的教训：最初这里用的是 logger.warn + 回退。但实测发现这条 warn 在
// `flutter build apk` 下不可见（Flutter 会过滤 Gradle 的日志输出，脚本里的 println
// 同样看不到），而且 Gradle 9 默认开启配置缓存，脚本体在第二次构建起就不再重新执行。
// 也就是说"打一条警告"这个机制本身是不可靠的：它既不一定显示，也不一定执行。
// 所以改成 fail-closed —— 构建失败是 Flutter 一定会透传给用户的。
val keystorePropertiesFile = rootProject.file("key.properties")
val keystoreProperties = Properties()
val hasReleaseKeystore = keystorePropertiesFile.exists()
if (hasReleaseKeystore) {
    FileInputStream(keystorePropertiesFile).use { keystoreProperties.load(it) }
}

// 显式退出开关：确实需要一个 debug 签名的 release 包时，在 android/gradle.properties
// 里加一行 `mc.allowDebugSigning=true`。默认关闭。
val allowDebugSigning = (findProperty("mc.allowDebugSigning") as String?)?.toBoolean() ?: false

android {
    namespace = "ai.mediacenter.media_center_client"
    compileSdk = flutter.compileSdkVersion
    ndkVersion = flutter.ndkVersion

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    defaultConfig {
        // 包名一旦发布不可更改：改包名等于换一个 App，用户无法覆盖升级。
        applicationId = "ai.mediacenter.media_center_client"
        minSdk = flutter.minSdkVersion
        targetSdk = flutter.targetSdkVersion
        // 版本号唯一来源是 pubspec.yaml 的 `version: 1.0.0+1`（名字+版本号），
        // 由 Flutter Gradle 插件注入，不要在这里再写一遍。
        versionCode = flutter.versionCode
        versionName = flutter.versionName
    }

    signingConfigs {
        if (hasReleaseKeystore) {
            create("release") {
                // storeFile 相对 android/ 根目录，用 rootProject.file 解析，避免
                // 相对 app/ 还是 android/ 的歧义。
                storeFile = rootProject.file(keystoreProperties.getProperty("storeFile"))
                storePassword = keystoreProperties.getProperty("storePassword")
                keyAlias = keystoreProperties.getProperty("keyAlias")
                keyPassword = keystoreProperties.getProperty("keyPassword")
                // PKCS12 是 Java 9+ 的默认密钥库格式，显式声明以免依赖 JDK 默认值。
                storeType = keystoreProperties.getProperty("storeType") ?: "PKCS12"
            }
        }
    }

    buildTypes {
        release {
            // 这里刻意**不抛异常**。`buildTypes.release` 的这段配置在配置阶段对所有构建
            // 都会执行一次，把 require 写在这里会让 `flutter build apk --debug` 一起失败
            // （踩过：第一版就是这样，报错信息里推荐用户改用 --debug，结果 --debug 也挂）。
            // fail-closed 的落点在文件末尾的 assembleRelease 钩子里，只针对 release。
            signingConfig = if (hasReleaseKeystore) {
                signingConfigs.getByName("release")
            } else {
                signingConfigs.getByName("debug")
            }
        }
    }
}

kotlin {
    compilerOptions {
        jvmTarget = org.jetbrains.kotlin.gradle.dsl.JvmTarget.JVM_17
    }
}

flutter {
    source = "../.."
}

// fail-closed 的落点：只有真正要产出 release 包时才失败，不影响 --debug / --profile。
// 用 doFirst（执行期）而不是配置期，一是为了只命中 release 构建，二是避开
// Gradle 9 默认开启的配置缓存——配置期的判断会被缓存，执行期的不会。
tasks.matching { it.name == "assembleRelease" }.configureEach {
    doFirst {
        if (!hasReleaseKeystore && !allowDebugSigning) {
            throw GradleException(
                """
                [media_center] 未找到 android/key.properties，拒绝用 debug 密钥签名 release 包。

                  原因：debug 签名的包与正式包签名不同，安装器会拒绝覆盖安装
                        (INSTALL_FAILED_UPDATE_INCOMPATIBLE)，也就是"测试包升不了级"。

                  请三选一：
                    1) 配置正式签名 —— 见 README「Android 正式打包（签名）」；
                    2) 只想确认代码能编过 —— 用 flutter build apk --debug；
                    3) 确实要一个 debug 签名的 release 包 —— 在 android/gradle.properties
                       中加一行：mc.allowDebugSigning=true
                """.trimIndent()
            )
        }
    }
}
