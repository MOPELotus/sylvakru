# 播放库核对记录

2026-10-02。该记录说明实际下载的库；最终 APK/安装程序仍须提取并比较哈希。

Windows x64/ARM64 使用 `tooling/mpv-lock.json` 固定的 mpv 官方 LGPL 构建。
下载后校验 SHA-256，安装前检查全部 EXE/DLL 的 PE 架构。
已排除曾检查过、FFmpeg 标记为 `nonfree and unredistributable` 的另一份 ARM64 构建。

Android 使用上游固定的 [20260920 播放库](https://github.com/AfalpHy/libmpv-android-audio-build/releases/tag/20260920)。

| JAR | SHA-256 |
| --- | --- |
| default-arm64-v8a.jar | `503fbdaddefc5d4dd5b752b58bd6c4c31d670809c9931e0d014b2b41266d9b10` |
| default-armeabi-v7a.jar | `f61949edc41edc029d1eab57169eac59ab7e765c5ad60818775e29b7d1d68176` |

解包检查两个 `libmpv.so`：其中的 libavcodec、libavformat、libavfilter、
libavutil、libswscale、libswresample 均报告 LGPL version 3 or later；
编译配置包含 `--disable-gpl --enable-version3`，未发现 nonfree 配置或声明。
应用附 LGPL 2.1、LGPL 3 和 GPL 3 正文。GPL 3 正文是 LGPL 3 引用的许可文本，
不表示这些播放库启用了 GPL 编解码器。

对应源码和构建脚本以各上游发布记录及固定版本为入口：
[Android 构建项目](https://github.com/AfalpHy/libmpv-android-audio-build)、
[Windows mpv 源码](https://github.com/mpv-player/mpv/commit/a1f50f2c3)。
发布前还须核对依赖对应源码是否完整可取得；本记录不代替最终包和源码的交付核对。

## 固定源码入口复核

Android 发布标签 20260920 当前指向提交
`cf2cc6433890192a98c8277aafd2b18b0ea90a98`。
[依赖声明](https://github.com/AfalpHy/libmpv-android-audio-build/blob/cf2cc6433890192a98c8277aafd2b18b0ea90a98/buildscripts/include/depinfo.sh)
列出 mpv 0.41.0、FFmpeg 8.1 和 OpenSSL 3.4.0；
[FFmpeg 构建脚本](https://github.com/AfalpHy/libmpv-android-audio-build/blob/cf2cc6433890192a98c8277aafd2b18b0ea90a98/buildscripts/scripts/ffmpeg.sh)
明确关闭 GPL、启用 version3。发布资产仅有四种 ABI 的 JAR。
这些是上游声明和脚本的入口，不表示已经证明每个二进制依赖的对应源码完整性。

Windows mpv 发布所用提交扩展为完整 SHA：
`a1f50f2c38206dc943f331cf5a5b02f97a0ce219`，已写入下载锁文件。
[固定版本的 Windows 构建流程](https://github.com/mpv-player/mpv/blob/a1f50f2c38206dc943f331cf5a5b02f97a0ce219/.github/workflows/build.yml)
使用 BtbN 的 `win64-lgpl` / `winarm64-lgpl` 容器，其声明标签为 latest。
仅有 mpv 提交不足以证明容器内全部依赖的对应源码，正式发布前还需完成该项核对。

`verification.json` 的 license_audit 保持未通过；它属于正式发布的独立门槛，
不能用 Android 真机验收或本轮代码测试替代。
