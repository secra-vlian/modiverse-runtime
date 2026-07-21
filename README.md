# Modiverse Runtime

Modiverse Runtime 是独立于业务仓库的 Runtime 构建与发布项目。仓库保存构建脚本、版本目录、校验信息和发布契约；Runtime 压缩包通过 GitHub/Gitee Releases 分发，不提交到 Git 历史。

## 目录结构

```text
runtime/
├── x86_64/
│   ├── nginx/<version>/
│   ├── postgresql/<version>/
│   └── ...
└── aarch64/
    └── ...
```

构建脚本位于 `scripts/`。Runtime 软件包统一命名为 `<software>-<version>-linux-<arch>.tar.gz`，例如 `nginx-1.28.3-linux-x86_64.tar.gz`。安装器 GitHub Release `init` 默认附件名另带 `-centos7-runtime` 后缀；Nexus / 真机验收常用短名 + 子目录布局，现场 YAML 显式覆盖即可。

在 Apple Silicon 或其他原生 ARM64 Docker 主机上，默认以 **混合 musl + glibc 回退** 策略构建 aarch64 Runtime：

- **优先官方 musl**：Alpine apk（nginx / postgresql / redis / zeromq / ffmpeg）、OpenObserve `*-linux-arm64-musl`、静态 Go 二进制（tusd / otelcol）
- **无 musl 则 glibc 源码构建**：common-libs、poppler、LibreOffice 等继续 manylinux2014（glibc 2.17）自定义构建，并在产物目录写入 `UNSUPPORTED-MUSL` 标识

策略表见 `scripts/runtime-build/aarch64-linkage.env`；构建结束生成 `runtime/aarch64/LINKAGE-MANIFEST.yaml`。

```bash
scripts/build-aarch64-runtime.sh
```

主构建一次产出：

- `common-libs`（glibc-fallback；含 `libcrypt.so.2`，`service.enabled: false`）
- L0 组件默认 **musl 官方交付**（nginx / postgresql / redis / zeromq / tusd；可选 otel / ffmpeg / openobserve）
- **glibc-fallback** 组件（poppler / libreoffice）带 `UNSUPPORTED-MUSL` 标识
- 组件双 `RUNPATH`（glibc 路径）：`$ORIGIN/../lib:$ORIGIN/../../../common-libs/current/lib`
- **禁止**任何归档打包 `libc.so.6` / `ld-linux*` 或 `libc.musl*` / `ld-musl*`

可通过环境变量覆盖基础镜像（须保持 glibc ≤ 2.17）：

```bash
MDV_AARCH64_BUILDER_BASE_IMAGE=quay.io/pypa/manylinux2014_aarch64 \
MDV_AARCH64_BUILDER_IMAGE=modiverse-runtime-aarch64-builder:manylinux2014 \
  scripts/build-aarch64-runtime.sh
```

构建完成后必须跑契约门禁（禁 ship glibc/musl 核心 libc；glibc-fallback 仍检 GLIBC ≤ 2.17）：

```bash
scripts/verify-aarch64-runtime.sh
```

不合规的 glibc-only OpenObserve / LibreOffice 实验品请移到 `runtime/deferred-aarch64-l1-l2/`（勿放在 `runtime/aarch64/` 下），否则 verify 会失败。

也可仅重建单个组件，例如 `scripts/build-aarch64-runtime.sh redis` 或 `common-libs`。脚本会向镜像构建与下载容器透传 `HTTP_PROXY`、`HTTPS_PROXY` 和 `NO_PROXY`（含小写形式）。产物写入 `runtime/aarch64/<software>/<version>/`，并同步生成 `.sha256` 与 `build.log`。

扁平化安装器验收目录（**不再**做 common-libs / RUNPATH / LO 补丁；逻辑已并入主构建）：

```bash
scripts/make-acceptance-artifacts-aarch64.sh
```

产物落在 `runtime/acceptance-repo/aarch64/`（路径形如 `nginx/nginx-1.28.3-linux-aarch64.tar.gz`）。将该目录上传到 Nexus 或通过 `file://` 作为验收 `MDV_ACCEPTANCE_RUNTIME_BASE`。

组装纯离线 L0 介质（含安装器）：

```bash
MDV_INSTALLER_BIN=/path/to/aarch64/mdv-installer \
  scripts/pack-offline-L0-aarch64.sh
# → runtime/offline-L0-aarch64/{mdv-installer,mdv.config.yaml,runtime/...}
# 默认 baseURL: file:///opt/mdv-offline-L0-aarch64/runtime
# 目标机将整树拷到 /opt/mdv-offline-L0-aarch64 后执行 install
```

将扁平验收仓上传到 Nexus（需凭据）：

```bash
MDV_NEXUS_USER=... MDV_NEXUS_PASSWORD=... \
  scripts/publish-acceptance-repo-aarch64.sh
```

重打包安装器制品时，通过 `MDV_RUNTIME_OVERLAY_ROOT` 指向 Modiverse 主仓库的 `apps/installer/runtime-entrypoints`：

```bash
MDV_RUNTIME_OVERLAY_ROOT=../modiverse/apps/installer/runtime-entrypoints \
  scripts/repack-runtime-with-contract.sh nginx input.tar.gz output.tar.gz
```

## 发布约束

1. 已发布的 Runtime 版本和附件不可覆盖，修复时发布新的 catalog 版本。
2. 每个 Runtime 归档必须携带 `manifest.yaml`，并提供 SHA-256 校验值。
3. GitHub 与 Gitee 镜像必须发布完全相同的附件。
4. 安装器必须固定 catalog 版本并校验下载制品，不能依赖 `latest`。
5. 发布第三方二进制前必须确认许可证及再分发义务。
6. aarch64 只有 L0（或声明范围内）真机验收通过后才能宣称该架构已交付；勿将未验收的 OpenObserve / LibreOffice 混称全量交付。

## 契约文档

制品契约与分层交付见主仓：

- `knowledge/02-standards/devops/runtime-aarch64-artifact-delivery.md`
- `docs/roadmap/installer-aarch64-runtime-delivery-plan.md`
