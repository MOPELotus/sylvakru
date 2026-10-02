# 聆序 / Linsen

基于 Sylvakru 和 TuneWeave 的私人音乐播放器，核心是搜索、音乐库、播放和歌词。
本地与在线歌曲可以混合排队。推荐、热搜和社区永久不在产品范围内。

默认启动设备内嵌 TuneWeave；在首页「账号与服务」可改用远程 HTTP(S) 服务。
账号按平台管理，Cookie 导入后转换为 TuneWeave Client mode 凭据，保存在系统安全存储。
搜索范围与播放选源独立：切换浏览平台不切换正在播放的队列。
默认开启跨平台回退、Unblock 和严格匹配，只有完整解析链确认没有可用源才置灰。

在线队列条目使用 TuneWeave Uni item；本地索引、重复项及队列顺序由现有播放器保存。
平台歌单直接读写账号，不提供额外云同步。云盘上传支持当前传输内继续，进程结束后需重新开始。
播放上报默认开启，仅上报实际网易云媒体；不确定是否送达的上报不自动重复。

## 开发

Flutter 3.47.5，Rust 1.98.1；依赖锁与 TuneWeave 源码版本均已固定。

```sh
flutter pub get --enforce-lockfile
flutter analyze
flutter test
cargo test --locked --manifest-path native/tuneweave_runtime/Cargo.toml
```

Android：设置 `ANDROID_NDK_HOME` 为 NDK 28.2.13676358，运行
`python tooling/build_native.py android arm64` 或 `arm`，再运行对应架构的 `flutter build apk`。
Windows：运行 `python tooling/build_native.py windows x64` 或 `arm64`，
`python tooling/build_lofty.py <架构>` 和 `python tooling/prepare_mpv.py <架构>`，
再运行 `flutter build windows --release`。ARM64 使用原生 ARM64 主机；
当运行官方 x64 Flutter SDK 时，先运行 `python tooling/prepare_flutter_arm64.py`，
该脚本核对固定 SDK 源码后选择原生 ARM64 引擎。最终安装包仍检查所有 PE 架构。
内嵌后端通过 Dart FFI 加载进程内动态库。

## 自动构建与发布

GitHub Actions：PR 运行静态检查和测试；主分支推送及手动触发构建四种架构。
Artifacts 保留 30 天，包含两个签名 APK、两个 Windows 安装程序及 SHA-256 文件。
Android 签名由固定的 `LINSEN_KEYSTORE_BASE64` 与 `LINSEN_KEYSTORE_PASSWORD` Secrets 提供。
密钥不得提交到仓库，后续升级必须保留同一份密钥。

Release 工作流支持 `v*` 标签和手动指定已有标签，总是检出该标签。
发布前必须完成 `docs/verification.json` 的真实验收记录；alpha/beta/rc 标签发布为预发行版。
尚未完成 ColorOS 16 流体云真机验收，不能将当前开发状态宣称为正式版完成。

保留 Apache-2.0 许可证与原作者归属，详见 [NOTICE](NOTICE)。
