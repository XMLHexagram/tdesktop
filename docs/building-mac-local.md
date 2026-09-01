# 本地构建（macOS / Apple Silicon，Xcode 27）

本文记录在这台机器上**实测跑通**的构建流程，是 [`building-mac.md`](building-mac.md) 的补充：
官方文档假设的是较旧的 Xcode 和干净的 Homebrew 环境，在 Xcode 27 / macOS 27 SDK 下会有三处必须修的地方。

实测环境：macOS 27.0（arm64）、Xcode 27.0 Beta 5（唯一安装的 Xcode）、Homebrew、16 核 / 64G。
产物：`out/Debug/Telegram.app`，arm64，`minos 12.0`、`sdk 27.0`，可正常启动。

## 目录布局

构建脚本按仓库的**上级目录**定位依赖，`Telegram/build/prepare/prepare.py` 会 `chdir` 到 `../..`：

```text
/Users/hexagram/Projects/blah/          # BuildPath
├── tdesktop/                           # 本仓库
└── Libraries/                          # prepare 脚本生成，约 42G
    └── local/Qt-6.11.1/
```

Qt 版本由 `Telegram/build/qt_version.py` 在 darwin 上硬编码为 **6.11.1**，`configure.py` 会自动
设置 `QT` 环境变量，**不需要手动 export**。

## 前置依赖

```bash
brew install git automake libtool cmake wget pkg-config gnu-tar ninja nasm meson
```

Xcode 必须是 `xcode-select -p` 指向的那个。如果装了多个，用 `DEVELOPER_DIR=...` 覆盖即可，
不需要 `sudo xcode-select`。

## 步骤

```bash
# 1. submodule（36 个，必须 recursive）
git submodule update --init --recursive

# 2. 本地补丁（见下节，缺任何一个都会构建失败）
git -C cmake apply "$PWD/docs/local-patches/cmake-helpers-ranges-libcxx.patch"

# 3. 编译全部第三方库 —— 最耗时的一步
./Telegram/build/prepare/mac.sh silent

# 4. 生成 Xcode 工程
Telegram/configure.sh \
    -D TDESKTOP_API_TEST=ON \
    -D CMAKE_OSX_DEPLOYMENT_TARGET=12.0 \
    -D CMAKE_OSX_ARCHITECTURES=arm64

# 5. 构建
cmake --build out --config Debug --target Telegram
```

产物在 `out/Debug/Telegram.app`。用隔离的数据目录试跑：

```bash
out/Debug/Telegram.app/Contents/MacOS/Telegram -workdir /tmp/tg-scratch
```

### 关于各个参数

- **`silent`** —— `prepare.py` 在检测到某个阶段的命令内容变化时会弹交互式
  `(r)ebuild, rebuild (a)ll, (s)kip, (p)rint, (q)uit?` 提示，没有 TTY 时会抛
  `termios.error` 直接崩掉。`silent` 让它自动重建。
  各阶段结果缓存在 `../Libraries/cache_keys`，中断后重跑会跳过已完成的阶段。
- **`TDESKTOP_API_TEST=ON`** —— 使用内置测试凭据（api_id 17349）。
  不加且不提供 `TDESKTOP_API_ID` / `TDESKTOP_API_HASH` 时 CMake 会 `FATAL_ERROR`。
  测试凭据有速率限制，正式用途请按 [api_credentials.md](api_credentials.md) 申请自己的。
- **`CMAKE_OSX_DEPLOYMENT_TARGET=12.0`** —— 仓库在
  `cmake/validate_special_target.cmake:25` 把它设为 10.13，而 Xcode 27 的 macOS SDK
  只支持 12.0 ~ 27.0。该变量是不带 `FORCE` 的 `CACHE STRING`，命令行 `-D` 可以覆盖。
- **`CMAKE_OSX_ARCHITECTURES=arm64`** —— 默认是 `x86_64;arm64` universal。本机运行
  只需要 arm64，编译量减半。要做发布包就去掉这一行。

## 必须的本地补丁

### 1. libheif 的 gdk-pixbuf 插件（`Telegram/build/prepare/prepare.py`）

libheif 的 mac 分支加上 `-D WITH_GDK_PIXBUF=OFF`。

libheif 的 CMake 默认 `WITH_GDK_PIXBUF=ON` 并自动探测系统里的 gdk-pixbuf。Homebrew 的
`gdk-pixbuf`（会被 `librsvg` / `chafa` 当依赖装进来）只有 arm64 切片，而这一步是按
`CMAKE_OSX_ARCHITECTURES="x86_64;arm64"` 编 universal 的，于是 x86_64 那半找不到 glib 符号：

```text
"_g_log", referenced from: _stop_load in pixbufloader-heif.c.o
ld: symbol(s) not found for architecture x86_64
```

upstream CI 的机器上没装 gdk-pixbuf，所以撞不到这个问题。

### 2. breakpad 的 deployment target（`Telegram/build/prepare/prepare.py`）

breakpad 的三条 `xcodebuild` 命令末尾追加 `MACOSX_DEPLOYMENT_TARGET=12.0`。

其余的库都是 clang 直接驱动，`-mmacosx-version-min=10.13` 只会产生警告；只有 breakpad 走
`xcodebuild`，会硬报错：

```text
error: The macOS deployment target 'MACOSX_DEPLOYMENT_TARGET' is set to 10.13,
but the range of supported deployment target versions is 12.0 to 27.0.x.
```

作为命令行 build setting 传入优先级最高，能盖过 `prepare.py` 全局导出的 10.13。
只改这一处的好处是不动全局 `environment` 字典——那会改变 `environmentKey` 哈希，
导致全部 26 个阶段缓存失效、从头重编。

> 库按 10.13、应用按 12.0 是安全的：依赖的最低版本**低于**使用方时不会有问题，
> 反过来才会告警。

### 3. range-v3 与新版 libc++（`cmake` submodule）

`cmake/external/ranges/CMakeLists.txt` 里给 `external_ranges` 定义
`META_NO_STD_FORWARD_DECLARATIONS`。

`Telegram/ThirdParty/range-v3/include/meta/meta.hpp:3789` 有一段 std 容器的前向声明，
守卫条件是 `#if defined(__apple_build_version__) || (defined(__clang__) && __clang_major__ < 6)`，
且**没有 `#else` 分支**——也就是说 gcc 和非 Apple clang 从来不编译这一段，Linux 构建一直
如此。它用的可见性宏 `META_TEMPLATE_VIS` 展开为 `_LIBCPP_TEMPLATE_VIS`，而 macOS 26+ SDK
的 libc++ 已经删除了这个宏，于是整段变成把 `allocator`、`pair`、`vector` 等重新声明成变量：

```text
error: redefinition of 'allocator' as different kind of symbol
error: variable has incomplete type 'class _LIBCPP_TEMPLATE_VIS'
```

`META_NO_STD_FORWARD_DECLARATIONS` 是 range-v3 自带的开关，打开后 Apple clang 走的路径
与 Linux 完全一致。

**注意这个文件属于 `cmake` submodule（desktop-app/cmake_helpers），`git submodule update`
会把改动冲掉。** 补丁已导出到
[`local-patches/cmake-helpers-ranges-libcxx.patch`](local-patches/cmake-helpers-ranges-libcxx.patch)，
重新 checkout submodule 后用上面第 2 步的命令重放。

## Docker：Linux 侧编译验证

Docker 编不出 macOS 应用，但仓库自带的 `Telegram/build/docker/centos_env/` 环境可以用来做
跨平台编译验证（Rocky 8 + gcc-toolset-15，Qt / FFmpeg / WebRTC / OpenSSL 全部预编译进镜像）。

upstream 发布的镜像**只有 amd64**，Apple Silicon 上靠 Rosetta 转译运行：

```bash
docker pull --platform linux/amd64 ghcr.io/telegramdesktop/tdesktop/centos_env:latest
docker tag ghcr.io/telegramdesktop/tdesktop/centos_env:latest tdesktop:centos_env
```

镜像由 `.github/workflows/docker.yml` 在 `Telegram/build/docker/centos_env/**` 变动时自动
构建推送，因此**用它之前先确认镜像的构建时间晚于本地 `Dockerfile` 的最后一次改动**：

```bash
docker buildx imagetools inspect ghcr.io/telegramdesktop/tdesktop/centos_env:latest \
    --format '{{json .Image}}' | python3 -c 'import json,sys; print(json.load(sys.stdin)["created"])'
git log -1 --format=%ci -- Telegram/build/docker/centos_env/Dockerfile
```

不匹配就得本地重建镜像（`Telegram/build/prepare/linux.sh`，需要 `poetry`，会把 Qt / WebRTC
等全部从源码编一遍，非常慢）。

跑构建：

```bash
docker run --rm -it --platform linux/amd64 \
    -u "$(id -u)" \
    -v "$PWD:/usr/src/tdesktop" \
    -e CONFIG=Debug \
    tdesktop:centos_env \
    /usr/src/tdesktop/Telegram/build/docker/centos_env/build.sh \
    -D TDESKTOP_API_TEST=ON
```

产物同样落在 `out/`，是 Linux ELF，**不能在 macOS 上直接运行**——这条路只用于验证改动能否
在 Linux/gcc 下编过。注意它和原生构建共用 `out/` 目录，来回切换需要清掉或换目录。
容器内会打印 `id: cannot find name for user ID 501`，是容器里没有对应 passwd 条目，无害。
