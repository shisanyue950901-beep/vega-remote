//! RustDesk 集成（M2b）。
//!
//! 约定（继承 T1/T2 安全约束）：
//! - 不读取、不保存、不通过命令行传递临时密码。密码只由 RustDesk 自己管理，
//!   控制台只负责打开 RustDesk 主窗口让用户自己看。
//! - 服务器公钥从不写日志；对外只暴露前 8 位指纹。
//! - 非 Windows 平台一律返回「未安装 RustDesk」，不 spawn 任何进程。

use serde::Serialize;
use std::fs::OpenOptions;
use std::io::Write;
use std::net::{Ipv4Addr, Ipv6Addr, SocketAddr, TcpStream, ToSocketAddrs};
use std::path::{Path, PathBuf};
use std::process::{Command, Stdio};
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::mpsc;
use std::time::{Duration, Instant};

use tauri::Manager;

const RUSTDESK_EXE: &str = "rustdesk.exe";
const NOT_INSTALLED: &str = "未安装 RustDesk";
const CONFIG_TIMEOUT: Duration = Duration::from_secs(5);
const TEST_TIMEOUT: Duration = Duration::from_secs(3);
/// 跨实例写配置时等锁的上限；超时宁可报错也不覆盖别人刚写的文件。
const LOCK_TIMEOUT: Duration = Duration::from_secs(3);
/// 锁文件的陈旧判定：进程崩溃留下的锁超过这个时间视为可回收。
const STALE_LOCK_AGE: Duration = Duration::from_secs(30);

/// 原子写临时文件序号，保证同名写入之间不会互相覆盖临时文件。
static TMP_SEQ: AtomicU64 = AtomicU64::new(0);
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
        // 方括号只允许包 IPv6：`[example.com]` 不是合法写法。
        if host.parse::<Ipv6Addr>().is_err() {
            return Err("方括号里必须是合法的 IPv6 地址".to_string());
        }
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
    // 逐标签按 DNS 规则校验：1-63 字符，字母/数字/连字符，首尾不能是连字符。
    let labels: Vec<&str> = host.split('.').collect();
    for label in &labels {
        if label.is_empty() {
            return Err("主机名包含空标签".into());
        }
        if label.len() > 63 {
            return Err("主机名单个标签过长（上限 63 字符）".into());
        }
        if !label
            .chars()
            .all(|c| c.is_ascii_alphanumeric() || c == '-')
        {
            return Err("主机名标签只能包含字母、数字和连字符".into());
        }
        if label.starts_with('-') || label.ends_with('-') {
            return Err("主机名标签不能以连字符开头或结尾".into());
        }
    }
    // 全数字的标签组合只可能是 IPv4；解析失败说明是个伪 IP（如 999.1.1.1）。
    if labels
        .iter()
        .all(|label| label.chars().all(|c| c.is_ascii_digit()))
    {
        return Err("IPv4 地址格式无效".into());
    }
    Ok(())
}

/// 公钥必须是 44 个 base64 字符（末尾恰好 1 个 `=`），解码后正好 32 字节。
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
    // 只允许末尾一个填充符：中间的 `=` 或不填充都拒绝。
    let body = key.strip_suffix('=').unwrap_or("");
    if body.is_empty() || body.len() != 43 || body.contains('=') {
        return Err("公钥 base64 填充位置无效".into());
    }
    let decoded = decode_base64(body.as_bytes())
        .ok_or_else(|| "公钥不是合法的 base64".to_string())?;
    if decoded.len() != 32 {
        return Err(format!(
            "公钥必须是 32 字节（解码后 {} 字节）",
            decoded.len()
        ));
    }
    Ok(key)
}

/// 严格 base64 解码：拒绝非法字符、非零填充位。43 字符应得到 32 字节。
fn decode_base64(data: &[u8]) -> Option<Vec<u8>> {
    let mut out = Vec::with_capacity(data.len() * 3 / 4);
    let mut buffer: u32 = 0;
    let mut bits: u32 = 0;
    for &byte in data {
        let value = match byte {
            b'A'..=b'Z' => byte - b'A',
            b'a'..=b'z' => byte - b'a' + 26,
            b'0'..=b'9' => byte - b'0' + 52,
            b'+' => 62,
            b'/' => 63,
            _ => return None,
        };
        buffer = (buffer << 6) | u32::from(value);
        bits += 6;
        if bits >= 8 {
            bits -= 8;
            out.push(((buffer >> bits) & 0xff) as u8);
            buffer &= (1 << bits) - 1;
        }
    }
    // 剩余不足一字节的位必须为 0，否则不是规范编码。
    if bits > 0 && buffer != 0 {
        return None;
    }
    Some(out)
}

/// IPC 入口：设备码只接受 9-10 位 ASCII 数字，不做任何字符清洗。
pub fn parse_peer_id(raw: &str) -> Result<String, String> {
    let value = raw.trim();
    if !value.is_empty() && value.chars().all(|c| c.is_ascii_digit()) {
        if value.len() == 9 || value.len() == 10 {
            return Ok(value.to_string());
        }
    }
    Err("设备码必须是 9-10 位数字".into())
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

/// 只回位置、不回原文：toml 的 Display 会把出错那行源码带出来，
/// 可能包含公钥或别的配置值，不能经 IPC 回给前端。
fn toml_parse_error(err: &toml::de::Error, text: &str) -> String {
    let location = err
        .span()
        .and_then(|span| {
            let end = span.start.min(text.len());
            if text.is_char_boundary(end) {
                Some(text[..end].matches('\n').count() + 1)
            } else {
                None
            }
        })
        .map(|line| format!("第 {line} 行附近"))
        .unwrap_or_else(|| "位置未知".to_string());
    format!("RustDesk2.toml 解析失败（{location}），请检查文件格式")
}

/// 解析 TOML 文本，只取 `[options]` 下的受管键；其他键保持不动。
pub fn read_server_config(text: &str) -> Result<ServerSnapshot, String> {
    if text.trim().is_empty() {
        return Ok(ServerSnapshot::default());
    }
    let doc: toml::Table =
        toml::from_str(text).map_err(|e| toml_parse_error(&e, text))?;
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
        toml::from_str(text).map_err(|e| toml_parse_error(&e, text))?
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

/// 读现有配置：只有「文件不存在」才当空文件；权限错误、非法 UTF-8 等
/// 必须中止，否则保存会用一个只含三个受管键的新文件覆盖掉用户原配置。
fn read_existing_config(path: &Path) -> Result<String, String> {
    match std::fs::read_to_string(path) {
        Ok(text) => Ok(text),
        Err(e) if e.kind() == std::io::ErrorKind::NotFound => Ok(String::new()),
        Err(e) => Err(format!("读取现有 RustDesk 配置失败，已中止保存：{e}")),
    }
}

/// 跨进程配置锁：同目录 `*.vega-lock`，`create_new` 保证只有一个实例拿到。
struct ConfigLock {
    path: PathBuf,
}

impl Drop for ConfigLock {
    fn drop(&mut self) {
        let _ = std::fs::remove_file(&self.path);
    }
}

fn acquire_config_lock(target: &Path) -> Result<ConfigLock, String> {
    if let Some(parent) = target.parent() {
        std::fs::create_dir_all(parent).map_err(|e| format!("创建配置目录失败：{e}"))?;
    }
    let mut name = target.as_os_str().to_os_string();
    name.push(".vega-lock");
    let lock_path = PathBuf::from(name);
    let started = Instant::now();
    loop {
        match OpenOptions::new()
            .write(true)
            .create_new(true)
            .open(&lock_path)
        {
            Ok(mut file) => {
                let _ = writeln!(file, "{}", std::process::id());
                return Ok(ConfigLock { path: lock_path });
            }
            Err(e) if e.kind() == std::io::ErrorKind::AlreadyExists => {
                // 崩溃留下的陈旧锁：超过 STALE_LOCK_AGE 直接回收。
                let stale = std::fs::metadata(&lock_path)
                    .and_then(|meta| meta.modified())
                    .ok()
                    .and_then(|modified| modified.elapsed().ok())
                    .map(|age| age > STALE_LOCK_AGE)
                    .unwrap_or(false);
                if stale {
                    let _ = std::fs::remove_file(&lock_path);
                    continue;
                }
                if started.elapsed() >= LOCK_TIMEOUT {
                    return Err(
                        "另一个 Vega 窗口正在保存 RustDesk 配置，请稍后重试".to_string()
                    );
                }
                std::thread::sleep(Duration::from_millis(50));
            }
            Err(e) => return Err(format!("创建配置锁失败：{e}")),
        }
    }
}

/// 原子写：同目录临时文件 + rename。临时文件用 `create_new` 独占创建，
/// 文件名带进程号与序号，两个 Vega 实例不会互相踩到对方的临时文件。
fn write_atomic(path: &Path, contents: &str) -> Result<(), String> {
    let parent = path
        .parent()
        .ok_or_else(|| "目标路径没有父目录".to_string())?;
    std::fs::create_dir_all(parent).map_err(|e| format!("创建目录失败：{e}"))?;
    let file_name = path
        .file_name()
        .and_then(|n| n.to_str())
        .unwrap_or("rustdesk.toml");
    let seq = TMP_SEQ.fetch_add(1, Ordering::Relaxed);
    let tmp = parent.join(format!(
        ".{file_name}.{}.{seq}.vega-tmp",
        std::process::id()
    ));
    let mut file = OpenOptions::new()
        .write(true)
        .create_new(true)
        .open(&tmp)
        .map_err(|e| format!("创建临时文件失败：{e}"))?;
    let result = file
        .write_all(contents.as_bytes())
        .and_then(|()| file.sync_all());
    drop(file);
    if let Err(e) = result {
        let _ = std::fs::remove_file(&tmp);
        return Err(format!("写临时文件失败：{e}"));
    }
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
pub async fn get_device_id() -> DeviceInfo {
    // --get-id 最多等 5 秒，不能卡在 Tauri 主线程上。
    tauri::async_runtime::spawn_blocking(get_device_id_blocking)
        .await
        .unwrap_or_else(|e| DeviceInfo {
            installed: false,
            id: String::new(),
            formatted_id: String::new(),
            path: String::new(),
            error: format!("读取设备码线程失败：{e}"),
        })
}

fn get_device_id_blocking() -> DeviceInfo {
    if !cfg!(windows) {
        return DeviceInfo {
            installed: false,
            id: String::new(),
            formatted_id: String::new(),
            path: String::new(),
            error: NOT_INSTALLED.to_string(),
        };
    }
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
    if !cfg!(windows) {
        return ServerConfigView {
            server: String::new(),
            relay: String::new(),
            key_fingerprint: String::new(),
            key_present: false,
            path: String::new(),
            error: NOT_INSTALLED.to_string(),
        };
    }
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
        Ok(snapshot) => {
            // 先算指纹/存在性，再移动 server/relay：否则会借用已移出的 snapshot。
            let key_fingerprint = snapshot.key_fingerprint();
            let key_present = snapshot.key_present();
            ServerConfigView {
                server: snapshot.server,
                relay: snapshot.relay,
                key_fingerprint,
                key_present,
                path: display,
                error: String::new(),
            }
        }
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
pub async fn set_server_config(server: String, key: String, relay: Option<String>) -> OpResult {
    // 等跨实例锁最多 3 秒，加上磁盘写入，不能占着 UI 线程。
    tauri::async_runtime::spawn_blocking(move || set_server_config_blocking(server, key, relay))
        .await
        .unwrap_or_else(|e| OpResult::err(format!("保存配置线程失败：{e}")))
}

fn set_server_config_blocking(
    server: String,
    key: String,
    relay: Option<String>,
) -> OpResult {
    if !cfg!(windows) {
        return OpResult::err(NOT_INSTALLED);
    }
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
    // 从读现有内容到替换文件全程持锁：两个 Vega 实例同时保存时后者等锁，
    // 不会各自基于旧内容 merge，把对方刚写的键覆盖回去。
    let _lock = match acquire_config_lock(&path) {
        Ok(lock) => lock,
        Err(e) => return OpResult::err(e),
    };
    let existing = match read_existing_config(&path) {
        Ok(text) => text,
        Err(e) => return OpResult::err(e),
    };
    let existing_snapshot = match read_server_config(&existing) {
        Ok(snapshot) => snapshot,
        Err(e) => return OpResult::err(e),
    };

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
    if !cfg!(windows) {
        return OpResult::err(NOT_INSTALLED);
    }
    // IPC 入口不做字符清洗：多余字符、11 位、8 位一律拒绝，不猜用户想连哪台。
    let id = match parse_peer_id(&peer_id) {
        Ok(id) => id,
        Err(e) => return OpResult::err(e),
    };
    let Some(exe) = locate_rustdesk() else {
        return OpResult::err(NOT_INSTALLED);
    };
    let args = match mode.as_str() {
        "control" => vec!["--connect", id.as_str()],
        "file" => vec!["--file-transfer", id.as_str()],
        _ => return OpResult::err("未知连接模式（只支持 control 或 file）"),
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
    if !cfg!(windows) {
        return Vec::new();
    }
    recent_path(&app)
        .map(|path| read_recent_peers_at(&path))
        .unwrap_or_default()
}

/// 「显示临时密码」：只是打开 RustDesk 主窗口，控制台不读取密码。
#[tauri::command]
pub fn open_rustdesk_window() -> OpResult {
    if !cfg!(windows) {
        return OpResult::err(NOT_INSTALLED);
    }
    let Some(exe) = locate_rustdesk() else {
        return OpResult::err(NOT_INSTALLED);
    };
    match spawn_detached(&exe, &[]) {
        Ok(()) => OpResult::ok("已打开 RustDesk 主窗口，请在其中查看临时密码"),
        Err(e) => OpResult::err(e),
    }
}

#[tauri::command]
pub async fn get_rustdesk_status() -> StatusView {
    // tasklist / sc 各最多 5 秒，全部挪到阻塞线程池。
    tauri::async_runtime::spawn_blocking(get_rustdesk_status_blocking)
        .await
        .unwrap_or_else(|e| StatusView {
            installed: false,
            running: false,
            service_state: String::new(),
            message: format!("读取 RustDesk 状态线程失败：{e}"),
        })
}

fn get_rustdesk_status_blocking() -> StatusView {
    if !cfg!(windows) {
        return StatusView {
            installed: false,
            running: false,
            service_state: String::new(),
            message: NOT_INSTALLED.to_string(),
        };
    }
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
        format!(
            "RustDesk 正在运行（服务：{}）",
            if service_state.is_empty() {
                "未安装"
            } else {
                service_state.as_str()
            }
        )
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

/// DNS 解析放在独立线程里，用 channel 超时收结果：`to_socket_addrs` 本身
/// 没有超时参数，直接调用可能把命令拖住很久。
fn resolve_with_timeout(host: &str, port: u16, timeout: Duration) -> Result<Vec<SocketAddr>, String> {
    let (tx, rx) = mpsc::channel();
    let lookup_host = host.to_string();
    std::thread::spawn(move || {
        let result = (lookup_host.as_str(), port)
            .to_socket_addrs()
            .map(|iter| iter.collect::<Vec<_>>())
            .map_err(|e| e.to_string());
        let _ = tx.send(result);
    });
    match rx.recv_timeout(timeout) {
        Ok(Ok(addrs)) => Ok(addrs),
        Ok(Err(e)) => Err(format!("解析 {host}:{port} 失败：{e}")),
        Err(_) => Err(format!("解析 {host}:{port} 超时（{} 秒）", timeout.as_secs())),
    }
}

/// 纯阻塞探测：解析和所有连接尝试共用一个 3 秒 deadline，不会每换一个
/// 地址就重新计 3 秒。命令层用 `spawn_blocking` 把它挪出 UI 线程。
fn probe_server(server: &str) -> TestResult {
    let started = Instant::now();
    let deadline = started + TEST_TIMEOUT;
    let (host, port) = match endpoint_from_server(server) {
        Ok(value) => value,
        Err(e) => {
            return TestResult {
                ok: false,
                message: e,
                latency_ms: 0,
            }
        }
    };
    let remaining = deadline.saturating_duration_since(Instant::now());
    let addrs = match resolve_with_timeout(&host, port, remaining) {
        Ok(addrs) => addrs,
        Err(e) => {
            return TestResult {
                ok: false,
                message: e,
                latency_ms: started.elapsed().as_millis() as u64,
            }
        }
    };
    if addrs.is_empty() {
        return TestResult {
            ok: false,
            message: format!("解析 {host}:{port} 没有结果"),
            latency_ms: started.elapsed().as_millis() as u64,
        };
    }
    let mut last_error = String::new();
    for addr in addrs {
        let remaining = deadline.saturating_duration_since(Instant::now());
        if remaining.is_zero() {
            last_error = "总超时已用完".to_string();
            break;
        }
        match TcpStream::connect_timeout(&addr, remaining) {
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
        message: format!(
            "TCP 连接失败（{} 秒总超时）：{last_error}",
            TEST_TIMEOUT.as_secs()
        ),
        latency_ms: started.elapsed().as_millis() as u64,
    }
}

#[tauri::command]
pub async fn test_server_connection(server: String) -> TestResult {
    if !cfg!(windows) {
        return TestResult {
            ok: false,
            message: NOT_INSTALLED.to_string(),
            latency_ms: 0,
        };
    }
    tauri::async_runtime::spawn_blocking(move || probe_server(&server))
        .await
        .unwrap_or_else(|e| TestResult {
            ok: false,
            message: format!("连接测试线程失败：{e}"),
            latency_ms: 0,
        })
}

/// 托盘「复制设备码」用：拿设备码写到剪贴板，不经过前端。
#[cfg(windows)]
pub fn copy_device_id_to_clipboard() -> Result<String, String> {
    // 托盘回调本身已在非 UI 线程跑，直接调阻塞实现，不要 await 命令。
    let info = get_device_id_blocking();
    if info.formatted_id.is_empty() {
        return Err(if info.error.is_empty() {
            NOT_INSTALLED.to_string()
        } else {
            info.error
        });
    }
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
pub fn copy_device_id_to_clipboard() -> Result<String, String> {
    Err(NOT_INSTALLED.to_string())
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

        let reparsed: toml::Table = toml::from_str(&merged).unwrap();
        let options = reparsed.get("options").unwrap().as_table().unwrap();
        assert_eq!(options.get("other").unwrap().as_str().unwrap(), "keep");
        assert_eq!(options.get("password").unwrap().as_str().unwrap(), "not-managed");
        let other = reparsed.get("other-section").unwrap().as_table().unwrap();
        assert!(other.get("flag").unwrap().as_bool().unwrap());
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
        assert_eq!(list.first().unwrap().as_str(), "222222222");
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

    fn temp_dir(tag: &str) -> PathBuf {
        let seq = TMP_SEQ.fetch_add(1, Ordering::Relaxed);
        let dir = std::env::temp_dir().join(format!(
            "vega-{tag}-{}-{seq}",
            std::process::id()
        ));
        std::fs::create_dir_all(&dir).unwrap();
        dir
    }

    #[test]
    fn peer_id_requires_nine_or_ten_digits_without_cleaning() {
        assert_eq!(parse_peer_id("123456789").unwrap(), "123456789");
        assert_eq!(parse_peer_id("1234567890").unwrap(), "1234567890");
        assert!(parse_peer_id("12345678").is_err());
        assert!(parse_peer_id("12345678901").is_err());
        assert!(parse_peer_id("123 456 789").is_err());
        assert!(parse_peer_id("12345678a").is_err());
        assert!(parse_peer_id("").is_err());
    }

    #[test]
    fn server_validation_rejects_malformed_hosts() {
        // 方括号里只能是 IPv6，不能拿它包 DNS 名。
        assert!(validate_server("[example.com]:21116").is_err());
        assert!(validate_server("[not-ipv6]").is_err());
        // 下划线、空标签、伪 IPv4 都不是合法主机名。
        assert!(validate_server("bad_host.example.com").is_err());
        assert!(validate_server("a..b").is_err());
        assert!(validate_server("999.1.1.1").is_err());
        assert!(validate_server("host:21116:1").is_err());
    }

    #[test]
    fn key_validation_rejects_interior_padding_and_bad_bits() {
        // 中间的 `=` 不能当填充符。
        let interior = format!("{}={}=", "A".repeat(20), "A".repeat(22));
        assert_eq!(interior.len(), 44);
        assert!(validate_key(&interior).is_err());
        // 43 位正文的末尾填充位必须为 0，否则不是规范 base64。
        let bad_bits = format!("{}B=", "A".repeat(42));
        assert_eq!(bad_bits.len(), 44);
        assert!(validate_key(&bad_bits).is_err());
        assert!(validate_key(&("A".repeat(44))).is_err());
    }

    #[test]
    fn toml_parse_error_does_not_echo_source_line() {
        let secret = "SUPERSECRETKEYVALUE";
        let text = format!("[options]\nkey = \"{secret}\"\nbroken = \n");
        let error = read_server_config(&text).unwrap_err();
        assert!(!error.contains(secret));
        assert!(error.contains("解析失败"));
    }

    #[test]
    fn write_atomic_replaces_existing_file_and_leaves_no_temp() {
        let dir = temp_dir("atomic");
        let path = dir.join("RustDesk2.toml");
        write_atomic(&path, "[options]\nother = \"first\"\n").unwrap();
        write_atomic(&path, "[options]\nother = \"second\"\n").unwrap();
        let text = std::fs::read_to_string(&path).unwrap();
        assert!(text.contains("second"));
        let leftovers: Vec<_> = std::fs::read_dir(&dir)
            .unwrap()
            .filter_map(Result::ok)
            .filter(|entry| entry.file_name().to_string_lossy().contains(".vega-tmp"))
            .collect();
        assert!(leftovers.is_empty());
        let _ = std::fs::remove_dir_all(&dir);
    }

    #[test]
    fn existing_config_aborts_on_invalid_utf8_instead_of_replacing() {
        let dir = temp_dir("utf8");
        let path = dir.join("RustDesk2.toml");
        std::fs::write(&path, [0xff, 0xfe, 0x00, 0x41]).unwrap();
        assert!(read_existing_config(&path).is_err());
        // 文件保持原样，没有被当成空文件覆盖。
        assert_eq!(std::fs::read(&path).unwrap(), vec![0xff, 0xfe, 0x00, 0x41]);
        let _ = std::fs::remove_dir_all(&dir);
    }

    #[test]
    fn file_merge_preserves_existing_keys_when_replacing() {
        let dir = temp_dir("merge");
        let path = dir.join("RustDesk2.toml");
        std::fs::write(
            &path,
            "[options]\nother = \"keep\"\npassword = \"not-managed\"\n",
        )
        .unwrap();
        let existing = read_existing_config(&path).unwrap();
        let key = "B".repeat(43) + "=";
        let merged =
            merge_server_config(&existing, "relay.example.com", "relay.example.com", &key).unwrap();
        write_atomic(&path, &merged).unwrap();
        let snapshot = read_server_config(&std::fs::read_to_string(&path).unwrap()).unwrap();
        assert_eq!(snapshot.server, "relay.example.com");
        assert_eq!(snapshot.key, key);
        let reparsed: toml::Table =
            toml::from_str(&std::fs::read_to_string(&path).unwrap()).unwrap();
        let options = reparsed.get("options").unwrap().as_table().unwrap();
        assert_eq!(options.get("other").unwrap().as_str().unwrap(), "keep");
        assert_eq!(
            options.get("password").unwrap().as_str().unwrap(),
            "not-managed"
        );
        let _ = std::fs::remove_dir_all(&dir);
    }
}
