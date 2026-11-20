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

## 待办（M2b 遗留）

`icon.ico` 在离线环境**无法重新生成**（仓库里没有源 SVG，本地也没有 ImageMagick /
`tauri icon`），M2b 保留现有占位 ICO 不动，等联网或有 Windows 环境时执行：

```bash
# 需要先有正式 logo.svg / logo.png（1024×1024）
npm run tauri icon path/to/logo.png
```

生成后会覆盖本目录全部图标文件，无需改 `tauri.conf.json`。
