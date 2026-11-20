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
  /** RustDesk 以 Windows 服务运行：配置要在 RustDesk 里改，用户 TOML 不生效。 */
  serviceMode: boolean;
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

/**
 * RustDesk-only 安装命令。控制台只复制这一行，不在应用内提权或执行脚本；
 * 不再走通用 bootstrap（那会按角色装一堆无关组件却可能漏掉 RustDesk）。
 */
const INSTALL_COMMAND =
  "winget install --id RustDesk.RustDesk --exact --source winget";

/**
 * 设备码解析：只接受 9/10 位纯数字，或控制台自己展示的 3-3-3 / 3-3-4 分组
 * （空格或连字符，整串分隔符必须一致）。返回纯数字，供 IPC 使用。
 * 不做「删掉多余字符」式清洗：粘错的码会被拒绝，而不是被改成另一台设备。
 */
export function parsePeerId(raw: string): string | null {
  const value = raw.trim();
  if (!value) {
    return null;
  }
  if (/^\d+$/.test(value)) {
    return value.length === 9 || value.length === 10 ? value : null;
  }
  const sep = value.includes("-") ? "-" : value.includes(" ") ? " " : null;
  if (!sep) {
    return null;
  }
  const groups = value.split(sep);
  if (groups.length !== 3) {
    return null;
  }
  if (!groups.every((group) => /^\d+$/.test(group))) {
    return null;
  }
  if (groups[0].length !== 3 || groups[1].length !== 3) {
    return null;
  }
  if (groups[2].length !== 3 && groups[2].length !== 4) {
    return null;
  }
  return groups.join("");
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

/**
 * 设备码分组：9 位 3-3-3，10 位 3-3-4。
 * 不能用 `.{1,3}` 硬切：10 位会被切成 3-3-3-1，parsePeerId 不认。
 * 与 Rust 侧 format_device_id 保持一致。
 */
export function formatDeviceCode(digits: string): string {
  const value = digits.trim();
  if (/^\d{9}$/.test(value)) {
    return `${value.slice(0, 3)} ${value.slice(3, 6)} ${value.slice(6, 9)}`;
  }
  if (/^\d{10}$/.test(value)) {
    return `${value.slice(0, 3)} ${value.slice(3, 6)} ${value.slice(6)}`;
  }
  return value;
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

/**
 * 设置页保存网络后调用：让远程协助页重读服务器并清掉旧探测结果。
 * 由 setupAssistPage 在启动时注册，避免设置页直接摸另一个页面的闭包。
 */
let refreshAssistServer: (() => void) | null = null;

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
  const idTestButton = byId<HTMLButtonElement>("id-test");
  let configuredServer = "";
  const serviceStatusRow = byId<HTMLDivElement>("service-status");
  const serviceDot = byId<HTMLSpanElement>("service-dot");
  const serviceStatusText = byId<HTMLSpanElement>("service-status-text");
  const copyInstallButton = byId<HTMLButtonElement>("copy-install-command");
  const installHint = byId<HTMLSpanElement>("install-hint");
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

  const loadServerConfig = (): void => {
    // 先清掉上一次的探测结论：设置页保存后旧地址的绿点不能留着。
    configuredServer = "";
    idTestButton.classList.add("is-hidden");
    idTestButton.disabled = false;
    idDot.className = "dot dot--off";
    idStatusText.textContent = "正在读取 ID 服务器配置…";
    void invoke<ServerConfigView>("get_server_config").then((config) => {
      if (!config) {
        idStatusText.textContent = "预览模式：无法读取 RustDesk 配置";
        idDot.className = "dot dot--off";
        return;
      }
      const server = config.server.trim();
      configuredServer = server;
      const key = config.keyFingerprint ? ` · 公钥 ${config.keyFingerprint}…` : " · 无公钥";
      // 绿点只代表「已配置且测试连通」；读到了空白地址或还没测连通性时
      // 分别显示未配置 / 待测试，不能拿「TOML 解析成功」冒充在线。
      if (config.error) {
        idStatusText.textContent = `ID 服务器：${config.error}`;
        idDot.className = "dot dot--off";
      } else if (!server) {
        idStatusText.textContent = "ID 服务器未配置（设置页可填写）";
        idDot.className = "dot dot--off";
      } else {
        idStatusText.textContent = `ID 服务器已配置 ${server}${key}（尚未测试连通性）`;
        idDot.className = "dot dot--busy";
        idTestButton.classList.remove("is-hidden");
      }
    });
  };
  refreshAssistServer = loadServerConfig;

  const loadStatus = (): void => {
    void invoke<StatusView>("get_rustdesk_status").then((status) => {
      if (!status) {
        return;
      }
      serviceStatusRow.classList.remove("is-hidden");
      serviceStatusText.textContent = status.message;
      serviceDot.classList.toggle("dot--ok", status.running);
      serviceDot.classList.toggle("dot--off", !status.running);
      copyInstallButton.classList.toggle("is-hidden", status.installed);
      installHint.classList.toggle("is-hidden", status.installed);
    });

    loadServerConfig();
  };

  idTestButton.addEventListener("click", () => {
    if (!configuredServer) {
      return;
    }
    idTestButton.disabled = true;
    idStatusText.textContent = `正在测试 ${configuredServer}:21116…`;
    void invoke<TestResult>("test_server_connection", { server: configuredServer }).then((result) => {
      idTestButton.disabled = false;
      if (!result) {
        idStatusText.textContent = "预览模式：命令不可用";
        idDot.className = "dot dot--off";
        return;
      }
      idStatusText.textContent = result.ok
        ? `ID 服务器 ${configuredServer} 连接成功（${result.latencyMs} ms）`
        : `ID 服务器 ${configuredServer} 连接失败：${result.message}`;
      idDot.className = `dot ${result.ok ? "dot--ok" : "dot--off"}`;
    });
  });

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

  copyInstallButton.addEventListener("click", () => {
    // 不再在应用内 runas 提权执行脚本：只把 README 的一行命令塞进剪贴板，
    // 由用户自己在管理员 PowerShell 里确认后运行。
    void copyText(INSTALL_COMMAND).then((ok) => {
      flashLabel(copyInstallButton, ok ? "已复制" : "复制失败");
      setStatus(
        serviceStatusText,
        ok ? "已复制安装命令，请在管理员 PowerShell 中运行" : "复制失败，请到 README 手动复制安装命令",
        ok ? "ok" : "error",
      );
    });
  });

  peerInput.addEventListener("input", () => {
    // 只提示、不悄悄删字符或截断：粘错的码必须显示原因，不能被改成另一台设备。
    if (peerInput.value.trim() === "") {
      setStatus(connectStatus, "");
      return;
    }
    if (parsePeerId(peerInput.value) === null) {
      setStatus(
        connectStatus,
        "设备码格式：123456789 / 123 456 789 / 123-456-789（9-10 位）",
        "error",
      );
      return;
    }
    setStatus(connectStatus, "");
  });

  connectButton.addEventListener("click", () => {
    const digits = parsePeerId(peerInput.value);
    if (digits === null) {
      setStatus(connectStatus, "请输入 9-10 位设备码（可带空格或连字符分组）", "error");
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
  const openRustdeskNetworkButton = byId<HTMLButtonElement>("open-rustdesk-network");
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
    openRustdeskNetworkButton.classList.add("is-hidden");
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
      if (result.serviceMode) {
        // 服务模式：用户 TOML 不是生效配置，不假装保存成功；
        // 指向 RustDesk 自己的「网络」设置，并给出打开窗口的按钮。
        setStatus(networkStatus, result.message, "warn");
        openRustdeskNetworkButton.classList.remove("is-hidden");
        return;
      }
      openRustdeskNetworkButton.classList.add("is-hidden");
      setStatus(networkStatus, result.message, result.ok ? "ok" : "error");
      if (result.ok) {
        keyInput.value = "";
        setStatus(testResult, "未测试");
        loadNetwork();
        // 远程协助页重读新服务器并丢掉旧地址的探测结论。
        refreshAssistServer?.();
      }
    });
  });

  openRustdeskNetworkButton.addEventListener("click", () => {
    void invoke<OpResult>("open_rustdesk_window").then((result) => {
      if (!result) {
        setStatus(networkStatus, "浏览器预览：命令不可用", "warn");
        return;
      }
      setStatus(networkStatus, result.message, result.ok ? "ok" : "error");
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
