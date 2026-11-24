allprojects {
    repositories {
        google()
        mavenCentral()
    }
}

val newBuildDir: Directory =
    rootProject.layout.buildDirectory
        .dir("../../build")
        .get()
rootProject.layout.buildDirectory.value(newBuildDir)

subprojects {
    val newSubprojectBuildDir: Directory = newBuildDir.dir(project.name)
    project.layout.buildDirectory.value(newSubprojectBuildDir)
}
subprojects {
    project.evaluationDependsOn(":app")
}

abstract class PatchBheTexturePlayer : DefaultTask() {
    @get:InputFile
    @get:PathSensitive(PathSensitivity.RELATIVE)
    abstract val upstream: RegularFileProperty

    @get:OutputDirectory
    abstract val generatedDirectory: DirectoryProperty

    @TaskAction
    fun patch() {
        val source = upstream.get().asFile.readText()
        val original = "new ExoPlayer.Builder(context)"
        check(source.indexOf(original) >= 0 && source.indexOf(original) == source.lastIndexOf(original)) {
            "video_player_android changed its texture player builder. Recheck decoder fallback."
        }
        val target = generatedDirectory.file(
            "io/flutter/plugins/videoplayer/texture/TextureVideoPlayer.java",
        ).get().asFile
        target.parentFile.mkdirs()
        target.writeText(
            source.replace(
                original,
                "new ExoPlayer.Builder(context, " +
                    "new androidx.media3.exoplayer.DefaultRenderersFactory(context)" +
                    ".setEnableDecoderFallback(true))",
            ),
        )
    }
}

// App previews use video_player's default texture backend. Overlay only its builder
// in generated Android sources so local and CI builds leave the Pub cache untouched.
project(":video_player_android") {
    val upstreamSource = file(
        "src/main/java/io/flutter/plugins/videoplayer/texture/TextureVideoPlayer.java",
    )
    pluginManager.withPlugin("com.android.library") {
        extensions.getByType<com.android.build.api.variant.LibraryAndroidComponentsExtension>().onVariants { variant ->
            val variantName = variant.name.replaceFirstChar { it.uppercaseChar() }
            val patchTexturePlayer = tasks.register<PatchBheTexturePlayer>("patchBhe${variantName}TexturePlayer") {
                upstream.set(upstreamSource)
            }
            checkNotNull(variant.sources.java).addGeneratedSourceDirectory(
                patchTexturePlayer, PatchBheTexturePlayer::generatedDirectory,
            )
        }
    }
    tasks.withType<JavaCompile>().configureEach {
        exclude { it.file == upstreamSource }
    }
}

tasks.register<Delete>("clean") {
    delete(rootProject.layout.buildDirectory)
}
