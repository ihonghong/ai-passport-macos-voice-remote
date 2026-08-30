<p align="right">
  <strong>简体中文</strong> · <a href="CI-sync-main.md">English</a>
</p>

# 手动审查上游更新

`main` 是受支持的产品分支，因此有意关闭自动上游同步。FoloToy 仓库继续作为只读
`upstream` 远端保留。

```bash
git fetch upstream
git log --oneline --left-right main...upstream/main
git diff --stat main...upstream/main
```

采用上游提交前必须先审查。重点核对分区地址、Recovery 兼容性、BLE 身份与安全、BSP
引脚、屏幕方向、音频时钟和依赖版本。不得使用强制同步工作流覆盖产品 `main`。
