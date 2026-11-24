"""Check a compiled video_player_android TextureVideoPlayer class."""

import os
import re
import subprocess
import sys
from pathlib import Path


def main(class_file: Path) -> None:
    java_home = os.environ.get("JAVA_HOME")
    javap = str(Path(java_home) / "bin/javap") if java_home else "javap"
    bytecode = subprocess.check_output([javap, "-p", "-c", str(class_file)], text=True)
    factory_setter = r"DefaultRenderersFactory\.setEnableDecoderFallback:\(Z\)"
    builder_with_factory = r'ExoPlayer\$Builder\."<init>":\(Landroid/content/Context;Landroidx/media3/exoplayer/RenderersFactory;\)V'
    if not re.search(
        rf"iconst_1\s+\d+: +invokevirtual[^\n]+{factory_setter}"
        rf"[^\n]*\n\s*\d+: +invokespecial[^\n]+{builder_with_factory}",
        bytecode,
    ) or len(re.findall(factory_setter, bytecode)) != 1:
        raise SystemExit("TextureVideoPlayer must build ExoPlayer with decoder fallback enabled once.")
    print("TextureVideoPlayer passes decoder fallback=true to its ExoPlayer builder.")


if __name__ == "__main__":
    main(Path(sys.argv[1]))
