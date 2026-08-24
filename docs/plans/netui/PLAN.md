# NetUI 计划入口

完整实施计划请从 [README.md](./README.md) 开始。

固定命令契约：

- `netup`：启动默认 JSON。
- `netdown`：停止 NetUI 受管实例。
- `netui`：管理全部 JSON、设置默认，并控制全局/大陆白名单/off 持久环境模式。
- UI：大量使用有层级的圆角矩形；使用 VHS 做脚本化视觉测试并将 PNG 复制到 `/mnt/c/Users/genev/Desktop/`。
- 生命周期：仅 tmux，不使用 systemd/nohup。

本目录仅为计划，不包含实现。
