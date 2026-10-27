# Third-party tools

Dropwheel does not include or link any of these tools. When you run an action, Dropwheel starts them as separate programs. You install them yourself, for example with `brew install ffmpeg webp`. Each tool keeps its own license.

| Tool | Used for | License |
|---|---|---|
| [FFmpeg](https://ffmpeg.org/legal.html) | Video and audio conversion | LGPL 2.1 or later. A build with `--enable-gpl` is under the GPL. The Homebrew build uses `--enable-gpl --enable-version3`. |
| [x264](https://www.videolan.org/developers/x264.html) (inside FFmpeg) | H.264 video (MP4, MOV) | GPL 2 or later |
| [x265](https://bitbucket.org/multicoreware/x265_git) (inside FFmpeg) | HEVC video | GPL 2 or later |
| [libvpx](https://chromium.googlesource.com/webm/libvpx) (inside FFmpeg) | WebM video | BSD 3-Clause |
| [Opus](https://opus-codec.org/license/) (inside FFmpeg) | WebM, OGG and Opus audio | BSD 3-Clause |
| [LAME](https://lame.sourceforge.io) (inside FFmpeg) | MP3 audio | LGPL 2 or later |
| [libwebp](https://chromium.googlesource.com/webm/libwebp) (`cwebp`, `gif2webp`) | WebP images | BSD 3-Clause |

## If you ship these tools with Dropwheel

`build.sh` copies nothing from this list. If you put your own copies in `Dropwheel.app/Contents/Resources/Tools`, Dropwheel uses them before the Homebrew copies. If you then share that app, you must follow each tool's license. For a GPL build of FFmpeg, include the GPL text. Also give the recipients the exact FFmpeg source code and your configure line.

H.264 and HEVC are covered by patents in some countries. The x264 and x265 licenses do not grant a patent license.
