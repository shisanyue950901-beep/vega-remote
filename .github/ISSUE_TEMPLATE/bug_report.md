---
name: Bug 报告
about: 安装、连接、诊断或卸载出问题时用这个模板
title: '[bug] '
labels: bug
assignees: ''
---

## 环境

- Windows 版本（`winver`）：
- Windows PowerShell 5.1 还是 PowerShell 7：
- 角色：被控端 / 控制端 / 中继服务器
- Vega Remote 版本或 commit：
- 相关组件版本（Sunshine / Moonlight / Tailscale / RustDesk）：

## 问题

发生了什么？期望是什么？

## 复现步骤

1.
2.
3.

## 日志与诊断

请贴 **vega-doctor** 的输出（隐藏设备码、公网 IP、Tailscale 机器名后再贴）：

```powershell
powershell -File .\tools\vega-doctor.ps1
```

安装/卸载相关请贴脚本最后 30 行输出。**不要贴密码、Key、令牌、完整状态清单。**

## 尝试过的处理

-
