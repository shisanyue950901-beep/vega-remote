// Vega 控制台 M2b：RustDesk 接入
// 约束：设备码/服务器配置来自 Rust 侧；密码永不进入前端与日志。
// 非 Tauri 环境（浏览器预览）下所有命令静默降级为「预览」提示。

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

interface DeviceInfo {
  installed: boolean;
  id: string;
  formattedId: string;
  path: string;
  error: string;
}

interface ServerConfigView {
  server: string;
  relay: string;
  keyFingerprint: string;
  keyPresent: boolean;
  path: string;
  error: string;
}

interface OpResult {
  ok: boolean;
  message: string;
}

interface StatusView {
  installed: boolean;
  running: boolean;
  serviceState: string;
  message: string;
}

interface TestResult {
  ok: boolean;
  message: string;
  latencyMs: number;
}

let currentDeviceCode = "";

function byId<T extends HTMLElement>(id: string): T {
  const el = document.getElementById(id);
  if (!el) {
    throw new Error(`找不到元素 #${id}`);
  }
  return el as T;
}

/** 调 Rust 命令；非 Tauri 环境或命令被拒时返回 null。 */
async function invoke<T>(cmd: string, args?: Record<string, unknown>): Promise<T | null> {
  const core = window.__TAURI__?.core;
  if (!core) {
    return null;
  }
  try {
    return await core.invoke<T>(cmd, args);
  } catch (error) {
    console.warn(`命令 ${cmd} 失败`, error);
    return null;
  }
}

function setStatus(el: HTMLElement, text: string, kind?: "ok" | "warn" | "error"): void {
  el.textContent = text;
  el.dataset.kind = kind ?? "";
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
  void invoke("set_close_to_tray", { enabled });
}

function flashLabel(button: HTMLButtonElement, text: string): void {
  const original = button.dataset.originalLabel ?? button.textContent ?? "";
  button.dataset.originalLabel = original;
  button.textContent = text;
  window.setTimeout(() => {
    button.textContent = original;
  }, 1600);
}

/** 设备码分组：9 位 3-3-3，10 位 3-3-4。 */
function formatDeviceCode(digits: string): string {
  const groups = digits.match(/.{1,3}/g) ?? [];
  return groups.join(" ");
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
  const codeEl = byId<HTMLSpanElement>("device-code");
  const codeStatus = byId<HTMLParagraphElement>("device-code-status");
  const copyCodeButton = byId<HTMLButtonElement>("copy-code");
  const copyShareButton = byId<HTMLButtonElement>("copy-share");
  const showPasswordButton = byId<HTMLButtonElement>("show-password");
  const passwordStatus = byId<HTMLSpanElement>("password-status");
  const idDot = byId<HTMLSpanElement>("id-dot");
  const idStatusText = byId<HTMLSpanElement>("id-status-text");
  const serviceStatusRow = byId<HTMLDivElement>("service-status");
  const serviceDot = byId<HTMLSpanElement>("service-dot");
  const serviceStatusText = byId<HTMLSpanElement>("service-status-text");
  const installButton = byId<HTMLButtonElement>("install-rustdesk");
  const peerInput = byId<HTMLInputElement>("peer-code");
  const recentList = byId<HTMLDataListElement>("recent-devices");
  const connectButton = byId<HTMLButtonElement>("connect-peer");
  const connectStatus = byId<HTMLSpanElement>("connect-status");

  const renderRecents = (ids: string[]): void => {
    recentList.innerHTML = "";
    ids.forEach((id) => {
      const option = document.createElement("option");
      option.value = formatDeviceCode(id);
      recentList.append(option);
    });
  };

  const loadRecents = (): void => {
    void invoke<string[]>("get_recent_peers").then((ids) => {
      if (ids) {
        renderRecents(ids);
      }
    });
  };

  const loadDeviceCode = (): void => {
    codeStatus.textContent = "";
    void invoke<DeviceInfo>("get_device_id").then((info) => {
      if (!info) {
        codeEl.textContent = "预览模式";
        setStatus(codeStatus, "浏览器预览：未连接 Tauri，命令不可用", "warn");
        return;
      }
      currentDeviceCode = info.formattedId;
      if (info.installed && info.formattedId) {
        codeEl.textContent = info.formattedId;
        setStatus(codeStatus, `来自 ${info.path}`, "ok");
      } else {
        codeEl.textContent = "—";
        setStatus(codeStatus, info.error || "未安装 RustDesk", "error");
      }
    });
  };

  const loadStatus = (): void => {
    void invoke<StatusView>("get_rustdesk_status").then((status) => {
      if (!status) {
        return;
      }
      serviceStatusRow.classList.remove("is-hidden");
      serviceStatusText.textContent = status.message;
      serviceDot.classList.toggle("dot--ok", status.running);
      serviceDot.classList.toggle("dot--off", !status.running);
      installButton.classList.toggle("is-hidden", status.installed);
    });

    void invoke<ServerConfigView>("get_server_config").then((config) => {
      if (!config) {
        idStatusText.textContent = "预览模式：无法读取 RustDesk 配置";
        idDot.className = "dot dot--off";
        return;
      }
      const server = config.server || "未配置";
      const key = config.keyFingerprint ? ` · 公钥 ${config.keyFingerprint}…` : " · 无公钥";
      idStatusText.textContent = config.error
        ? `ID 服务器：${config.error}`
        : `ID 服务器 ${server}${key}`;
      idDot.className = `dot ${config.error ? "dot--off" : "dot--ok"}`;
    });
  };

  copyCodeButton.addEventListener("click", () => {
    if (!currentDeviceCode) {
      flashLabel(copyCodeButton, "暂无设备码");
      return;
    }
    void copyText(currentDeviceCode).then((ok) => {
      flashLabel(copyCodeButton, ok ? "已复制" : "复制失败");
    });
  });

  copyShareButton.addEventListener("click", () => {
    if (!currentDeviceCode) {
      copyShareButton.textContent = "暂无设备码";
      window.setTimeout(() => {
        copyShareButton.textContent = "复制并分享";
      }, 1600);
      return;
    }
    const text = `Vega 远程协助：设备码 ${currentDeviceCode}。临时密码请在 RustDesk 主窗口查看（我不读取它）。`;
    void copyText(text).then((ok) => {
      copyShareButton.textContent = ok ? "已复制到剪贴板" : "复制失败";
      window.setTimeout(() => {
        copyShareButton.textContent = "复制并分享";
      }, 1600);
    });
  });

  showPasswordButton.addEventListener("click", () => {
    setStatus(passwordStatus, "正在打开 RustDesk…");
    void invoke<OpResult>("open_rustdesk_window").then((result) => {
      if (!result) {
        setStatus(passwordStatus, "浏览器预览：命令不可用", "warn");
        return;
      }
      setStatus(passwordStatus, result.message, result.ok ? "ok" : "error");
    });
  });

  installButton.addEventListener("click", () => {
    setStatus(serviceStatusText, "正在请求管理员授权…");
    void invoke<OpResult>("install_rustdesk").then((result) => {
      if (!result) {
        setStatus(serviceStatusText, "浏览器预览：命令不可用", "warn");
        return;
      }
      setStatus(serviceStatusText, result.message, result.ok ? "ok" : "error");
    });
  });

  peerInput.addEventListener("input", () => {
    const digits = peerInput.value.replace(/\D/g, "").slice(0, 10);
    peerInput.value = formatDeviceCode(digits);
  });

  connectButton.addEventListener("click", () => {
    const digits = peerInput.value.replace(/\D/g, "");
    if (digits.length !== 9 && digits.length !== 10) {
      setStatus(connectStatus, "请输入 9-10 位设备码", "error");
      return;
    }
    const mode =
      document.querySelector<HTMLInputElement>('input[name="connect-mode"]:checked')?.value ??
      "control";
    setStatus(connectStatus, "正在发起连接…");
    connectButton.disabled = true;
    void invoke<OpResult>("connect_peer", { peerId: digits, mode }).then((result) => {
      connectButton.disabled = false;
      if (!result) {
        setStatus(connectStatus, "浏览器预览：命令不可用", "warn");
        return;
      }
      setStatus(connectStatus, result.message, result.ok ? "ok" : "error");
      if (result.ok) {
        loadRecents();
      }
    });
  });

  loadDeviceCode();
  loadStatus();
  loadRecents();
}

/* ---------- 设置 ---------- */
function setupSettingsPage(): void {
  const testButton = byId<HTMLButtonElement>("test-connection");
  const testResult = byId<HTMLSpanElement>("test-connection-result");
  const saveButton = byId<HTMLButtonElement>("save-network");
  const networkStatus = byId<HTMLSpanElement>("network-status");
  const idServerInput = byId<HTMLInputElement>("set-id-server");
  const relayServerInput = byId<HTMLInputElement>("set-relay-server");
  const keyInput = byId<HTMLTextAreaElement>("set-server-key");
  const fingerprint = byId<HTMLSpanElement>("server-key-fingerprint");
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

  const loadNetwork = (): void => {
    setStatus(networkStatus, "正在读取 RustDesk 配置…");
    void invoke<ServerConfigView>("get_server_config").then((config) => {
      if (!config) {
        setStatus(networkStatus, "浏览器预览：未连接 Tauri，命令不可用", "warn");
        return;
      }
      idServerInput.value = config.server;
      relayServerInput.value = config.relay;
      keyInput.value = "";
      if (config.keyPresent) {
        fingerprint.textContent = `${config.keyFingerprint}…（完整公钥不回显）`;
      } else {
        fingerprint.textContent = config.error || "未设置";
      }
      setStatus(networkStatus, config.error ? config.error : `配置文件：${config.path}`, config.error ? "warn" : "ok");
    });
  };

  saveButton.addEventListener("click", () => {
    const server = idServerInput.value.trim();
    const relay = relayServerInput.value.trim();
    const key = keyInput.value.trim();
    setStatus(networkStatus, "正在保存…");
    saveButton.disabled = true;
    void invoke<OpResult>("set_server_config", { server, key, relay }).then((result) => {
      saveButton.disabled = false;
      if (!result) {
        setStatus(networkStatus, "浏览器预览：命令不可用", "warn");
        return;
      }
      setStatus(networkStatus, result.message, result.ok ? "ok" : "error");
      if (result.ok) {
        keyInput.value = "";
        loadNetwork();
      }
    });
  });

  testButton.addEventListener("click", () => {
    const server = idServerInput.value.trim();
    if (!server) {
      setStatus(testResult, "先填 ID 服务器", "error");
      return;
    }
    setStatus(testResult, "正在连接 21116…");
    testButton.disabled = true;
    void invoke<TestResult>("test_server_connection", { server }).then((result) => {
      testButton.disabled = false;
      if (!result) {
        setStatus(testResult, "浏览器预览：命令不可用", "warn");
        return;
      }
      const text = result.ok
        ? `连接成功，${result.latencyMs} ms（${result.message}）`
        : `连接失败：${result.message}`;
      setStatus(testResult, text, result.ok ? "ok" : "error");
    });
  });

  runDoctorButton.addEventListener("click", () => {
    flashLabel(runDoctorButton, "M2c 接入");
  });

  exportButton.addEventListener("click", () => {
    flashLabel(exportButton, "M2c 接入");
  });

  fixedPasswordButton.addEventListener("click", () => {
    const configured = fixedPasswordInput.value.length > 0;
    flashLabel(fixedPasswordButton, configured ? "请在 RustDesk 里设置" : "请在 RustDesk 里清除");
    fixedPasswordInput.value = "";
  });

  loadNetwork();
}

/* ---------- 我的设备：配对输入框（M2a r2 遗留） ---------- */
function setupPairing(): void {
  const openPairing = byId<HTMLButtonElement>("sunshine-pair");
  const pinInput = byId<HTMLInputElement>("sunshine-pin");
  const pinSubmit = byId<HTMLButtonElement>("sunshine-pin-submit");
  let opened = false;

  const setOpened = (value: boolean): void => {
    opened = value;
    pinInput.classList.toggle("is-hidden", !value);
    pinSubmit.classList.toggle("is-hidden", !value);
    openPairing.textContent = value ? "收起配对" : "打开配对";
    if (value) {
      pinInput.focus();
    }
  };

  openPairing.addEventListener("click", () => {
    setOpened(!opened);
  });

  pinInput.addEventListener("input", () => {
    pinInput.value = pinInput.value.replace(/\D/g, "").slice(0, 4);
  });

  pinSubmit.addEventListener("click", () => {
    if (pinInput.value.length !== 4) {
      flashLabel(pinSubmit, "PIN 需 4 位");
      return;
    }
    flashLabel(pinSubmit, "M2c 接入");
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
  setupPairing();
  setupIncomingDialog();
  setupWindowControls();
}

if (document.readyState === "loading") {
  document.addEventListener("DOMContentLoaded", main);
} else {
  main();
}

export {};
