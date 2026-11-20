// Vega 控制台 M2a：静态界面交互
// 约束：不发任何网络请求，不采集遥测；所有数据为占位数据。

interface TauriWindowHandle {
  minimize(): Promise<void>;
  toggleMaximize(): Promise<void>;
  close(): Promise<void>;
  startDragging(): Promise<void>;
}

interface TauriGlobal {
  window?: { getCurrentWindow(): TauriWindowHandle };
  core?: { invoke<T>(cmd: string, args?: Record<string, unknown>): Promise<T> };
  clipboardManager?: { writeText(text: string): Promise<void> };
}

declare global {
  interface Window {
    __TAURI__?: TauriGlobal;
  }
}

const DEVICE_CODE = "123 456 789";
const PASSWORD_LENGTH = 8;

function byId<T extends HTMLElement>(id: string): T {
  const el = document.getElementById(id);
  if (!el) {
    throw new Error(`找不到元素 #${id}`);
  }
  return el as T;
}

function randomPassword(length: number): string {
  const alphabet = "ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnpqrstuvwxyz23456789";
  let out = "";
  for (let i = 0; i < length; i += 1) {
    out += alphabet.charAt(Math.floor(Math.random() * alphabet.length));
  }
  return out;
}

async function copyText(text: string): Promise<boolean> {
  try {
    const tauriClipboard = window.__TAURI__?.clipboardManager;
    if (tauriClipboard) {
      await tauriClipboard.writeText(text);
      return true;
    }
    if (navigator.clipboard) {
      await navigator.clipboard.writeText(text);
      return true;
    }
    return false;
  } catch {
    return false;
  }
}

/** 把「关闭到托盘」勾选状态同步给 Rust（Rust 侧默认 true）。 */
function syncCloseToTray(enabled: boolean): void {
  const core = window.__TAURI__?.core;
  if (!core) {
    return;
  }
  void core.invoke("set_close_to_tray", { enabled }).catch(() => {
    /* 非 Tauri 环境或命令不可用时忽略：界面保持静态 */
  });
}

function flashLabel(button: HTMLButtonElement, text: string): void {
  const original = button.dataset.originalLabel ?? button.textContent ?? "";
  button.dataset.originalLabel = original;
  button.textContent = text;
  window.setTimeout(() => {
    button.textContent = original;
  }, 1200);
}

/* ---------- 左栏导航 ---------- */
function setupNav(): void {
  const items = Array.from(document.querySelectorAll<HTMLButtonElement>(".nav__item"));
  const pages = Array.from(document.querySelectorAll<HTMLElement>(".page"));

  items.forEach((item) => {
    item.addEventListener("click", () => {
      const target = item.dataset.page;
      if (!target) {
        return;
      }
      items.forEach((other) => other.classList.toggle("is-active", other === item));
      pages.forEach((page) => page.classList.toggle("is-active", page.id === `page-${target}`));
    });
  });
}

/* ---------- 页签 ---------- */
function setupTabs(): void {
  const tabs = Array.from(document.querySelectorAll<HTMLButtonElement>(".tabs__tab"));
  const panels = Array.from(document.querySelectorAll<HTMLElement>(".tabpanel"));

  tabs.forEach((tab) => {
    tab.addEventListener("click", () => {
      const target = tab.dataset.tab;
      if (!target) {
        return;
      }
      tabs.forEach((other) => {
        const active = other === tab;
        other.classList.toggle("is-active", active);
        other.setAttribute("aria-selected", active ? "true" : "false");
      });
      panels.forEach((panel) => panel.classList.toggle("is-active", panel.id === `tab-${target}`));
    });
  });
}

/* ---------- 远程协助 ---------- */
function setupAssistPage(): void {
  const passwordEl = byId<HTMLSpanElement>("temp-password");
  const toggleButton = byId<HTMLButtonElement>("toggle-password");
  const refreshButton = byId<HTMLButtonElement>("refresh-password");
  const refreshStatus = byId<HTMLSpanElement>("refresh-status");
  const copyCodeButton = byId<HTMLButtonElement>("copy-code");
  const copyShareButton = byId<HTMLButtonElement>("copy-share");
  const peerInput = byId<HTMLInputElement>("peer-code");
  const connectButton = byId<HTMLButtonElement>("connect-peer");
  const peerHint = document.createElement("span");
  peerHint.className = "field__hint";

  let revealed = false;
  let password = randomPassword(PASSWORD_LENGTH);
  let refreshStatusTimer = 0;

  // P3：刷新反馈写在按钮旁的状态元素，不动按钮内的 SVG 图标。
  const showRefreshStatus = (text: string): void => {
    refreshStatus.textContent = text;
    window.clearTimeout(refreshStatusTimer);
    refreshStatusTimer = window.setTimeout(() => {
      refreshStatus.textContent = "";
    }, 1600);
  };

  const renderPassword = (): void => {
    passwordEl.textContent = revealed ? password : "●".repeat(PASSWORD_LENGTH);
    passwordEl.dataset.revealed = revealed ? "true" : "false";
    toggleButton.title = revealed ? "隐藏密码" : "显示密码";
    toggleButton.setAttribute("aria-label", toggleButton.title);
  };

  renderPassword();

  toggleButton.addEventListener("click", () => {
    revealed = !revealed;
    renderPassword();
  });

  refreshButton.addEventListener("click", () => {
    password = randomPassword(PASSWORD_LENGTH);
    revealed = true;
    renderPassword();
    showRefreshStatus("已刷新");
  });

  copyCodeButton.addEventListener("click", () => {
    void copyText(DEVICE_CODE).then((ok) => {
      flashLabel(copyCodeButton, ok ? "已复制" : "复制失败");
    });
  });

  copyShareButton.addEventListener("click", () => {
    const text = `Vega 远程协助：设备码 ${DEVICE_CODE}，临时密码 ${password}`;
    void copyText(text).then((ok) => {
      copyShareButton.textContent = ok ? "已复制到剪贴板" : "复制失败";
      window.setTimeout(() => {
        copyShareButton.textContent = "复制并分享";
      }, 1400);
    });
  });

  peerInput.addEventListener("input", () => {
    const digits = peerInput.value.replace(/\D/g, "").slice(0, 9);
    const groups = digits.match(/.{1,3}/g) ?? [];
    peerInput.value = groups.join(" ");
  });

  connectButton.addEventListener("click", () => {
    const digits = peerInput.value.replace(/\D/g, "");
    peerHint.textContent =
      digits.length === 9
        ? `M2b 接入后发起会话：${peerInput.value}（静态界面，未发起网络请求）`
        : "请输入 9 位设备码";
    peerInput.insertAdjacentElement("afterend", peerHint);
  });
}

/* ---------- 我的设备 / 设置 ---------- */
function setupSettingsPage(): void {
  const testButton = byId<HTMLButtonElement>("test-connection");
  const testResult = byId<HTMLSpanElement>("test-connection-result");
  const runDoctorButton = byId<HTMLButtonElement>("run-doctor");
  const exportButton = byId<HTMLButtonElement>("export-log");
  const fixedPasswordButton = byId<HTMLButtonElement>("save-fixed-password");
  const fixedPasswordInput = byId<HTMLInputElement>("set-fixed-password");
  const trayCheckbox = byId<HTMLInputElement>("set-tray");

  // 关闭到托盘：默认开启，启动时把当前勾选状态交给 Rust，变更时再同步。
  syncCloseToTray(trayCheckbox.checked);
  trayCheckbox.addEventListener("change", () => {
    syncCloseToTray(trayCheckbox.checked);
  });

  testButton.addEventListener("click", () => {
    testResult.textContent = "静态界面：M2b 接入后由 Rust 侧探测（未发起网络请求）";
  });

  runDoctorButton.addEventListener("click", () => {
    flashLabel(runDoctorButton, "M2c 接入");
  });

  exportButton.addEventListener("click", () => {
    flashLabel(exportButton, "M2c 接入");
  });

  fixedPasswordButton.addEventListener("click", () => {
    const configured = fixedPasswordInput.value.length > 0;
    flashLabel(fixedPasswordButton, configured ? "已保存（占位）" : "已清空（占位）");
    fixedPasswordInput.value = "";
  });
}

/* ---------- 被控弹窗 / 浮条 ---------- */
function setupIncomingDialog(): void {
  const dialog = byId<HTMLDivElement>("incoming-dialog");
  const timer = byId<HTMLParagraphElement>("incoming-timer");
  const accept = byId<HTMLButtonElement>("incoming-accept");
  const reject = byId<HTMLButtonElement>("incoming-reject");

  let remaining = 60;
  let handle = 0;

  const stop = (): void => {
    if (handle !== 0) {
      window.clearInterval(handle);
      handle = 0;
    }
  };

  const close = (): void => {
    stop();
    dialog.classList.add("is-hidden");
  };

  accept.addEventListener("click", close);
  reject.addEventListener("click", close);

  if (dialog.classList.contains("is-hidden")) {
    return;
  }

  handle = window.setInterval(() => {
    remaining -= 1;
    timer.textContent = `${remaining} 秒后自动拒绝`;
    if (remaining <= 0) {
      close();
    }
  }, 1000);
}

/* ---------- 自绘标题栏 ---------- */
function setupWindowControls(): void {
  const current = window.__TAURI__?.window?.getCurrentWindow();
  const bind = (id: string, action: (win: TauriWindowHandle) => Promise<void>): void => {
    byId<HTMLButtonElement>(id).addEventListener("click", () => {
      if (!current) {
        return;
      }
      void action(current);
    });
  };

  bind("win-minimize", (win) => win.minimize());
  bind("win-maximize", (win) => win.toggleMaximize());
  bind("win-close", (win) => win.close());
}

function main(): void {
  setupNav();
  setupTabs();
  setupAssistPage();
  setupSettingsPage();
  setupIncomingDialog();
  setupWindowControls();
}

if (document.readyState === "loading") {
  document.addEventListener("DOMContentLoaded", main);
} else {
  main();
}

export {};
