// 把 index.html / styles.css 拷到 dist，供 Tauri frontendDist 直接加载。
// 只做静态资源复制，不引入打包器（M2a 零框架约束）。
import { copyFile, mkdir } from "node:fs/promises";
import { fileURLToPath } from "node:url";
import { dirname, join } from "node:path";

const here = dirname(fileURLToPath(import.meta.url));
const root = join(here, "..");
const src = join(root, "src");
const dist = join(root, "dist");

const files = ["index.html", "styles.css"];

await mkdir(dist, { recursive: true });
for (const name of files) {
  await copyFile(join(src, name), join(dist, name));
  console.log(`已复制 ${name} -> dist/${name}`);
}
