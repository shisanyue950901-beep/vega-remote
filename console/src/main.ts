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
  /** 公钥存在但格式无效；非空时只显示通用文案，不展示值。 */
  keyError: string;
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

interface GpuInfo {
  name: string;
  kind: string;
  encoder: string;
  memoryMb: number;
}

interface StreamingStatus {
  sunshineState: string;
  sunshineLabel: string;
  gpus: GpuInfo[];
  moonlightInstalled: boolean;
  moonlightError: string;
  hostInstallCommand: string;
  clientInstallCommand: string;
}

interface DoctorItem {
  item: string;
  status: string;
  advice: string;
}

let currentDeviceCode = "";

/** 串流页与 doctor 的跨区动作；由各自 setup 设置。 */
let refreshStreaming: (() => void) | null = null;
let refreshAssistDevice: (() => void) | null = null;
let refreshAssistStatus: (() => void) | null = null;
let runDoctorAction: (() => void) | null = null;

/** 设置页与远程协助页共用同一份配置快照，避免 focus 时各读一遍。 */
type ConfigHandler = (config: ServerConfigView | null) => void;
const configHandlers: ConfigHandler[] = [];
let configRefreshInFlight = false;

async function refreshSharedConfig(): Promise<void> {
  if (configRefreshInFlight) {
    return;
  }
  configRefreshInFlight = true;
  let config: ServerConfigView | null = null;
  try {
    config = await invoke<ServerConfigView>("get_server_config");
  } catch {
    // 读取失败也要通知每个页面：旧快照可能已经不成立，不能继续拿来测试。
    config = null;
  } finally {
    configRefreshInFlight = false;
  }
  for (const handler of configHandlers) {
    handler(config);
  }
}

async function refreshOnFocus(): Promise<void> {
  await refreshSharedConfig();
  // 从 RustDesk 安装/改配置回来时，设备码与安装状态也要跟着重查。
  refreshAssistDevice?.();
  refreshAssistStatus?.();
  refreshStreaming?.();
}

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
function navigateTo(page: string): void {
  const items = Array.from(document.querySelectorAll<HTMLButtonElement>(".nav__item"));
  const pages = Array.from(document.querySelectorAll<HTMLElement>(".page"));
  items.forEach((item) => item.classList.toggle("is-active", item.dataset.page === page));
  pages.forEach((target) => target.classList.toggle("is-active", target.id === `page-${page}`));
}

function setupNav(): void {
  const items = Array.from(document.querySelectorAll<HTMLButtonElement>(".nav__item"));
  items.forEach((item) => {
    item.addEventListener("click", () => {
      const target = item.dataset.page;
      if (target) {
        navigateTo(target);
      }
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
  const idTestButton = byId<HTMLButtonElement>("id-test");
  let configuredServer = "";
  // 探测代次：读配置或发起新探测都会 +1；过期结果（地址或代次变了）直接丢弃，
  // 避免旧地址的结论被贴到刚切换的新服务器上。
  let probeGeneration = 0;
  const serviceStatusRow = byId<HTMLDivElement>("service-status");
  const serviceDot = byId<HTMLSpanElement>("service-dot");
  const serviceStatusText = byId<HTMLSpanElement>("service-status-text");
  const openInstallPageButton = byId<HTMLButtonElement>("open-install-page");
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

  const applyServerConfig = (config: ServerConfigView | null): void => {
    // 先清掉上一次的探测结论，并作废在途探测：RustDesk 里改完地址后
    // 旧地址的绿点不能留着。
    probeGeneration += 1;
    configuredServer = "";
    idTestButton.classList.add("is-hidden");
    idTestButton.disabled = false;
    idDot.className = "dot dot--off";
    if (!config) {
      idStatusText.textContent = "预览模式：无法读取 RustDesk 配置";
      return;
    }
    const server = config.server.trim();
    configuredServer = server;
    const key = config.keyError
      ? " · 公钥格式无效"
      : config.keyFingerprint
        ? ` · 公钥 ${config.keyFingerprint}…`
        : " · 无公钥";
    // 绿点只代表「已配置且测试连通」；读到了空白地址或还没测连通性时
    // 分别显示未配置 / 待测试，不能拿「TOML 解析成功」冒充在线。
    if (config.error) {
      idStatusText.textContent = `ID 服务器：${config.error}`;
    } else if (!server) {
      idStatusText.textContent = "ID 服务器未配置（在 RustDesk 的 设置 → 网络 中填写）";
    } else {
      idStatusText.textContent = `ID 服务器已配置 ${server}${key}（尚未测试连通性）`;
      idDot.className = "dot dot--busy";
      idTestButton.classList.remove("is-hidden");
    }
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
      openInstallPageButton.classList.toggle("is-hidden", status.installed);
      installHint.classList.toggle("is-hidden", status.installed);
    });
  };

  idTestButton.addEventListener("click", () => {
    const testedServer = configuredServer;
    if (!testedServer) {
      return;
    }
    const generation = ++probeGeneration;
    idTestButton.disabled = true;
    idStatusText.textContent = `正在测试 ${testedServer}:21116…`;
    void invoke<TestResult>("test_server_connection", { server: testedServer }).then((result) => {
      // 回包晚于地址变更（重读配置或再次点击）就丢掉：绿点只能代表当前地址。
      if (generation !== probeGeneration || testedServer !== configuredServer) {
        return;
      }
      idTestButton.disabled = false;
      if (!result) {
        idStatusText.textContent = "预览模式：命令不可用";
        idDot.className = "dot dot--off";
        return;
      }
      idStatusText.textContent = result.ok
        ? `ID 服务器 ${testedServer} 连接成功（${result.latencyMs} ms）`
        : `ID 服务器 ${testedServer} 连接失败：${result.message}`;
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

  openInstallPageButton.addEventListener("click", () => {
    // WinGet 已下架 RustDesk：不再复制安装命令，交给 Rust 侧用默认浏览器
    // 打开写死的官方发行页，由用户手动安装。
    setStatus(serviceStatusText, "正在打开 RustDesk 官方下载页…");
    void invoke<OpResult>("open_rustdesk_download_page").then((result) => {
      if (!result) {
        setStatus(serviceStatusText, "浏览器预览：命令不可用", "warn");
        return;
      }
      setStatus(serviceStatusText, result.message, result.ok ? "ok" : "error");
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

  configHandlers.push(applyServerConfig);
  refreshAssistDevice = loadDeviceCode;
  refreshAssistStatus = loadStatus;
  loadDeviceCode();
  loadStatus();
  loadRecents();
}

/* ---------- 设置 ---------- */
function setupSettingsPage(): void {
  const testButton = byId<HTMLButtonElement>("test-connection");
  const testResult = byId<HTMLSpanElement>("test-connection-result");
  const openRustdeskNetworkButton = byId<HTMLButtonElement>("open-rustdesk-network");
  const networkStatus = byId<HTMLSpanElement>("network-status");
  const idServerInput = byId<HTMLInputElement>("set-id-server");
  const relayServerInput = byId<HTMLInputElement>("set-relay-server");
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

  // 只读页：配置只显示 RustDesk2.toml 里的当前值，写入一律在 RustDesk 里做。
  let probeGeneration = 0;

  const applyConfig = (config: ServerConfigView | null): void => {
    // 每次重读配置都作废在途探测，并把上一次的结果与按钮状态复位。
    // 旧回调只认自己的代次，不能把按钮永久留在 disabled（审计 r5 P2）。
    probeGeneration += 1;
    testButton.disabled = true;
    setStatus(testResult, "未测试");
    if (!config) {
      // 刷新失败：旧地址不能留在页面上，更不能拿旧地址去测试（审计 P2）。
      idServerInput.value = "";
      relayServerInput.value = "";
      fingerprint.textContent = "—";
      testButton.disabled = true;
      setStatus(networkStatus, "读取 RustDesk 配置失败：请重新打开设置页", "error");
      return;
    }
    idServerInput.value = config.server;
    relayServerInput.value = config.relay;
    if (config.keyError) {
      fingerprint.textContent = config.keyError;
    } else if (config.keyPresent) {
      fingerprint.textContent = `${config.keyFingerprint}…（完整公钥不回显）`;
    } else {
      fingerprint.textContent = config.error || "未设置";
    }
    setStatus(networkStatus, config.error ? config.error : `配置文件：${config.path}`, config.error ? "warn" : "ok");
    // 只有当最新快照里确实有地址时才允许测试。
    testButton.disabled = config.server.trim() === "";
  };

  configHandlers.push(applyConfig);

  // 修改入口：打开 RustDesk 主窗口，让用户在「设置 → 网络」里改。
  openRustdeskNetworkButton.addEventListener("click", () => {
    setStatus(networkStatus, "正在打开 RustDesk…");
    void invoke<OpResult>("open_rustdesk_window").then((result) => {
      if (!result) {
        setStatus(networkStatus, "浏览器预览：命令不可用", "warn");
        return;
      }
      setStatus(
        networkStatus,
        result.ok ? "已打开 RustDesk，请在 设置 → 网络 中修改服务器地址" : result.message,
        result.ok ? "ok" : "error",
      );
    });
  });

  testButton.addEventListener("click", () => {
    const testedServer = idServerInput.value.trim();
    if (!testedServer) {
      setStatus(testResult, "还没有读到 ID 服务器地址", "error");
      return;
    }
    const generation = ++probeGeneration;
    setStatus(testResult, "正在连接 21116…");
    testButton.disabled = true;
    void invoke<TestResult>("test_server_connection", { server: testedServer }).then((result) => {
      // 地址或代次变了就丢结果；按钮由最新一次 applyConfig 恢复，
      // 这里不再碰 disabled，避免和刷新流程抢状态。
      if (generation !== probeGeneration || testedServer !== idServerInput.value.trim()) {
        return;
      }
      testButton.disabled = idServerInput.value.trim() === "";
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

  const doctorResults = byId<HTMLUListElement>("doctor-results");
  const doctorStatus = byId<HTMLSpanElement>("doctor-status");

  const renderDoctor = (items: DoctorItem[]): void => {
    doctorResults.innerHTML = "";
    if (items.length === 0) {
      const empty = document.createElement("li");
      empty.className = "doctor__item";
      empty.textContent = "没有诊断结果";
      doctorResults.append(empty);
      return;
    }
    for (const entry of items) {
      const row = document.createElement("li");
      const modifier =
        entry.status === "通过" ? "pass" : entry.status === "警告" ? "warn" : "fail";
      const tagClass =
        entry.status === "通过" ? "tag--ok" : entry.status === "警告" ? "tag--warn" : "tag--fail";
      row.className = `doctor__item doctor__item--${modifier}`;
      const tag = document.createElement("span");
      tag.className = `tag ${tagClass}`;
      tag.textContent = entry.status;
      row.append(tag);
      const text = document.createElement("span");
      text.textContent = entry.advice ? `${entry.item}：${entry.advice}` : entry.item;
      row.append(text);
      doctorResults.append(row);
    }
  };

  const runDoctor = (): void => {
    runDoctorButton.disabled = true;
    setStatus(doctorStatus, "正在诊断（最多 8 秒）…");
    void invoke<DoctorItem[]>("run_doctor").then((items) => {
      runDoctorButton.disabled = false;
      if (!items) {
        setStatus(doctorStatus, "浏览器预览：命令不可用", "warn");
        return;
      }
      renderDoctor(items);
      setStatus(doctorStatus, `诊断完成：${items.length} 项`, "ok");
    });
  };
  runDoctorAction = runDoctor;
  runDoctorButton.addEventListener("click", runDoctor);

  exportButton.addEventListener("click", () => {
    exportButton.disabled = true;
    setStatus(doctorStatus, "正在导出脱敏日志…");
    void invoke<OpResult>("export_doctor_log").then((result) => {
      exportButton.disabled = false;
      if (!result) {
        setStatus(doctorStatus, "浏览器预览：命令不可用", "warn");
        return;
      }
      setStatus(doctorStatus, result.message, result.ok ? "ok" : "error");
    });
  });

  fixedPasswordButton.addEventListener("click", () => {
    const configured = fixedPasswordInput.value.length > 0;
    flashLabel(fixedPasswordButton, configured ? "请在 RustDesk 里设置" : "请在 RustDesk 里清除");
    fixedPasswordInput.value = "";
  });
}

/* ---------- 我的设备：高性能串流 ---------- */
function setupStreamingPage(): void {
  const sunshineTag = byId<HTMLSpanElement>("sunshine-tag");
  const gpuList = byId<HTMLUListElement>("gpu-list");
  const sunshineStatus = byId<HTMLSpanElement>("sunshine-status");
  const pairingButton = byId<HTMLButtonElement>("sunshine-pair");
  const settingsButton = byId<HTMLButtonElement>("sunshine-settings");
  const installButton = byId<HTMLButtonElement>("sunshine-install");
  const moonlightTag = byId<HTMLSpanElement>("moonlight-tag");
  const moonlightStart = byId<HTMLButtonElement>("moonlight-start");
  const moonlightInstall = byId<HTMLButtonElement>("moonlight-install");
  const moonlightStatus = byId<HTMLSpanElement>("moonlight-status");
  const diagnoseButton = byId<HTMLButtonElement>("diagnose-net");

  const setTag = (el: HTMLSpanElement, text: string, kind: "ok" | "warn" | "fail"): void => {
    el.textContent = text;
    el.className = `tag tag--${kind}`;
  };

  const renderGpus = (gpus: GpuInfo[]): void => {
    gpuList.innerHTML = "";
    if (gpus.length === 0) {
      const empty = document.createElement("li");
      empty.className = "field__hint";
      empty.textContent = "未识别到可用于编码的显卡";
      gpuList.append(empty);
      return;
    }
    for (const gpu of gpus) {
      const row = document.createElement("li");
      row.className = "gpu";
      const name = document.createElement("span");
      name.className = "gpu__name";
      name.textContent = gpu.name;
      const meta = document.createElement("span");
      meta.className = "field__hint";
      const memory = gpu.memoryMb > 0 ? ` · 显存 ${gpu.memoryMb} MB` : "";
      meta.textContent = `${gpu.kind} · 编码器 ${gpu.encoder}${memory}`;
      row.append(name, meta);
      gpuList.append(row);
    }
  };

  let status: StreamingStatus | null = null;

  const renderStatus = (value: StreamingStatus): void => {
    status = value;
    if (value.sunshineState === "running") {
      setTag(sunshineTag, `Sunshine ${value.sunshineLabel}`, "ok");
    } else if (value.sunshineState === "notInstalled" || value.sunshineState === "unknown") {
      setTag(sunshineTag, `Sunshine ${value.sunshineLabel}`, "fail");
    } else {
      setTag(sunshineTag, `Sunshine ${value.sunshineLabel}`, "warn");
    }
    renderGpus(value.gpus);
    setTag(moonlightTag, value.moonlightInstalled ? "Moonlight 已安装" : "Moonlight 未安装", value.moonlightInstalled ? "ok" : "warn");
    moonlightStart.disabled = !value.moonlightInstalled;
    if (value.moonlightError) {
      setStatus(moonlightStatus, value.moonlightError, "warn");
    } else if (value.moonlightInstalled) {
      setStatus(moonlightStatus, "在 Moonlight 中选择已配对主机", "ok");
    } else {
      setStatus(moonlightStatus, "安装后点「开始串流」，在 Moonlight 里添加已配对主机", "warn");
    }
  };

  const load = (): void => {
    void invoke<StreamingStatus>("get_streaming_status").then((value) => {
      if (!value) {
        setTag(sunshineTag, "预览模式", "warn");
        setTag(moonlightTag, "预览模式", "warn");
        return;
      }
      renderStatus(value);
    });
  };
  refreshStreaming = load;

  const copyInstallCommand = (command: string, statusEl: HTMLSpanElement, what: string): void => {
    void copyText(command).then((ok) => {
      setStatus(
        statusEl,
        ok
          ? `${what}安装命令已复制，请在管理员 PowerShell 中运行（会同时配置防火墙）`
          : "复制失败，请手动从 README 复制安装命令",
        ok ? "ok" : "error",
      );
    });
  };

  installButton.addEventListener("click", () => {
    if (!status) {
      setStatus(sunshineStatus, "还在读取串流状态，请稍后重试", "warn");
      return;
    }
    copyInstallCommand(status.hostInstallCommand, sunshineStatus, "Sunshine ");
  });

  pairingButton.addEventListener("click", () => {
    setStatus(sunshineStatus, "正在打开 Sunshine 配对页…");
    void invoke<OpResult>("open_sunshine_pairing").then((result) => {
      setStatus(
        sunshineStatus,
        result ? result.message : "浏览器预览：命令不可用",
        result && result.ok ? "ok" : "error",
      );
    });
  });

  settingsButton.addEventListener("click", () => {
    setStatus(sunshineStatus, "正在打开 Sunshine 设置页…");
    void invoke<OpResult>("open_sunshine_settings").then((result) => {
      setStatus(
        sunshineStatus,
        result ? result.message : "浏览器预览：命令不可用",
        result && result.ok ? "ok" : "error",
      );
    });
  });

  moonlightStart.addEventListener("click", () => {
    setStatus(moonlightStatus, "正在打开 Moonlight…");
    void invoke<OpResult>("start_moonlight_stream").then((result) => {
      setStatus(
        moonlightStatus,
        result ? result.message : "浏览器预览：命令不可用",
        result && result.ok ? "ok" : "error",
      );
    });
  });

  moonlightInstall.addEventListener("click", () => {
    if (!status) {
      setStatus(moonlightStatus, "还在读取串流状态，请稍后重试", "warn");
      return;
    }
    copyInstallCommand(status.clientInstallCommand, moonlightStatus, "Moonlight ");
  });

  // 诊断网络：跳到设置页的诊断卡片并立刻运行 doctor。
  diagnoseButton.addEventListener("click", () => {
    navigateTo("settings");
    byId<HTMLDivElement>("doctor-card").scrollIntoView({ behavior: "smooth", block: "start" });
    runDoctorAction?.();
  });

  load();
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
  setupStreamingPage();
  setupIncomingDialog();
  setupWindowControls();

  // 两页共用一份配置快照；启动时读一次，focus 时再刷新并复查设备码/安装状态。
  void refreshSharedConfig();
  window.addEventListener("focus", () => {
    void refreshOnFocus();
  });
}

if (document.readyState === "loading") {
  document.addEventListener("DOMContentLoaded", main);
} else {
  main();
}

export {};
