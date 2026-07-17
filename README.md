# Modiverse Runtime

Modiverse Runtime 是独立于业务仓库的 Runtime 构建与发布项目。仓库保存版本目录、校验信息和发布契约；Runtime 压缩包通过 GitHub/Gitee Releases 分发，不提交到 Git 历史。

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

## 发布约束

1. 已发布的 Runtime 版本和附件不可覆盖，修复时发布新的 catalog 版本。
2. 每个 Runtime 归档必须携带 `manifest.yaml`，并提供 SHA-256 校验值。
3. GitHub 与 Gitee 镜像必须发布完全相同的附件。
4. 安装器必须固定 catalog 版本并校验下载制品，不能依赖 `latest`。
5. 发布第三方二进制前必须确认许可证及再分发义务。

