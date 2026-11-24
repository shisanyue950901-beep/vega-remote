// 把 index.html / styles.css 拷到 dist，供 Tauri frontendDist 直接加载。
// 只做静态资源复制，不引入打包器（M2a 零框架约束）。
import { copyFile, mkdir, readFile, writeFile } from "node:fs/promises";
import { fileURLToPath } from "node:url";
import { dirname, join } from "node:path";

const here = dirname(fileURLToPath(import.meta.url));
const root = join(here, "..");
const src = join(root, "src");
const dist = join(root, "dist");

const files = ["index.html", "styles.css"];

await mkdir(dist, { recursive: true });
// 版本号唯一来源：package.json；与 tauri.conf.json 不一致直接失败，避免界面显示旧版本。
const pkgVersion = JSON.parse(await readFile(join(root, "package.json"), "utf8")).version;
const tauriVersion = JSON.parse(await readFile(join(root, "src-tauri", "tauri.conf.json"), "utf8")).version;
if (!/^\d+\.\d+\.\d+$/.test(pkgVersion) || pkgVersion !== tauriVersion) {
  throw new Error(`版本号不一致：package.json=${pkgVersion} tauri.conf.json=${tauriVersion}`);
}
for (const name of files) {
  if (name === "index.html") {
    const html = (await readFile(join(src, name), "utf8")).replaceAll("__VEGA_VERSION__", pkgVersion);
    if (html.includes("__VEGA_VERSION__")) throw new Error("index.html 版本占位符未替换");
    await writeFile(join(dist, name), html);
  } else {
    await copyFile(join(src, name), join(dist, name));
  }
  console.log(`已复制 ${name} -> dist/${name}`);
}
