# 图标占位说明（M2a）

当前 `32x32.png`、`128x128.png`、`128x128@2x.png`、`icon.ico` 只是程序生成的
蓝底白色「V」占位图标，仅用于让 `tauri build` 能通过资源嵌入与托盘图标加载。

- 正式图标确定后，用同一文件名覆盖即可，不需要改 `tauri.conf.json`。
- 建议尺寸：`32x32.png`、`128x128.png`、`256x256`（`128x128@2x.png`）、`icon.ico`（含 16/32/48/256 多尺寸）。
- 托盘状态色（蓝=就绪、绿=被控中、灰=离线）在 M2b 切换图标资源，不放这里。
- 生成方式（需本机 ImageMagick 或类似工具）：

```bash
magick logo.svg -resize 32x32 icons/32x32.png
magick logo.svg -resize 128x128 icons/128x128.png
magick logo.svg -resize 256x256 icons/128x128@2x.png
magick logo.svg -define icon:auto-resize=256,48,32,16 icons/icon.ico
```
