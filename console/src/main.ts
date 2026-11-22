// Vega 控制台 T4：设备列表、长期密码与验证方式接入
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

/** 安装包随包的默认中继（`vega-defaults.json`），只读展示。 */
interface RelayDefaultsView {
  idServer: string;
  relayServer: string;
  keyPresent: boolean;
  /** 公钥摘要（前 8 位），用于和 RustDesk 实际配置比对，不回显完整公钥。 */
  keyFingerprint: string;
  path: string;
  error: string;
}

/** 设置页「手机扫码配置」：只给矩阵与指纹，完整公钥只在二维码内容里。 */
interface MobileQrView {
  size: number;
  modules: boolean[];
  server: string;
  keyFingerprint: string;
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

/** `run_doctor` 的返回值：本次结果 + 快照编号 + 本次是否产出快照。 */
interface DoctorReport {
  snapshotId: number;
  snapshotAvailable: boolean;
  items: DoctorItem[];
}

let currentDeviceCode = "";

/** 串流页与 doctor 的跨区动作；由各自 setup 设置。 */
let refreshStreaming: (() => void) | null = null;
let refreshAssistDevice: (() => void) | null = null;
let refreshAssistStatus: (() => void) | null = null;
let refreshDeviceList: (() => void) | null = null;
let runDoctorAction: (() => void) | null = null;

/** 长期密码状态（`get_password_status`）。密码本身永不出现在这里。 */
interface PasswordStatus {
  hasPermanent: boolean;
  verifyMethod: string;
}

/** 验证方式：协助页只读显示，设置页提交长期密码时一起带给 Rust。 */
type VerifyMethod = "temporary" | "permanent" | "both";

let selectedVerify: VerifyMethod = "temporary";
/** 设置页或清除进行中（含等待 UAC）：任何输入事件都不能把提交按钮重新点亮。 */
let pwBusy = false;
/** 设置页读到的密码状态刷新；协助页「未设置」文案由它统一更新。 */
let refreshPasswordStatus: (() => void) | null = null;
/** 协助页注册：验证方式只读展示跟随密码状态。 */
let applyPasswordAvailability: ((status: PasswordStatus) => void) | null = null;
/** 设置页注册：展开长期密码内联表单（主页「设置」跳转时用）。 */
let openFixedPasswordForm: (() => void) | null = null;

function asVerifyMethod(raw: string): VerifyMethod {
  return raw === "permanent" || raw === "both" ? raw : "temporary";
}

/** 只改分段的高亮与记忆值，不写 RustDesk：写盘发生在设置长期密码时。 */
function selectVerifyMethod(method: VerifyMethod): void {
  selectedVerify = method;
  const group = document.getElementById("verify-method");
  if (!group) {
    return;
  }
  group.querySelectorAll<HTMLButtonElement>(".seg__btn[data-verify]").forEach((btn) => {
    const active = btn.dataset.verify === selectedVerify;
    btn.classList.toggle("is-active", active);
    btn.setAttribute("aria-pressed", active ? "true" : "false");
  });
}

/** 设置页与远程协助页共用同一份配置快照，避免 focus 时各读一遍。 */
type ConfigHandler = (config: ServerConfigView | null) => void;
const configHandlers: ConfigHandler[] = [];
let configRefreshInFlight = false;
/** 读取进行中又来了焦点/重读请求：本轮结束后必须再补读一次，不能丢弃。 */
let configRefreshPending = false;

async function refreshSharedConfig(): Promise<void> {
  if (configRefreshInFlight) {
    configRefreshPending = true;
    return;
  }
  configRefreshInFlight = true;
  try {
    // 循环只在本轮读取期间没人再请求时退出；有请求就再读一次，
    // 用最新快照覆盖远程协助页和设置页两个视图。
    for (;;) {
      configRefreshPending = false;
      let config: ServerConfigView | null = null;
      try {
        config = await invoke<ServerConfigView>("get_server_config");
      } catch {
        // 读取失败也要通知每个页面：旧快照可能已经不成立，不能继续拿来测试。
        config = null;
      }
      for (const handler of configHandlers) {
        handler(config);
      }
      if (!configRefreshPending) {
        break;
      }
    }
  } finally {
    configRefreshInFlight = false;
  }
}

async function refreshOnFocus(): Promise<void> {
  await refreshSharedConfig();
  // 从 RustDesk 安装/改配置回来时，设备码与安装状态也要跟着重查。
  refreshAssistDevice?.();
  refreshAssistStatus?.();
  refreshDeviceList?.();
  refreshPasswordStatus?.();
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

/**
 * 图标按钮的反馈：只切 aria-label 与 `.is-copied` 类。
 * 不能写 textContent —— 会把按钮里的 SVG 直接删掉，计时结束后也只剩文字。
 */
function flashCopyState(button: HTMLButtonElement, ok: boolean | null): void {
  const original = button.dataset.originalLabel ?? button.getAttribute("aria-label") ?? "";
  button.dataset.originalLabel = original;
  button.setAttribute("aria-label", ok === null ? "暂无设备码" : ok ? "已复制设备码" : "复制失败");
  button.classList.toggle("is-copied", ok === true);
  button.classList.toggle("is-copy-failed", ok === false);
  window.setTimeout(() => {
    button.setAttribute("aria-label", original);
    button.classList.remove("is-copied", "is-copy-failed");
  }, 1500);
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
  // 回到「我的设备」时重读：连接/改名/删除可能都发生在别的页面。
  if (page === "devices") {
    refreshDeviceList?.();
  }
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
  // 两个独立元素：临时密码的「查看」结果绝不能写进长期密码状态行。
  const temporaryPasswordStatus = byId<HTMLSpanElement>("temporary-password-status");
  const openFixedPasswordButton = byId<HTMLButtonElement>("open-fixed-password");
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

  // 设备码与安装状态的请求序号：focus 连续触发时只应用最新一次的回包，
  // 旧请求晚到的结果直接丢弃（否则会拿旧状态覆盖刚刷新出来的界面）。
  let deviceCodeRequest = 0;
  let statusRequest = 0;

  const loadDeviceCode = (): void => {
    const request = ++deviceCodeRequest;
    codeStatus.textContent = "";
    void invoke<DeviceInfo>("get_device_id").then((info) => {
      if (request !== deviceCodeRequest) {
        return;
      }
      if (!info) {
        codeEl.textContent = "预览模式";
        setStatus(codeStatus, "浏览器预览：未连接 Tauri，命令不可用", "warn");
        return;
      }
      currentDeviceCode = info.formattedId;
      if (info.installed && info.formattedId) {
        codeEl.textContent = info.formattedId;
        // 不再回显 RustDesk 安装路径：状态行只表示可用性。
        codeStatus.textContent = "";
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
    const request = ++statusRequest;
    void invoke<StatusView>("get_rustdesk_status").then((status) => {
      if (request !== statusRequest) {
        return;
      }
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
      flashCopyState(copyCodeButton, null);
      return;
    }
    void copyText(currentDeviceCode).then((ok) => {
      flashCopyState(copyCodeButton, ok);
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
    setStatus(temporaryPasswordStatus, "正在打开 RustDesk…");
    void invoke<OpResult>("open_rustdesk_window").then((result) => {
      if (!result) {
        setStatus(temporaryPasswordStatus, "浏览器预览：命令不可用", "warn");
        return;
      }
      setStatus(temporaryPasswordStatus, result.message, result.ok ? "ok" : "error");
    });
  });

  // 主页「长期密码 · 设置」：跳到设置页并展开内联表单。
  const gotoFixedPassword = (): void => {
    navigateTo("settings");
    openFixedPasswordForm?.();
  };
  openFixedPasswordButton.addEventListener("click", gotoFixedPassword);
  const fixedPasswordRow = document.getElementById("fixed-password-row");
  fixedPasswordRow?.addEventListener("click", gotoFixedPassword);

  openInstallPageButton.addEventListener("click", () => {
    // 安装入口只有一条：交给 Rust 侧用默认浏览器打开官方发行页，由用户手动安装。
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

  // 验证方式分段只读：显示 RustDesk 里当前生效的值，点击一律跳到设置页的长期密码表单。
  // 写盘只发生在设置/清除长期密码时，协助页不再单独改这个值。
  const verifyGroup = byId<HTMLDivElement>("verify-method");
  const verifyHint = byId<HTMLSpanElement>("verify-hint");
  const verifyButtons = Array.from(
    verifyGroup.querySelectorAll<HTMLButtonElement>(".seg__btn[data-verify]"),
  );
  verifyGroup.setAttribute("aria-readonly", "true");
  verifyButtons.forEach((btn) => {
    btn.setAttribute("aria-pressed", btn.classList.contains("is-active") ? "true" : "false");
    // 只读按钮仍可点：点击不是「选择」，而是跳到能改它的地方。
    btn.addEventListener("click", () => {
      navigateTo("settings");
      openFixedPasswordForm?.();
    });
  });

  // 高亮跟随已生效的验证方式；未设长期密码时给出「先设置长期密码」提示。
  applyPasswordAvailability = (status: PasswordStatus): void => {
    verifyButtons.forEach((btn) => {
      btn.removeAttribute("aria-disabled");
    });
    verifyHint.classList.toggle("is-hidden", status.hasPermanent);
    selectVerifyMethod(asVerifyMethod(status.verifyMethod));
  };

  configHandlers.push(applyServerConfig);
  refreshAssistDevice = loadDeviceCode;
  refreshAssistStatus = loadStatus;
  loadDeviceCode();
  loadStatus();
  loadRecents();
}

/* ---------- 我的设备：远程协助设备列表 ---------- */
/**
 * 数据全部来自 Rust：`get_recent_peers` 给设备码，`get_peer_aliases` 给别名。
 * 列表行整段用 createElement + textContent 拼，别名是用户输入，绝不能进 innerHTML。
 */
function setupDevicesPage(): void {
  const list = byId<HTMLDivElement>("device-list");
  // 空状态是 index.html 里的节点：有设备时摘下，列表空了再原样放回。
  const emptyState = list.querySelector<HTMLDivElement>(".empty");
  emptyState?.remove();

  const statusLine = document.createElement("p");
  statusLine.className = "row__sub";
  statusLine.setAttribute("role", "status");
  statusLine.setAttribute("aria-live", "polite");

  const showStatus = (text: string, kind?: "ok" | "warn" | "error"): void => {
    setStatus(statusLine, text, kind);
    if (text && statusLine.parentElement !== list) {
      list.append(statusLine);
    }
  };

  const connectMode = (): string =>
    document.querySelector<HTMLInputElement>('input[name="connect-mode"]:checked')?.value ??
    "control";

  /** 别名的键是规范化后的设备码；两种写法都查一遍。 */
  const aliasOf = (aliases: Record<string, string>, id: string): string =>
    aliases[id] ?? aliases[parsePeerId(id) ?? id] ?? "";

  let openMenu: HTMLDivElement | null = null;
  const closeMenu = (): void => {
    openMenu?.remove();
    openMenu = null;
  };

  const load = (): void => {
    void Promise.all([
      invoke<string[]>("get_recent_peers"),
      invoke<Record<string, string>>("get_peer_aliases"),
    ]).then(([ids, aliases]) => {
      const peers = ids ?? [];
      const map = aliases ?? {};
      render(peers, map);
      if (!ids) {
        showStatus("浏览器预览：命令不可用", "warn");
      }
    });
  };

  const buildRow = (id: string, aliases: Record<string, string>): HTMLDivElement => {
    const alias = aliasOf(aliases, id);
    const code = formatDeviceCode(parsePeerId(id) ?? id);
    const name = alias || code;

    const row = document.createElement("div");
    row.className = "row";

    // 头像：名称首字（别名优先，其次设备码首字）。
    const avatar = document.createElement("span");
    avatar.className = "device__avatar";
    avatar.setAttribute("aria-hidden", "true");
    avatar.textContent = Array.from(name)[0] ?? "?";

    const body = document.createElement("span");
    body.className = "row__body";
    const label = document.createElement("span");
    label.className = "row__label";
    label.textContent = name;
    const codeLine = document.createElement("span");
    codeLine.className = "row__sub";
    const codeEl = document.createElement("code");
    codeEl.textContent = code;
    codeLine.append(codeEl);
    body.append(label, codeLine);

    const connect = document.createElement("button");
    connect.type = "button";
    connect.className = "link";
    connect.textContent = "连接";
    connect.addEventListener("click", () => {
      connect.disabled = true;
      connect.textContent = "连接中";
      void invoke<OpResult>("connect_peer", { peerId: parsePeerId(id) ?? id, mode: connectMode() }).then(
        (result) => {
          connect.disabled = false;
          connect.textContent = "连接";
          if (!result) {
            showStatus("浏览器预览：命令不可用", "warn");
            return;
          }
          showStatus(result.ok ? `正在连接 ${name}…` : result.message, result.ok ? "ok" : "error");
          if (result.ok) {
            load();
          }
        },
      );
    });

    const menu = document.createElement("button");
    menu.type = "button";
    menu.className = "link";
    menu.textContent = "…";
    menu.setAttribute("aria-label", `${name} 的更多操作`);
    menu.addEventListener("click", (event) => {
      // 不拦住冒泡的话，下面文档级监听会在同一轮里把刚开的菜单关掉。
      event.stopPropagation();
      openPeerMenu(menu, id, alias, code);
    });

    row.append(avatar, body, connect, menu);
    return row;
  };

  const openPeerMenu = (anchor: HTMLElement, id: string, alias: string, code: string): void => {
    closeMenu();
    const menu = document.createElement("div");
    menu.className = "group";
    menu.style.position = "fixed";
    menu.style.zIndex = "70";
    menu.style.minWidth = "132px";
    menu.style.padding = "4px";
    menu.style.boxShadow = "0 14px 34px rgba(0, 0, 0, 0.18)";

    const rename = document.createElement("button");
    rename.type = "button";
    rename.className = "link";
    rename.textContent = "改名";
    rename.addEventListener("click", () => {
      closeMenu();
      const input = window.prompt("设备名称（留空则清除别名）", alias);
      if (input === null) {
        return;
      }
      void invoke<OpResult>("set_peer_alias", { peerId: parsePeerId(id) ?? id, alias: input }).then(
        (result) => {
          if (!result) {
            showStatus("浏览器预览：命令不可用", "warn");
            return;
          }
          showStatus(result.message, result.ok ? "ok" : "error");
          if (result.ok) {
            load();
          }
        },
      );
    });

    const remove = document.createElement("button");
    remove.type = "button";
    remove.className = "link link--danger";
    remove.textContent = "删除";
    remove.addEventListener("click", () => {
      closeMenu();
      if (!window.confirm(`从本地记录中删除 ${alias || code}？不会影响对方设备本身。`)) {
        return;
      }
      void invoke<OpResult>("remove_peer", { peerId: parsePeerId(id) ?? id }).then((result) => {
        if (!result) {
          showStatus("浏览器预览：命令不可用", "warn");
          return;
        }
        showStatus(result.message, result.ok ? "ok" : "error");
        if (result.ok) {
          load();
        }
      });
    });

    menu.append(rename, remove);
    document.body.append(menu);
    // 菜单贴着「…」按钮右下角；超出窗口右侧时向左收。
    const rect = anchor.getBoundingClientRect();
    const width = menu.offsetWidth || 132;
    const left = Math.max(8, Math.min(rect.right - width, window.innerWidth - width - 8));
    menu.style.top = `${Math.round(rect.bottom + 6)}px`;
    menu.style.left = `${Math.round(left)}px`;
    openMenu = menu;
  };

  const render = (ids: string[], aliases: Record<string, string>): void => {
    list.textContent = "";
    if (ids.length === 0) {
      if (emptyState) {
        list.append(emptyState);
      }
    } else {
      ids.forEach((id) => list.append(buildRow(id, aliases)));
    }
    if (statusLine.textContent) {
      list.append(statusLine);
    }
  };

  document.addEventListener("click", (event) => {
    if (openMenu && !openMenu.contains(event.target as Node)) {
      closeMenu();
    }
  });
  window.addEventListener("resize", closeMenu);

  refreshDeviceList = (): void => {
    closeMenu();
    load();
  };
  load();
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
  const relayDefaultsHint = byId<HTMLSpanElement>("relay-defaults");
  const runDoctorButton = byId<HTMLButtonElement>("run-doctor");
  const exportButton = byId<HTMLButtonElement>("export-log");
  const fixedPasswordButton = byId<HTMLButtonElement>("save-fixed-password");
  const fixedPasswordInput = byId<HTMLInputElement>("set-fixed-password");
  const fixedPasswordConfirm = byId<HTMLInputElement>("set-fixed-password-confirm");
  const clearPasswordButton = byId<HTMLButtonElement>("clear-fixed-password");
  const togglePasswordButton = byId<HTMLButtonElement>("toggle-fixed-password");
  const passwordForm = byId<HTMLDivElement>("fixed-password-form");
  const formVerifyGroup = byId<HTMLDivElement>("pw-form-verify");
  const formVerifyButtons = Array.from(
    formVerifyGroup.querySelectorAll<HTMLButtonElement>(".seg__btn[data-pw-verify]"),
  );
  const trayCheckbox = byId<HTMLInputElement>("set-tray");

  // 表单里的验证方式：默认「两者」，提交时和密码一起发出，避免「先设密码、再改验证方式」两步。
  // formVerifyPending 只在用户点过分段时为 true，此时焦点刷新不能覆盖他的选择。
  let formVerify: VerifyMethod = "both";
  let formVerifyPending = false;

  const renderFormVerify = (): void => {
    formVerifyButtons.forEach((btn) => {
      const active = btn.dataset.pwVerify === formVerify;
      btn.classList.toggle("is-active", active);
      btn.setAttribute("aria-pressed", active ? "true" : "false");
    });
  };

  formVerifyButtons.forEach((btn) => {
    btn.setAttribute("aria-pressed", btn.classList.contains("is-active") ? "true" : "false");
    btn.addEventListener("click", () => {
      formVerify = asVerifyMethod(btn.dataset.pwVerify ?? "");
      formVerifyPending = true;
      renderFormVerify();
    });
  });

  // 长期密码表单默认折叠：只在用户点开或从主页跳过来时展开。
  const setPasswordFormOpen = (open: boolean): void => {
    passwordForm.classList.toggle("is-hidden", !open);
    togglePasswordButton.setAttribute("aria-expanded", open ? "true" : "false");
    togglePasswordButton.textContent = open ? "收起" : "设置长期密码";
    if (open) {
      fixedPasswordInput.focus();
    }
  };
  togglePasswordButton.addEventListener("click", () => {
    setPasswordFormOpen(passwordForm.classList.contains("is-hidden"));
  });
  openFixedPasswordForm = (): void => {
    setPasswordFormOpen(true);
  };

  // 关闭到托盘：默认开启，启动时把当前勾选状态交给 Rust，变更时再同步。
  syncCloseToTray(trayCheckbox.checked);
  trayCheckbox.addEventListener("change", () => {
    syncCloseToTray(trayCheckbox.checked);
  });

  // 只读页：配置只显示 RustDesk2.toml 里的当前值，写入一律在 RustDesk 里做。
  // 安装包默认中继只用于比对：不一致时提示，不提供“一键改回”的写入能力。
  let probeGeneration = 0;
  let relayDefaults: RelayDefaultsView | null = null;
  let lastConfig: ServerConfigView | null = null;

  // RustDesk 的 ID 与中继各有默认端口；比较前按角色补默认端口，
  // 保留显式端口，并且不把裸 IPv6 末尾的数字当端口截掉。
  const RUSTDESK_ID_PORT = 21116;
  const RUSTDESK_RELAY_PORT = 21117;

  const normalizeEndpoint = (value: string, defaultPort: number): string => {
    const text = value.trim().toLowerCase();
    if (!text) return "";
    const bracketed = /^\[([0-9a-f:.]+)\](?::(\d+))?$/.exec(text);
    if (bracketed) {
      const port = bracketed[2] ? Number(bracketed[2]) : defaultPort;
      return `[${bracketed[1]}]:${port}`;
    }
    // 只有一个冒号且后面是数字才算 host:port；裸 IPv6 有多个冒号，保持原样。
    const withPort = /^([^:]+):(\d+)$/.exec(text);
    if (withPort) {
      return `${withPort[1]}:${Number(withPort[2])}`;
    }
    return `${text}:${defaultPort}`;
  };

  const renderRelayDefaults = (): void => {
    if (!relayDefaults) {
      setStatus(relayDefaultsHint, "");
      return;
    }
    if (relayDefaults.error) {
      setStatus(relayDefaultsHint, `默认中继：${relayDefaults.error}`, "warn");
      return;
    }
    const expected = `${relayDefaults.idServer}（中继 ${relayDefaults.relayServer}）`;
    if (!lastConfig || lastConfig.error) {
      setStatus(relayDefaultsHint, `默认中继：${expected}`, "warn");
      return;
    }
    const sameId =
      normalizeEndpoint(lastConfig.server, RUSTDESK_ID_PORT) ===
      normalizeEndpoint(relayDefaults.idServer, RUSTDESK_ID_PORT);
    const sameRelay =
      normalizeEndpoint(lastConfig.relay, RUSTDESK_RELAY_PORT) ===
      normalizeEndpoint(relayDefaults.relayServer, RUSTDESK_RELAY_PORT);
    // 公钥也要比：只比地址会让「同地址不同密钥」被误判为一致。
    const sameKey = relayDefaults.keyPresent
      ? lastConfig.keyPresent && lastConfig.keyFingerprint === relayDefaults.keyFingerprint
      : true;
    if (sameId && sameRelay && sameKey) {
      setStatus(relayDefaultsHint, `与安装包默认中继一致：${expected}`, "ok");
    } else {
      setStatus(
        relayDefaultsHint,
        `当前 RustDesk 中继与安装包默认（${expected}）不一致；如果你 fork 过 vega-defaults.json 请确认配置文件已同步。`,
        "warn",
      );
    }
  };

  void invoke<RelayDefaultsView>("get_relay_defaults")
    .then((view) => {
      relayDefaults = view ?? null;
      renderRelayDefaults();
    })
    .catch(() => {
      relayDefaults = null;
      setStatus(relayDefaultsHint, "默认中继：浏览器预览下不可用", "warn");
    });

  const applyConfig = (config: ServerConfigView | null): void => {
    // 每次重读配置都作废在途探测，并把上一次的结果与按钮状态复位。
    // 旧回调只认自己的代次，不能把按钮永久留在 disabled（审计 r5 P2）。
    probeGeneration += 1;
    lastConfig = config;
    renderRelayDefaults();
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

  // 手机扫码配置：把当前 RustDesk 配置画成官方 App 能扫的二维码。
  // 弹层是原生 <dialog>：showModal() 负责焦点限制在弹层内、Esc 关闭，
  // 关闭后焦点回到「显示二维码」，键盘不会退到遮罩下的设置控件。
  const mobileButton = byId<HTMLButtonElement>("show-mobile-qr");
  const mobileSheet = byId<HTMLDialogElement>("mobile-qr-sheet");
  const mobileCanvas = byId<HTMLCanvasElement>("mobile-qr-canvas");
  const mobileStatus = byId<HTMLParagraphElement>("mobile-qr-status");
  const mobileClose = byId<HTMLButtonElement>("mobile-qr-close");
  const mobileContext = mobileCanvas.getContext("2d");
  let mobileGeneration = 0;

  // 二维码边长：版本 1（21）到版本 40（177），且必须是 4n+1 的整数。
  const QR_MIN_SIZE = 21;
  const QR_MAX_SIZE = 177;
  const QR_QUIET_ZONE = 4;

  /**
   * 上下文是否已经丢失。丢失后 `fillRect` 不报错也不写像素，画布会白屏，
   * 所以绘制前必须问一句。老实现没有 `isContextLost()`，只能退回 null 判断。
   */
  const mobileContextIsLost = (): boolean => {
    if (!mobileContext) {
      return false;
    }
    // TS 5.4 的 DOM 声明里没有 isContextLost，按可选方法读取。
    const isLost = (mobileContext as unknown as { isContextLost?: () => boolean }).isContextLost;
    if (typeof isLost !== "function") {
      return false;
    }
    try {
      return isLost.call(mobileContext) === true;
    } catch {
      return false;
    }
  };

  /**
   * 清空空画布。context 不可用时返回 false，调用方不得再显示成功状态。
   */
  const clearMobileCanvas = (): boolean => {
    if (!mobileContext) {
      return false;
    }
    try {
      mobileContext.fillStyle = "#fff";
      mobileContext.fillRect(0, 0, mobileCanvas.width, mobileCanvas.height);
      return true;
    } catch {
      return false;
    }
  };

  /**
   * 画码并返回是否真的画成功。失败时自己写好错误状态，调用方只负责在
   * 返回 true 之后显示成功文案——否则错误会被紧接着的 ok 覆盖（审计 P2）。
   */
  const drawMobileQr = (view: MobileQrView): boolean => {
    if (!mobileContext) {
      setStatus(mobileStatus, "当前环境不支持 canvas，请更新系统或显卡驱动后重试", "error");
      return false;
    }
    // 已经丢了上下文就别画：白底黑块都写不进去，画完还报成功等于骗人。
    if (mobileContextIsLost()) {
      setStatus(mobileStatus, "绘制二维码失败，请重试", "error");
      return false;
    }
    const size = view.size;
    if (
      !Number.isInteger(size) ||
      size < QR_MIN_SIZE ||
      size > QR_MAX_SIZE ||
      (size - 1) % 4 !== 0
    ) {
      setStatus(mobileStatus, "二维码尺寸无效，请重试", "error");
      return false;
    }
    if (!Array.isArray(view.modules) || view.modules.length !== size * size) {
      setStatus(mobileStatus, "二维码数据不完整，请重试", "error");
      return false;
    }
    const canvasSize = mobileCanvas.width;
    // 四周各 4 模块静区；整数像素缩放后居中，避免半像素糊边。
    const total = size + QR_QUIET_ZONE * 2;
    const scale = Math.floor(canvasSize / total);
    if (!Number.isFinite(canvasSize) || canvasSize <= 0 || scale < 1) {
      setStatus(mobileStatus, "画布太小，无法容纳二维码和静区，请调整窗口大小后重试", "error");
      return false;
    }
    if (!clearMobileCanvas()) {
      setStatus(mobileStatus, "画布不可用，请重试", "error");
      return false;
    }
    const offset = Math.floor((canvasSize - scale * total) / 2);
    try {
      mobileContext.fillStyle = "#000";
      for (let row = 0; row < size; row += 1) {
        for (let col = 0; col < size; col += 1) {
          if (!view.modules[row * size + col]) {
            continue;
          }
          mobileContext.fillRect(
            offset + (col + QR_QUIET_ZONE) * scale,
            offset + (row + QR_QUIET_ZONE) * scale,
            scale,
            scale,
          );
        }
      }
    } catch {
      // 画到一半失败就把残码擦掉，别让用户扫到半个二维码。
      clearMobileCanvas();
      setStatus(mobileStatus, "绘制二维码失败，请重试", "error");
      return false;
    }
    return true;
  };

  const closeMobileSheet = (): void => {
    mobileGeneration += 1;
    if (mobileSheet.open) {
      mobileSheet.close();
    }
  };

  /**
   * 弹层打开期间 GPU 掉了会触发 contextlost：这时画布上什么都没了，
   * 继续显示「当前 ID 服务器」就是白屏配成功。直接翻成绘制失败，
   * 并作废进行中的请求，免得迟到的结果又把状态写回 ok。
   */
  const handleMobileContextLost = (): void => {
    // 监听常驻；弹层没开时不处理，避免异步 close 与重开之间的竞态。
    if (!mobileSheet.open) {
      return;
    }
    mobileGeneration += 1;
    setStatus(mobileStatus, "绘制二维码失败，请重试", "error");
  };

  const openMobileSheet = (): void => {
    const generation = ++mobileGeneration;
    if (!mobileSheet.open) {
      mobileSheet.showModal();
    }
    mobileClose.focus();
    clearMobileCanvas();
    if (!window.__TAURI__?.core) {
      setStatus(mobileStatus, "浏览器预览下不可用", "warn");
      return;
    }
    setStatus(mobileStatus, "生成中…");
    void invoke<MobileQrView>("get_mobile_config_qr").then((view) => {
      if (generation !== mobileGeneration || !mobileSheet.open) {
        return;
      }
      if (!view) {
        setStatus(mobileStatus, "读取 RustDesk 配置失败，请重试", "error");
        return;
      }
      if (view.error) {
        setStatus(mobileStatus, view.error, "warn");
        return;
      }
      // 只有真的画成功了才写成功状态。
      if (!drawMobileQr(view)) {
        return;
      }
      setStatus(mobileStatus, `当前 ID 服务器：${view.server}`, "ok");
    });
  };

  mobileCanvas.addEventListener("contextlost", handleMobileContextLost);
  mobileButton.addEventListener("click", openMobileSheet);
  mobileClose.addEventListener("click", closeMobileSheet);
  // 浏览器对 showModal() 的弹层自己处理 Esc（cancel → close），
  // 这里只做收尾：作废进行中的请求并把焦点还给入口按钮。
  mobileSheet.addEventListener("cancel", () => {
    mobileGeneration += 1;
  });
  mobileSheet.addEventListener("close", () => {
    // close 是异步派发的：若此时弹层已被重新打开，这是上一次的迟到事件，忽略。
    if (mobileSheet.open) {
      return;
    }
    mobileGeneration += 1;
    mobileButton.focus();
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

  // 导出只认「当前屏幕上那次诊断」的快照编号；一开始没有结果，先禁用。
  let currentSnapshotId: number | null = null;
  let doctorGeneration = 0;
  // 设置页按钮与串流页快捷入口共用的运行标志：运行中再次触发直接忽略，
  // 不发第二次请求、也不改按钮和状态文字。
  let doctorRunning = false;
  exportButton.disabled = true;

  const runDoctor = (): void => {
    if (doctorRunning) {
      return;
    }
    doctorRunning = true;
    runDoctorButton.disabled = true;
    // 新诊断一开始，旧快照就作废：导出等这次结果。
    currentSnapshotId = null;
    exportButton.disabled = true;
    setStatus(doctorStatus, "正在诊断（最多 8 秒）…");
    const generation = ++doctorGeneration;
    void invoke<DoctorReport>("run_doctor")
      .then((report) => {
        if (generation !== doctorGeneration) {
          return;
        }
        doctorRunning = false;
        runDoctorButton.disabled = false;
        if (!report) {
          setStatus(doctorStatus, "浏览器预览：命令不可用", "warn");
          return;
        }
        renderDoctor(report.items);
        // 超时也算本次结果，但没有快照：导出保持禁用。
        currentSnapshotId = report.snapshotAvailable ? report.snapshotId : null;
        exportButton.disabled = currentSnapshotId === null;
        setStatus(
          doctorStatus,
          currentSnapshotId === null
            ? `诊断完成：${report.items.length} 项（本次无快照，导出已禁用）`
            : `诊断完成：${report.items.length} 项`,
          currentSnapshotId === null ? "warn" : "ok",
        );
      })
      .catch(() => {
        if (generation !== doctorGeneration) {
          return;
        }
        doctorRunning = false;
        runDoctorButton.disabled = false;
        currentSnapshotId = null;
        exportButton.disabled = true;
        setStatus(doctorStatus, "诊断失败，请重试", "error");
      });
  };
  runDoctorAction = runDoctor;
  runDoctorButton.addEventListener("click", runDoctor);

  exportButton.addEventListener("click", () => {
    const snapshotId = currentSnapshotId;
    if (snapshotId === null) {
      exportButton.disabled = true;
      setStatus(doctorStatus, "本次没有可导出的诊断快照，请先重新诊断", "warn");
      return;
    }
    exportButton.disabled = true;
    setStatus(doctorStatus, "正在导出脱敏日志…");
    void invoke<OpResult>("export_doctor_log", { snapshotId }).then((result) => {
      // 发起导出时的快照已经不是当前显示的那次：整包丢弃，
      // 不改按钮状态，也不覆盖状态文字。
      if (currentSnapshotId !== snapshotId) {
        return;
      }
      exportButton.disabled = false;
      if (!result) {
        setStatus(doctorStatus, "浏览器预览：命令不可用", "warn");
        return;
      }
      setStatus(doctorStatus, result.message, result.ok ? "ok" : "error");
    });
  });

  /* ----- 长期密码：两次输入一致 + ≥8 位含字母数字才允许提交 ----- */
  // 状态行插在「设置 / 清除」按钮行下面；不改 index.html 的结构。
  const passwordResult = document.createElement("p");
  passwordResult.className = "row__sub";
  passwordResult.setAttribute("role", "status");
  passwordResult.setAttribute("aria-live", "polite");
  (fixedPasswordButton.closest(".row__actions") ?? fixedPasswordButton).insertAdjacentElement(
    "afterend",
    passwordResult,
  );

  // 协助页的「长期密码」状态行：有就一起更新，没有（别的页面结构）就跳过。
  const assistPasswordStatus = document.getElementById("password-status");

  /**
   * 与 Rust 侧保持一致：8-64 位、含字母和数字，
   * 且只允许字母数字和 `!#$%&*+,-./:;<=>?@^_~`（其他符号会被 CLI 当成参数或转义）。
   */
  const PASSWORD_CHARS = /^[A-Za-z0-9!#$%&*+,\-./:;<=>?@^_~]+$/;
  const PASSWORD_RULE =
    "密码需 8-64 位，含字母和数字，只能用字母数字和 !#$%&*+,-./:;<=>?@^_~";
  const passwordValid = (value: string): boolean =>
    value.length >= 8 &&
    value.length <= 64 &&
    PASSWORD_CHARS.test(value) &&
    /[A-Za-z]/.test(value) &&
    /\d/.test(value);

  const refreshSubmitState = (): void => {
    const value = fixedPasswordInput.value;
    const confirm = fixedPasswordConfirm.value;
    // 进行中始终禁用：input/confirm 的编辑事件会反复调用这里，不能把按钮重新点亮。
    fixedPasswordButton.disabled = pwBusy || !(passwordValid(value) && value === confirm);
  };

  // 设置或清除进行中（含等待 UAC）时，三个控件全部禁用，避免状态写入乱序。
  const setPasswordBusy = (busy: boolean): void => {
    pwBusy = busy;
    formVerifyButtons.forEach((btn) => {
      btn.disabled = busy;
    });
    clearPasswordButton.disabled = busy;
    if (busy) {
      fixedPasswordButton.disabled = true;
    } else {
      refreshSubmitState();
    }
  };

  const applyPasswordStatus = (status: PasswordStatus): void => {
    if (assistPasswordStatus) {
      setStatus(
        assistPasswordStatus,
        status.hasPermanent ? "已设置" : "未设置",
        status.hasPermanent ? "ok" : undefined,
      );
    }
    // 分段高亮跟随 RustDesk 里实际生效的验证方式；可用性由协助页按 hasPermanent 决定。
    selectVerifyMethod(asVerifyMethod(status.verifyMethod));
    // 设置页表单的分段：用户已选但还没提交时保持原样，否则跟随状态（首次设置默认「两者」）。
    if (!formVerifyPending) {
      formVerify = status.hasPermanent ? asVerifyMethod(status.verifyMethod) : "both";
      renderFormVerify();
    }
    applyPasswordAvailability?.(status);
  };

  const loadPasswordStatus = (): void => {
    void invoke<PasswordStatus>("get_password_status").then((status) => {
      if (!status) {
        if (assistPasswordStatus) {
          setStatus(assistPasswordStatus, "预览模式：无法读取密码状态", "warn");
        }
        return;
      }
      applyPasswordStatus(status);
    });
  };

  refreshPasswordStatus = (): void => {
    loadPasswordStatus();
  };

  fixedPasswordInput.addEventListener("input", () => {
    refreshSubmitState();
    if (!fixedPasswordInput.value) {
      setStatus(passwordResult, "");
    } else if (!passwordValid(fixedPasswordInput.value)) {
      setStatus(passwordResult, PASSWORD_RULE, "warn");
    } else if (fixedPasswordConfirm.value && fixedPasswordInput.value !== fixedPasswordConfirm.value) {
      setStatus(passwordResult, "两次输入的密码不一致", "warn");
    } else {
      setStatus(passwordResult, "");
    }
  });

  fixedPasswordConfirm.addEventListener("input", () => {
    refreshSubmitState();
    if (!fixedPasswordConfirm.value) {
      setStatus(passwordResult, "");
      return;
    }
    setStatus(
      passwordResult,
      fixedPasswordInput.value === fixedPasswordConfirm.value ? "" : "两次输入的密码不一致",
      fixedPasswordInput.value === fixedPasswordConfirm.value ? undefined : "warn",
    );
  });

  fixedPasswordButton.addEventListener("click", () => {
    const password = fixedPasswordInput.value;
    if (!passwordValid(password)) {
      setStatus(passwordResult, PASSWORD_RULE, "error");
      return;
    }
    if (password !== fixedPasswordConfirm.value) {
      setStatus(passwordResult, "两次输入的密码不一致", "error");
      return;
    }
    setPasswordBusy(true);
    setStatus(passwordResult, "正在请求管理员确认（Windows 会弹一次 UAC）…");
    void invoke<OpResult>("set_permanent_password", { password, verify: formVerify })
      .then((result) => {
        if (!result) {
          setStatus(passwordResult, "浏览器预览：命令不可用", "warn");
          return;
        }
        setStatus(passwordResult, result.message, result.ok ? "ok" : "error");
        if (result.ok) {
          loadPasswordStatus();
        }
      })
      .finally(() => {
        // 无论成败都立刻清空两个输入框并恢复控件：密码不在页面上多留一秒。
        fixedPasswordInput.value = "";
        fixedPasswordConfirm.value = "";
        formVerifyPending = false;
        setPasswordBusy(false);
      });
  });

  clearPasswordButton.addEventListener("click", () => {
    if (!window.confirm("清除长期密码后将只能用临时密码连接，确定清除吗？")) {
      return;
    }
    setPasswordBusy(true);
    setStatus(passwordResult, "正在请求管理员确认（Windows 会弹一次 UAC）…");
    void invoke<OpResult>("clear_permanent_password")
      .then((result) => {
        if (!result) {
          setStatus(passwordResult, "浏览器预览：命令不可用", "warn");
          return;
        }
        setStatus(passwordResult, result.message, result.ok ? "ok" : "error");
        if (result.ok) {
          loadPasswordStatus();
        }
      })
      .finally(() => {
        setPasswordBusy(false);
      });
  });

  renderFormVerify();
  refreshSubmitState();
  loadPasswordStatus();
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

  // 串流状态的请求序号：刷新连续触发时只应用最新一次的回包，
  // 旧请求晚到的结果直接丢弃（与 Assist 页做法一致）。
  let statusRequest = 0;

  const load = (): void => {
    const request = ++statusRequest;
    void invoke<StreamingStatus>("get_streaming_status").then((value) => {
      if (request !== statusRequest) {
        return;
      }
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
  setupDevicesPage();
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
