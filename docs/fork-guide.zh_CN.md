<p align="right">
  <strong>简体中文</strong> · <a href="fork-guide.md">English</a>
</p>

# 上游维护方式

本仓库基于 `FoloToy/ai-passport` 开发，保留原始 Git 历史和 MIT 署名。现在 `main`
代表受支持的 Mac 语音遥控产品，不再自动同步 FoloToy 上游。

远端分工如下：

```text
origin    git@github.com:ihonghong/ai-passport-macos-voice-remote.git # 产品仓库
upstream  https://github.com/FoloToy/ai-passport.git                  # 只读基线
```

日常改动在短生命周期 `feature/*` 分支开发，审查后合入本仓库 `main`。需要采用上游
更新时，先 fetch `upstream`，审查提交与硬件契约，再 cherry-pick 或只合并确认过的
改动；不得把上游 `main` 强制同步覆盖产品分支。

继续保留上游署名与仓库许可证。通用修复仍可另行提交给 FoloToy；产品专属固件、Mac
Bridge、Provider 配置以及私人或无再分发许可的素材只留在本仓库或本机。
