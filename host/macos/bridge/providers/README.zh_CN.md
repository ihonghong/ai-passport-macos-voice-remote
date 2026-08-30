<p align="right">
  <strong>简体中文</strong> · <a href="README.md">English</a>
</p>

# 指标 Provider 插件

Provider 提供当前通信协议支持的两个可选仪表盘指标：`0..100` 的剩余额度，以及非负
整数形式的今日 Token 总量。Provider 只在 Mac 上运行，不处理音频和键盘事件。

内置 Provider：

- `codex`：通过本地 Codex CLI 读取剩余额度，并汇总本机 `~/.codex` 会话记录里的
  Token 计数事件；只有用户主动选择后才运行，不会上传这些记录，默认每五分钟更新。
- `none`：关闭指标，但不影响遥控和音频功能。
- `auto`：能找到 Codex CLI 时选择 `codex`，否则选择 `none`。

公开版本默认使用 `none`。需要用量仪表盘时，再明确选择 `codex` 或 `auto`。

新增内置 Provider 时，在本目录创建 `<名称>.py` 并导出：

```python
from providers.base import MetricSnapshot

class ExampleProvider:
    name = "example"
    refresh_seconds = 300

    def read(self):
        return MetricSnapshot(
            provider=self.name,
            remaining_percent=75,
            daily_total=120_000_000,
        )

def create(settings):
    return ExampleProvider()
```

随后把 `provider.name` 设为 `example`。也可以填写完整 Python 模块名来加载外部模块，
前提是该模块位于安装环境的 Python 导入路径中。凭证不要提交进仓库；非敏感选项通过
`provider.settings` 传入。

对应的固件文案在构建时选择：

```bash
idf.py -D AI_PASSPORT_PROVIDER_PROFILE=codex build
```

不强调具体模型时使用 `generic`，也可以增加一个很小的
`main/plugins/providers/<名称>/provider_profile.h` 并定义四个文案宏。数值通信协议保持不变。
