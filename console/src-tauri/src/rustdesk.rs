//! RustDesk 集成（M2b）。
//!
//! 约定（继承 T1/T2 安全约束）：
//! - 不读取、不保存、不通过命令行传递临时密码。密码只由 RustDesk 自己管理，
//!   控制台只负责打开 RustDesk 主窗口让用户自己看。
//! - 服务器公钥从不写日志；对外只暴露前 8 位指纹。
//! - 非 Windows 平台一律返回「未安装 RustDesk」，不 spawn 任何进程。

use serde::Serialize;
use std::net::{Ipv4Addr, Ipv6Addr, SocketAddr, TcpStream, ToSocketAddrs};
use std::path::{Path, PathBuf};
use std::process::{Command, Stdio};
use std::time::{Duration, Instant};

use tauri::Manager;

const RUSTDESK_EXE: &str = "rustdesk.exe";
const NOT_INSTALLED: &str = "未安装 RustDesk";
const CONFIG_TIMEOUT: Duration = Duration::from_secs(5);
const TEST_TIMEOUT: Duration = Duration::from_secs(3);
/// RustDesk 默认 ID/中继端口（hbbs 21116）。
const RUSTDESK_DEFAULT_PORT: u16 = 21116;
const RECENT_LIMIT: usize = 10;
const RECENT_FILE: &str = "recent-ids.json";

#[cfg(windows)]
const CREATE_NO_WINDOW: u32 = 0x0800_0000;

/* ------------------------------------------------------------------ */
/* 纯函数：设备码、服务器地址、公钥校验（带单元测试）                    */
/* ------------------------------------------------------------------ */

/// 从任意文本里抽出 9~10 位纯数字设备码；`--get-id` 输出的就是纯数字。
pub fn normalize_device_id(raw: &str) -> Option<String> {
    let digits: String = raw.chars().filter(|c| c.is_ascii_digit()).collect();
    if digits.len() == 9 || digits.len() == 10 {
        Some(digits)
    } else {
        None
    }
}

/// 只接受「整行就是设备码」的行，避免把 RustDesk 版本号等数字当成设备码。
pub fn extract_device_id(stdout: &str) -> Option<String> {
    for line in stdout.lines() {
        let trimmed = line.trim();
        if trimmed.is_empty() {
            continue;
        }
        if !trimmed
            .chars()
            .all(|c| c.is_ascii_digit() || c == '-' || c == ' ')
        {
            continue;
        }
        if let Some(id) = normalize_device_id(trimmed) {
            return Some(id);
        }
    }
    None
}

/// 前端展示用：9 位 → 3-3-3，10 位 → 3-3-4，其他原样返回。
pub fn format_device_id(id: &str) -> String {
    match id.len() {
        9 => format!("{}-{}-{}", &id[0..3], &id[3..6], &id[6..9]),
        10 => format!("{}-{}-{}", &id[0..3], &id[3..6], &id[6..10]),
        _ => id.to_string(),
    }
}

/// 校验「主机[:端口]」。主机可以是 IPv4、主机名，IPv6 必须写成 `[::1]`。
/// 返回去掉首尾空白后的地址。
pub fn validate_server(input: &str) -> Result<String, String> {
    let value = input.trim();
    if value.is_empty() {
        return Err("服务器地址不能为空".into());
    }
    if value.len() > 255 {
        return Err("服务器地址过长（上限 255 字符）".into());
    }
    if value
        .chars()
        .any(|c| c.is_whitespace() || c == '/' || c == '\\' || c == '"' || c == '\'')
    {
        return Err("服务器地址只能包含主机名、IP 和可选端口".into());
    }
    let (host, port) = split_host_port(value)?;
    validate_host(host)?;
    if let Some(port) = port {
        if port == 0 {
            return Err("端口必须在 1-65535 之间".into());
        }
    }
    Ok(value.to_string())
}

fn split_host_port(value: &str) -> Result<(&str, Option<u16>), String> {
    if let Some(rest) = value.strip_prefix('[') {
        let end = rest
            .find(']')
            .ok_or_else(|| "IPv6 地址缺少右方括号".to_string())?;
        let host = &rest[..end];
        let tail = &rest[end + 1..];
        if tail.is_empty() {
            return Ok((host, None));
        }
        let port = tail
            .strip_prefix(':')
            .ok_or_else(|| "IPv6 地址后只能跟 :端口".to_string())?;
        return Ok((host, Some(parse_port(port)?)));
    }
    if let Some((host, port)) = value.rsplit_once(':') {
        // 无方括号的 IPv6 里冒号不止一个：整串当主机处理。
        if !host.contains(':') {
            if host.is_empty() {
                return Err("冒号前缺少主机".into());
            }
            return Ok((host, Some(parse_port(port)?)));
        }
    }
    Ok((value, None))
}

fn parse_port(port: &str) -> Result<u16, String> {
    if port.is_empty() || !port.chars().all(|c| c.is_ascii_digit()) {
        return Err("端口必须是数字".into());
    }
    port.parse::<u16>()
        .map_err(|_| "端口必须在 1-65535 之间".into())
}

fn validate_host(host: &str) -> Result<(), String> {
    if host.is_empty() {
        return Err("主机不能为空".into());
    }
    if host.len() > 253 {
        return Err("主机名过长".into());
    }
    if host.parse::<Ipv4Addr>().is_ok() || host.parse::<Ipv6Addr>().is_ok() {
        return Ok(());
    }
    if host.starts_with('-')
        || host.ends_with('-')
        || host.starts_with('.')
        || host.ends_with('.')
        || host.contains("..")
    {
        return Err("主机名格式无效".into());
    }
    if !host
        .chars()
        .all(|c| c.is_ascii_alphanumeric() || c == '-' || c == '.' || c == '_')
    {
        return Err("主机名只能包含字母、数字、点和连字符".into());
    }
    Ok(())
}

/// 公钥必须是 44 个 base64 字符（允许末尾 1~2 个 `=`）。返回清洗后的公钥。
pub fn validate_key(input: &str) -> Result<String, String> {
    let key: String = input
        .chars()
        .filter(|c| !c.is_whitespace())
        .collect::<String>();
    if key.is_empty() {
        return Err("公钥不能为空".into());
    }
    if key.len() != 44 {
        return Err(format!("公钥应为 44 个 base64 字符（当前 {}）", key.len()));
    }
    if !key
        .chars()
        .all(|c| c.is_ascii_alphanumeric() || c == '+' || c == '/' || c == '=')
    {
        return Err("公钥包含非 base64 字符".into());
    }
    if key.trim_end_matches('=').len() < 42 || key.contains('=') && !key.ends_with('=') {
        return Err("公钥 base64 填充位置无效".into());
    }
    Ok(key)
}

/// 公钥指纹：只暴露前 8 位。
pub fn key_fingerprint(key: &str) -> String {
    key.chars().take(8).collect()
}

/// 从 `host[:port]` 得到用于 TCP 探测的 (主机, 端口)。
pub fn endpoint_from_server(server: &str) -> Result<(String, u16), String> {
    let normalized = validate_server(server)?;
    let (host, port) = split_host_port(&normalized)?;
    Ok((
        host.to_string(),
        port.unwrap_or(RUSTDESK_DEFAULT_PORT),
    ))
}

/* ------------------------------------------------------------------ */
/* RustDesk2.toml 读写                                                  */
/* ------------------------------------------------------------------ */

/// RustDesk2.toml `[options]` 里的三个受管键。
#[derive(Debug, Default, Clone, PartialEq, Eq)]
pub struct ServerSnapshot {
    pub server: String,
    pub relay: String,
    pub key: String,
}

impl ServerSnapshot {
    pub fn key_fingerprint(&self) -> String {
        key_fingerprint(&self.key)
    }

    pub fn key_present(&self) -> bool {
        !self.key.is_empty()
    }
}

/// 解析 TOML 文本，只取 `[options]` 下的受管键；其他键保持不动。
pub fn read_server_config(text: &str) -> Result<ServerSnapshot, String> {
    if text.trim().is_empty() {
        return Ok(ServerSnapshot::default());
    }
    let doc: toml::Table = text
        .parse()
        .map_err(|e| format!("RustDesk2.toml 解析失败：{e}"))?;
    let options = match doc.get("options").and_then(|v| v.as_table()) {
        Some(table) => table,
        None => return Ok(ServerSnapshot::default()),
    };
    let get = |name: &str| -> String {
        options
            .get(name)
            .and_then(|v| v.as_str())
            .unwrap_or_default()
            .to_string()
    };
    Ok(ServerSnapshot {
        server: get("custom-rendezvous-server"),
        relay: get("relay-server"),
        key: get("key"),
    })
}

/// 把三个受管键合并进 `[options]`，保留文件里其他所有键与段落。
pub fn merge_server_config(
    text: &str,
    server: &str,
    relay: &str,
    key: &str,
) -> Result<String, String> {
    let mut doc: toml::Table = if text.trim().is_empty() {
        toml::Table::new()
    } else {
        text.parse()
            .map_err(|e| format!("RustDesk2.toml 解析失败：{e}"))?
    };

    if !doc.contains_key("options") {
        doc.insert(
            "options".to_string(),
            toml::Value::Table(toml::Table::new()),
        );
    }
    let table = doc
        .get_mut("options")
        .and_then(|value| value.as_table_mut())
        .ok_or_else(|| "[options] 不是表，拒绝覆盖".to_string())?;
    table.insert(
        "custom-rendezvous-server".to_string(),
        toml::Value::String(server.to_string()),
    );
    table.insert(
        "relay-server".to_string(),
        toml::Value::String(relay.to_string()),
    );
    table.insert("key".to_string(), toml::Value::String(key.to_string()));

    toml::to_string(&doc).map_err(|e| format!("RustDesk2.toml 序列化失败：{e}"))
}

/// 当前用户配置路径：`%APPDATA%\RustDesk\config\RustDesk2.toml`。
pub fn user_config_path() -> Option<PathBuf> {
    let appdata = std::env::var_os("APPDATA").map(PathBuf::from).or_else(|| {
        std::env::var_os("USERPROFILE")
            .map(PathBuf::from)
            .map(|p| p.join("AppData").join("Roaming"))
    })?;
    Some(
        appdata
            .join("RustDesk")
            .join("config")
            .join("RustDesk2.toml"),
    )
}

/* ------------------------------------------------------------------ */
/* 进程工具                                                            */
/* ------------------------------------------------------------------ */

/// 找 rustdesk.exe：先 Program Files\RustDesk，再 PATH。
pub fn locate_rustdesk() -> Option<PathBuf> {
    for key in ["ProgramFiles", "ProgramFiles(x86)"] {
        if let Some(root) = std::env::var_os(key) {
            let root = PathBuf::from(root);
            if root.as_os_str().is_empty() {
                continue;
            }
            let candidate = root.join("RustDesk").join(RUSTDESK_EXE);
            if candidate.is_file() {
                return Some(candidate);
            }
        }
    }
    if let Some(paths) = std::env::var_os("PATH") {
        for dir in std::env::split_paths(&paths) {
            let candidate = dir.join(RUSTDESK_EXE);
            if candidate.is_file() {
                return Some(candidate);
            }
        }
    }
    None
}

/// 运行命令并限时收集输出。超时会杀掉子进程并返回错误。
fn run_capture(exe: &Path, args: &[&str], timeout: Duration) -> Result<String, String> {
    let mut command = Command::new(exe);
    command
        .args(args)
        .stdin(Stdio::null())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped());
    #[cfg(windows)]
    {
        use std::os::windows::process::CommandExt;
        // 隐藏控制台窗口：--get-id 与 tasklist 都不该闪黑框。
        command.creation_flags(CREATE_NO_WINDOW);
    }

    let mut child = command
        .spawn()
        .map_err(|e| format!("启动 {} 失败：{e}", exe.display()))?;
    let started = Instant::now();
    loop {
        match child.try_wait() {
            Ok(Some(status)) => {
                let output = child
                    .wait_with_output()
                    .map_err(|e| format!("读取输出失败：{e}"))?;
                let text = String::from_utf8_lossy(&output.stdout).to_string();
                if status.success() {
                    return Ok(text);
                }
                return Err(format!(
                    "命令退出码 {:?}：{}",
                    status.code(),
                    String::from_utf8_lossy(&output.stderr).trim()
                ));
            }
            Ok(None) => {
                if started.elapsed() >= timeout {
                    let _ = child.kill();
                    let _ = child.wait();
                    return Err(format!("命令超时（{} 秒）", timeout.as_secs()));
                }
                std::thread::sleep(Duration::from_millis(50));
            }
            Err(e) => return Err(format!("等待命令失败：{e}")),
        }
    }
}

/// 以无窗口方式启动进程（RustDesk 会自绘窗口，不需要控制台）。
fn spawn_detached(exe: &Path, args: &[&str]) -> Result<(), String> {
    let mut command = Command::new(exe);
    command.args(args).stdin(Stdio::null());
    #[cfg(windows)]
    {
        use std::os::windows::process::CommandExt;
        command.creation_flags(CREATE_NO_WINDOW);
    }
    command
        .spawn()
        .map(|_| ())
        .map_err(|e| format!("启动 {} 失败：{e}", exe.display()))
}

/* ------------------------------------------------------------------ */
/* 最近设备码存储（JSON，不含任何密钥）                                  */
/* ------------------------------------------------------------------ */

fn recent_path(app: &tauri::AppHandle) -> Result<PathBuf, String> {
    app.path()
        .app_config_dir()
        .map(|dir| dir.join(RECENT_FILE))
        .map_err(|e| format!("取配置目录失败：{e}"))
}

pub fn read_recent_peers_at(path: &Path) -> Vec<String> {
    let Ok(text) = std::fs::read_to_string(path) else {
        return Vec::new();
    };
    #[derive(serde::Deserialize)]
    struct Store {
        #[serde(default)]
        ids: Vec<String>,
    }
    match serde_json::from_str::<Store>(&text) {
        Ok(store) => store
            .ids
            .into_iter()
            .filter(|id| normalize_device_id(id).is_some())
            .take(RECENT_LIMIT)
            .collect(),
        Err(_) => Vec::new(),
    }
}

pub fn push_recent_peer(list: &mut Vec<String>, id: &str) {
    let Some(normalized) = normalize_device_id(id) else {
        return;
    };
    list.retain(|existing| existing != &normalized);
    list.insert(0, normalized);
    list.truncate(RECENT_LIMIT);
}

fn save_recent_peers(app: &tauri::AppHandle, list: &[String]) -> Result<(), String> {
    let path = recent_path(app)?;
    if let Some(parent) = path.parent() {
        std::fs::create_dir_all(parent).map_err(|e| format!("创建配置目录失败：{e}"))?;
    }
    let payload = serde_json::json!({ "ids": list });
    let text = serde_json::to_string_pretty(&payload)
        .map_err(|e| format!("序列化最近设备码失败：{e}"))?;
    write_atomic(&path, &text)
}

/// 原子写：同目录临时文件 + rename，避免面板崩溃留下半个文件。
fn write_atomic(path: &Path, contents: &str) -> Result<(), String> {
    let parent = path
        .parent()
        .ok_or_else(|| "目标路径没有父目录".to_string())?;
    std::fs::create_dir_all(parent).map_err(|e| format!("创建目录失败：{e}"))?;
    let file_name = path
        .file_name()
        .and_then(|n| n.to_str())
        .unwrap_or("rustdesk.toml");
    let tmp = parent.join(format!(".{file_name}.vega-tmp"));
    std::fs::write(&tmp, contents.as_bytes()).map_err(|e| format!("写临时文件失败：{e}"))?;
    std::fs::rename(&tmp, path).map_err(|e| {
        let _ = std::fs::remove_file(&tmp);
        format!("替换目标文件失败：{e}")
    })
}

/* ------------------------------------------------------------------ */
/* 服务 / 进程状态                                                      */
/* ------------------------------------------------------------------ */

#[cfg(windows)]
fn rustdesk_process_running() -> bool {
    match run_capture(
        Path::new("tasklist"),
        &["/FI", "IMAGENAME eq rustdesk.exe", "/NH"],
        CONFIG_TIMEOUT,
    ) {
        Ok(text) => text.to_ascii_lowercase().contains("rustdesk.exe"),
        Err(_) => false,
    }
}

#[cfg(not(windows))]
fn rustdesk_process_running() -> bool {
    false
}

#[cfg(windows)]
fn rustdesk_service_state() -> Option<String> {
    let text = run_capture(Path::new("sc"), &["query", "RustDesk"], CONFIG_TIMEOUT).ok()?;
    for line in text.lines() {
        if line.trim_start().starts_with("STATE") {
            // STATE : 4  RUNNING
            if let Some(state) = line.split_whitespace().last() {
                return Some(state.to_string());
            }
        }
    }
    Some("UNKNOWN".to_string())
}

#[cfg(not(windows))]
fn rustdesk_service_state() -> Option<String> {
    None
}

/* ------------------------------------------------------------------ */
/* 提权安装（复用现有 host 脚本，参数里不带任何密钥）                    */
/* ------------------------------------------------------------------ */

/// 定位 `host/install-host.ps1`：环境变量优先，其次从可执行文件向上找，
/// 最后看 `%ProgramData%\Vega\host\install-host.ps1`。
pub fn locate_host_script() -> Option<PathBuf> {
    if let Some(explicit) = std::env::var_os("VEGA_HOST_SCRIPT") {
        let path = PathBuf::from(explicit);
        if path.is_file() {
            return Some(path);
        }
    }
    if let Ok(exe) = std::env::current_exe() {
        let mut dir = exe.parent().map(Path::to_path_buf);
        for _ in 0..6 {
            let Some(current) = dir else { break };
            let candidate = current.join("host").join("install-host.ps1");
            if candidate.is_file() {
                return Some(candidate);
            }
            dir = current.parent().map(Path::to_path_buf);
        }
    }
    if let Some(program_data) = std::env::var_os("ProgramData") {
        let candidate = PathBuf::from(program_data)
            .join("Vega")
            .join("host")
            .join("install-host.ps1");
        if candidate.is_file() {
            return Some(candidate);
        }
    }
    None
}

#[cfg(windows)]
fn spawn_elevated_host_script(script: &Path) -> Result<(), String> {
    use std::os::windows::process::CommandExt;

    let script = script.display().to_string().replace('\'', "''");
    // 只传 -File <脚本> -WithRustDesk：脚本自己按需安装 RustDesk，不接收密钥。
    let command = format!(
        "Start-Process -FilePath 'powershell.exe' -Verb RunAs -ArgumentList @('-NoProfile','-ExecutionPolicy','Bypass','-File','{script}','-WithRustDesk') -WindowStyle Normal"
    );
    let mut cmd = Command::new("powershell.exe");
    cmd.args([
        "-NoProfile",
        "-NonInteractive",
        "-WindowStyle",
        "Hidden",
        "-Command",
        &command,
    ])
    .stdin(Stdio::null())
    .creation_flags(CREATE_NO_WINDOW);
    cmd.spawn()
        .map(|_| ())
        .map_err(|e| format!("调起安装脚本失败：{e}"))
}

#[cfg(not(windows))]
fn spawn_elevated_host_script(_script: &Path) -> Result<(), String> {
    Err(NOT_INSTALLED.to_string())
}

/* ------------------------------------------------------------------ */
/* Tauri 命令                                                          */
/* ------------------------------------------------------------------ */

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
pub struct DeviceInfo {
    pub installed: bool,
    pub id: String,
    pub formatted_id: String,
    pub path: String,
    pub error: String,
}

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
pub struct ServerConfigView {
    pub server: String,
    pub relay: String,
    pub key_fingerprint: String,
    pub key_present: bool,
    pub path: String,
    pub error: String,
}

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
pub struct OpResult {
    pub ok: bool,
    pub message: String,
}

impl OpResult {
    fn ok(message: impl Into<String>) -> Self {
        Self {
            ok: true,
            message: message.into(),
        }
    }
    fn err(message: impl Into<String>) -> Self {
        Self {
            ok: false,
            message: message.into(),
        }
    }
}

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
pub struct StatusView {
    pub installed: bool,
    pub running: bool,
    pub service_state: String,
    pub message: String,
}

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
pub struct TestResult {
    pub ok: bool,
    pub message: String,
    pub latency_ms: u64,
}

#[tauri::command]
pub fn get_device_id() -> DeviceInfo {
    let Some(exe) = locate_rustdesk() else {
        return DeviceInfo {
            installed: false,
            id: String::new(),
            formatted_id: String::new(),
            path: String::new(),
            error: NOT_INSTALLED.to_string(),
        };
    };
    let path = exe.display().to_string();
    match run_capture(&exe, &["--get-id"], CONFIG_TIMEOUT) {
        Ok(stdout) => match extract_device_id(&stdout) {
            Some(id) => DeviceInfo {
                installed: true,
                formatted_id: format_device_id(&id),
                id,
                path,
                error: String::new(),
            },
            None => DeviceInfo {
                installed: true,
                id: String::new(),
                formatted_id: String::new(),
                path,
                error: "rustdesk.exe --get-id 没有输出可用设备码".into(),
            },
        },
        Err(e) => DeviceInfo {
            installed: true,
            id: String::new(),
            formatted_id: String::new(),
            path,
            error: format!("读取设备码失败：{e}"),
        },
    }
}

#[tauri::command]
pub fn get_server_config() -> ServerConfigView {
    let Some(path) = user_config_path() else {
        return ServerConfigView {
            server: String::new(),
            relay: String::new(),
            key_fingerprint: String::new(),
            key_present: false,
            path: String::new(),
            error: "找不到 %APPDATA%\\RustDesk\\config\\RustDesk2.toml".into(),
        };
    };
    let display = path.display().to_string();
    let text = match std::fs::read_to_string(&path) {
        Ok(text) => text,
        Err(e) if e.kind() == std::io::ErrorKind::NotFound => {
            return ServerConfigView {
                server: String::new(),
                relay: String::new(),
                key_fingerprint: String::new(),
                key_present: false,
                path: display,
                error: format!("{NOT_INSTALLED} 或还没登录过（配置尚未生成）"),
            };
        }
        Err(e) => {
            return ServerConfigView {
                server: String::new(),
                relay: String::new(),
                key_fingerprint: String::new(),
                key_present: false,
                path: display,
                error: format!("读取配置失败：{e}"),
            };
        }
    };
    match read_server_config(&text) {
        Ok(snapshot) => ServerConfigView {
            server: snapshot.server,
            relay: snapshot.relay,
            key_fingerprint: snapshot.key_fingerprint(),
            key_present: snapshot.key_present(),
            path: display,
            error: String::new(),
        },
        Err(error) => ServerConfigView {
            server: String::new(),
            relay: String::new(),
            key_fingerprint: String::new(),
            key_present: false,
            path: display,
            error,
        },
    }
}

/// 写 `[options]` 三个键。`key` 为空表示保留现有公钥（前端只拿到指纹，
/// 不显示完整公钥，所以留空保存不能把公钥清掉）。
#[tauri::command]
pub fn set_server_config(server: String, key: String, relay: Option<String>) -> OpResult {
    let server = match validate_server(&server) {
        Ok(value) => value,
        Err(e) => return OpResult::err(e),
    };
    let relay_input = relay.unwrap_or_default();
    let relay = if relay_input.trim().is_empty() {
        server.clone()
    } else {
        match validate_server(&relay_input) {
            Ok(value) => value,
            Err(e) => return OpResult::err(format!("中继服务器：{e}")),
        }
    };

    let Some(path) = user_config_path() else {
        return OpResult::err("找不到 RustDesk 配置目录（%APPDATA% 缺失）");
    };
    let existing = std::fs::read_to_string(&path).unwrap_or_default();
    let existing_snapshot = read_server_config(&existing).unwrap_or_default();

    let key = if key.trim().is_empty() {
        if existing_snapshot.key.is_empty() {
            return OpResult::err("公钥不能为空（当前配置里也没有可沿用的公钥）");
        }
        existing_snapshot.key
    } else {
        match validate_key(&key) {
            Ok(value) => value,
            Err(e) => return OpResult::err(e),
        }
    };

    let merged = match merge_server_config(&existing, &server, &relay, &key) {
        Ok(text) => text,
        Err(e) => return OpResult::err(e),
    };
    // 只写文件，不打印内容：公钥不进日志。
    if let Err(e) = write_atomic(&path, &merged) {
        return OpResult::err(e);
    }
    OpResult::ok("已保存，重启 RustDesk 后生效")
}

#[tauri::command]
pub fn connect_peer(peer_id: String, mode: String, app: tauri::AppHandle) -> OpResult {
    let Some(id) = normalize_device_id(&peer_id) else {
        return OpResult::err("设备码必须是 9-10 位数字");
    };
    let Some(exe) = locate_rustdesk() else {
        return OpResult::err(NOT_INSTALLED);
    };
    let args = match mode.as_str() {
        "file" => vec!["--file-transfer", id.as_str()],
        _ => vec!["--connect", id.as_str()],
    };
    if let Err(e) = spawn_detached(&exe, &args) {
        return OpResult::err(e);
    }
    let mut list = recent_path(&app)
        .map(|path| read_recent_peers_at(&path))
        .unwrap_or_default();
    push_recent_peer(&mut list, &id);
    if let Err(e) = save_recent_peers(&app, &list) {
        return OpResult {
            ok: true,
            message: format!("已发起连接，但最近设备码没保存：{e}"),
        };
    }
    OpResult::ok("已发起连接，请在 RustDesk 窗口输入对方临时密码")
}

#[tauri::command]
pub fn get_recent_peers(app: tauri::AppHandle) -> Vec<String> {
    recent_path(&app)
        .map(|path| read_recent_peers_at(&path))
        .unwrap_or_default()
}

/// 「显示临时密码」：只是打开 RustDesk 主窗口，控制台不读取密码。
#[tauri::command]
pub fn open_rustdesk_window() -> OpResult {
    let Some(exe) = locate_rustdesk() else {
        return OpResult::err(NOT_INSTALLED);
    };
    match spawn_detached(&exe, &[]) {
        Ok(()) => OpResult::ok("已打开 RustDesk 主窗口，请在其中查看临时密码"),
        Err(e) => OpResult::err(e),
    }
}

#[tauri::command]
pub fn get_rustdesk_status() -> StatusView {
    let Some(_exe) = locate_rustdesk() else {
        return StatusView {
            installed: false,
            running: false,
            service_state: String::new(),
            message: NOT_INSTALLED.to_string(),
        };
    };
    let running = rustdesk_process_running();
    let service_state = rustdesk_service_state().unwrap_or_default();
    let message = if running {
        format!("RustDesk 正在运行（服务：{}）", if service_state.is_empty() { "未安装" } else { &service_state })
    } else if !service_state.is_empty() {
        format!("RustDesk 已安装，服务状态 {service_state}，进程未运行")
    } else {
        "RustDesk 已安装，但当前没有运行".to_string()
    };
    StatusView {
        installed: true,
        running,
        service_state,
        message,
    }
}

#[tauri::command]
pub fn install_rustdesk() -> OpResult {
    let Some(script) = locate_host_script() else {
        return OpResult::err("找不到 host/install-host.ps1，请先用一行安装脚本部署仓库");
    };
    match spawn_elevated_host_script(&script) {
        Ok(()) => OpResult::ok("已弹出管理员授权，安装完成后回到这里刷新状态"),
        Err(e) => OpResult::err(e),
    }
}

#[tauri::command]
pub fn test_server_connection(server: String) -> TestResult {
    let (host, port) = match endpoint_from_server(&server) {
        Ok(value) => value,
        Err(e) => {
            return TestResult {
                ok: false,
                message: e,
                latency_ms: 0,
            }
        }
    };
    let addrs: Vec<SocketAddr> = match (host.as_str(), port).to_socket_addrs() {
        Ok(iter) => iter.collect(),
        Err(e) => {
            return TestResult {
                ok: false,
                message: format!("解析 {host}:{port} 失败：{e}"),
                latency_ms: 0,
            }
        }
    };
    if addrs.is_empty() {
        return TestResult {
            ok: false,
            message: format!("解析 {host}:{port} 没有结果"),
            latency_ms: 0,
        };
    }
    let started = Instant::now();
    let mut last_error = String::new();
    for addr in addrs {
        match TcpStream::connect_timeout(&addr, TEST_TIMEOUT) {
            Ok(_) => {
                return TestResult {
                    ok: true,
                    message: format!("TCP {addr} 连接成功"),
                    latency_ms: started.elapsed().as_millis() as u64,
                };
            }
            Err(e) => last_error = format!("{addr}: {e}"),
        }
    }
    TestResult {
        ok: false,
        message: format!("TCP 连接失败（3 秒超时）：{last_error}"),
        latency_ms: started.elapsed().as_millis() as u64,
    }
}

/// 托盘「复制设备码」用：拿设备码写到剪贴板，不经过前端。
pub fn copy_device_id_to_clipboard() -> Result<String, String> {
    let info = get_device_id();
    if info.formatted_id.is_empty() {
        return Err(if info.error.is_empty() {
            NOT_INSTALLED.to_string()
        } else {
            info.error
        });
    }
    #[cfg(windows)]
    {
        let value = info.formatted_id.replace('\'', "''");
        let command = format!("Set-Clipboard -Value '{value}'");
        let mut cmd = Command::new("powershell.exe");
        use std::os::windows::process::CommandExt;
        cmd.args(["-NoProfile", "-NonInteractive", "-Command", &command])
            .stdin(Stdio::null())
            .creation_flags(CREATE_NO_WINDOW);
        cmd.spawn()
            .map_err(|e| format!("写剪贴板失败：{e}"))?;
        Ok(info.formatted_id)
    }
    #[cfg(not(windows))]
    {
        Err(NOT_INSTALLED.to_string())
    }
}

/* ------------------------------------------------------------------ */
/* 单元测试                                                            */
/* ------------------------------------------------------------------ */

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn device_id_accepts_nine_and_ten_digits() {
        assert_eq!(normalize_device_id("123456789"), Some("123456789".into()));
        assert_eq!(normalize_device_id("123 456 789"), Some("123456789".into()));
        assert_eq!(normalize_device_id("123-456-7890"), Some("1234567890".into()));
        assert_eq!(normalize_device_id("12345678"), None);
        assert_eq!(normalize_device_id("12345678901"), None);
        assert_eq!(normalize_device_id("abc"), None);
    }

    #[test]
    fn device_id_extract_ignores_version_lines() {
        let stdout = "1.3.2\n123 456 789\n";
        assert_eq!(extract_device_id(stdout), Some("123456789".into()));
        assert_eq!(extract_device_id("no id here"), None);
    }

    #[test]
    fn device_id_format_is_three_three_three() {
        assert_eq!(format_device_id("123456789"), "123-456-789");
        assert_eq!(format_device_id("1234567890"), "123-456-7890");
        assert_eq!(format_device_id("short"), "short");
    }

    #[test]
    fn server_validation_accepts_host_and_port() {
        assert_eq!(validate_server("relay.example.com").unwrap(), "relay.example.com");
        assert_eq!(validate_server(" 1.2.3.4:21117 ").unwrap(), "1.2.3.4:21117");
        assert_eq!(validate_server("[::1]:21116").unwrap(), "[::1]:21116");
        assert!(validate_server("").is_err());
        assert!(validate_server("host:99999").is_err());
        assert!(validate_server("host:abc").is_err());
        assert!(validate_server("bad host").is_err());
        assert!(validate_server("host/path").is_err());
        assert!(validate_server("-bad.example.com").is_err());
        assert!(validate_server("host:0").is_err());
    }

    #[test]
    fn endpoint_defaults_to_rustdesk_port() {
        assert_eq!(
            endpoint_from_server("relay.example.com").unwrap(),
            ("relay.example.com".to_string(), 21116)
        );
        assert_eq!(
            endpoint_from_server("relay.example.com:21117").unwrap(),
            ("relay.example.com".to_string(), 21117)
        );
    }

    #[test]
    fn key_validation_requires_44_base64_chars() {
        let valid = "A".repeat(43) + "=";
        assert_eq!(validate_key(&valid).unwrap(), valid);
        // 从输入框粘贴可能带换行/空格，清洗后仍是 44 字符。
        assert_eq!(validate_key(&format!("  {valid}\n")).unwrap(), valid);
        assert!(validate_key("").is_err());
        assert!(validate_key(&"A".repeat(43)).is_err());
        assert!(validate_key(&("A".repeat(45))).is_err());
        assert!(validate_key(&(format!("{}!", "A".repeat(43)))).is_err());
        assert_eq!(key_fingerprint(&valid), "AAAAAAAA");
    }

    #[test]
    fn toml_reads_managed_keys() {
        let text = r#"
[options]
custom-rendezvous-server = "relay.example.com"
relay-server = "relay.example.com:21117"
key = "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA="
other = "keep"
"#;
        let snapshot = read_server_config(text).unwrap();
        assert_eq!(snapshot.server, "relay.example.com");
        assert_eq!(snapshot.relay, "relay.example.com:21117");
        assert!(snapshot.key_present());
        assert_eq!(snapshot.key_fingerprint(), "AAAAAAAA");
    }

    #[test]
    fn toml_merge_preserves_other_keys_and_sections() {
        let original = r#"
[options]
custom-rendezvous-server = "old.example.com"
relay-server = "old.example.com"
key = "OLDKEY"
other = "keep"
password = "not-managed"

[other-section]
flag = true
"#;
        let key = "B".repeat(43) + "=";
        let merged = merge_server_config(original, "new.example.com", "relay.example.com:21117", &key).unwrap();
        let snapshot = read_server_config(&merged).unwrap();
        assert_eq!(snapshot.server, "new.example.com");
        assert_eq!(snapshot.relay, "relay.example.com:21117");
        assert_eq!(snapshot.key, key);

        let reparsed: toml::Table = merged.parse().unwrap();
        let options = reparsed.get("options").unwrap().as_table().unwrap();
        assert_eq!(options.get("other").unwrap().as_str().unwrap(), "keep");
        assert_eq!(options.get("password").unwrap().as_str().unwrap(), "not-managed");
        let other = reparsed.get("other-section").unwrap().as_table().unwrap();
        assert_eq!(other.get("flag").unwrap().as_bool().unwrap(), true);
    }

    #[test]
    fn toml_merge_creates_options_table_when_missing() {
        let merged = merge_server_config("", "relay.example.com", "relay.example.com", "KEY").unwrap();
        let snapshot = read_server_config(&merged).unwrap();
        assert_eq!(snapshot.server, "relay.example.com");
        assert_eq!(snapshot.relay, "relay.example.com");
        assert_eq!(snapshot.key, "KEY");
    }

    #[test]
    fn toml_merge_rejects_non_table_options() {
        assert!(merge_server_config("options = 1", "h", "h", "k").is_err());
    }

    #[test]
    fn recent_peers_dedup_and_truncate() {
        let mut list = Vec::new();
        for id in ["111111111", "222222222", "333333333"] {
            push_recent_peer(&mut list, id);
        }
        push_recent_peer(&mut list, "222222222");
        assert_eq!(list.first().unwrap(), "222222222");
        assert_eq!(list.len(), 3);

        for i in 0..15 {
            push_recent_peer(&mut list, &format!("{:09}", i + 1000));
        }
        assert_eq!(list.len(), RECENT_LIMIT);
    }

    #[test]
    fn recent_peers_round_trip_file() {
        let dir = std::env::temp_dir().join(format!("vega-recent-test-{}", std::process::id()));
        std::fs::create_dir_all(&dir).unwrap();
        let path = dir.join("recent-ids.json");
        save_recent_peers_to_path(&path, &["123456789".to_string()]).unwrap();
        assert_eq!(read_recent_peers_at(&path), vec!["123456789".to_string()]);
        let _ = std::fs::remove_dir_all(&dir);
    }

    fn save_recent_peers_to_path(path: &Path, list: &[String]) -> Result<(), String> {
        let payload = serde_json::json!({ "ids": list });
        let text = serde_json::to_string_pretty(&payload).map_err(|e| e.to_string())?;
        write_atomic(path, &text)
    }
}
