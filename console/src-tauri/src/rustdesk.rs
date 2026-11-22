//! RustDesk 集成（M2b）。
//!
//! 约定（继承 T1/T2 安全约束）：
//! - 不读取、不保存、不通过命令行传递临时密码。密码只由 RustDesk 自己管理，
//!   控制台只负责打开 RustDesk 主窗口让用户自己看。
//! - 服务器公钥从不写日志；对外只暴露前 8 位指纹。
//! - 非 Windows 平台一律返回「未安装 RustDesk」，不 spawn 任何进程。
//! - 控制台对 RustDesk 网络配置是**只读**的：只读 `RustDesk2.toml` 并展示，
//!   修改一律引导到 RustDesk 自己的「设置 → 网络」，避免与运行中的 RustDesk /
//!   服务进程互相覆盖配置。

use serde::Serialize;
use std::fs::OpenOptions;
use std::io::{Read, Write};
use std::net::{Ipv4Addr, Ipv6Addr, SocketAddr, TcpStream, ToSocketAddrs};
use std::path::{Path, PathBuf};
use std::process::{Command, Stdio};
use std::sync::atomic::{AtomicBool, AtomicU64, Ordering};
use std::sync::mpsc;
use std::sync::Arc;
use std::time::{Duration, Instant};

use tauri::Manager;

const RUSTDESK_EXE: &str = "rustdesk.exe";
const NOT_INSTALLED: &str = "未安装 RustDesk";
const CONFIG_TIMEOUT: Duration = Duration::from_secs(5);
const TEST_TIMEOUT: Duration = Duration::from_secs(3);

/// 子进程输出上限：`--get-id` 只输出一行设备码，4 KB 足够，且不会因为
/// 子进程灌输出把控制台内存吃掉。
const MAX_CAPTURE_BYTES: u64 = 4 * 1024;

/// RustDesk 官方下载页（WinGet 的 `RustDesk.RustDesk` 已被移除）。
/// 硬编码在 Rust 侧：不接受任何前端传入的 URL。
const RUSTDESK_DOWNLOAD_URL: &str = "https://github.com/rustdesk/rustdesk/releases/latest";

/// 原子写临时文件序号，保证同名写入之间不会互相覆盖临时文件。
static TMP_SEQ: AtomicU64 = AtomicU64::new(0);
/// RustDesk 默认 ID/中继端口（hbbs 21116 / hbbr 21117）。
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

const PEER_ID_ERROR: &str =
    "设备码必须是 9-10 位数字，或 3-3-3 / 3-3-4 分组格式（如 123-456-789）";

/// IPC 入口：设备码只接受 9-10 位 ASCII 数字，或控制台自己展示的分组写法
/// （`123 456 789`、`123-456-789`、十位码的 3-3-4）。返回纯数字。
/// 整串必须完全匹配：分隔符要一致，落单的分组直接拒绝，绝不做「删掉多余
/// 字符」式清洗，否则粘错的码会被悄悄改成另一台设备。
pub fn parse_peer_id(raw: &str) -> Result<String, String> {
    let value = raw.trim();
    if value.is_empty() {
        return Err(PEER_ID_ERROR.into());
    }
    let digits = if value.chars().all(|c| c.is_ascii_digit()) {
        value.to_string()
    } else {
        let separator = value
            .chars()
            .find(|c| !c.is_ascii_digit())
            .filter(|c| *c == ' ' || *c == '-')
            .ok_or_else(|| PEER_ID_ERROR.to_string())?;
        if value
            .chars()
            .any(|c| !c.is_ascii_digit() && c != separator)
        {
            return Err(PEER_ID_ERROR.into());
        }
        let groups: Vec<&str> = value.split(separator).collect();
        if groups.len() != 3
            || groups[..2].iter().any(|group| group.len() != 3)
            || !matches!(groups[2].len(), 3 | 4)
            || groups
                .iter()
                .any(|group| !group.chars().all(|c| c.is_ascii_digit()))
        {
            return Err(PEER_ID_ERROR.into());
        }
        groups.concat()
    };
    if digits.len() == 9 || digits.len() == 10 {
        Ok(digits)
    } else {
        Err(PEER_ID_ERROR.into())
    }
}

/// 公钥指纹：先按 base64/32 字节校验，通过后只暴露前 8 位。
///
/// 格式无效时返回空串：调用方只能展示通用的「公钥格式无效」，
/// 不能把畸形值（哪怕只有几个字符）回显给前端。
pub fn key_fingerprint(key: &str) -> String {
    match validate_key(key) {
        Ok(valid) => valid.chars().take(8).collect(),
        Err(_) => String::new(),
    }
}

/// 公钥存在但格式无效：对外只给通用文案。
pub fn key_invalid(key: &str) -> bool {
    !key.is_empty() && validate_key(key).is_err()
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

/// 保存前归一化服务器地址：IPv6 一律写成 `[addr]:port`。
///
/// RustDesk 不认裸 IPv6 或省略端口的 IPv6，而 Vega 的 TCP 探测会自动补
/// 默认端口；不归一化就会出现「测试通、RustDesk 连不上」。IPv4 和域名
/// 保持原样（RustDesk 会自己补端口）。
///
/// 控制台现在是只读的，不再写 `RustDesk2.toml`；这个归一化只在单元测试
/// 里校验格式规则（保留是为了地址校验口径不丢）。
#[allow(dead_code)]
pub fn normalize_server_for_save(input: &str, default_port: u16) -> Result<String, String> {
    let value = validate_server(input)?;
    let (host, port) = split_host_port(&value)?;
    if host.parse::<Ipv6Addr>().is_ok() {
        let port = port.unwrap_or(default_port);
        return Ok(format!("[{}]:{}", host, port));
    }
    Ok(value)
}

/* ------------------------------------------------------------------ */
/* RustDesk2.toml 读取                                                  */
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

/// 解析 TOML 文本，只取 `[options]` 下的受管键；文件本身只读，不做任何回写。
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

/// 找 rustdesk.exe：只认 `Program Files` / `Program Files (x86)` 下
/// 受信任的安装路径（已知文件夹 + 规范化 + 根目录包含校验）。
///
/// 不做 PATH 搜索：PATH 由启动环境决定，任何被改写的目录都能塞进一个
/// `rustdesk.exe`（审计 P2）。返回的就是校验通过、可直接启动的路径。
pub fn locate_rustdesk() -> Option<PathBuf> {
    crate::winpaths::trusted_install_exe(&["RustDesk", RUSTDESK_EXE])
}

/// 运行命令并限时收集 stdout。
///
/// 输出直接落到本次调用独占的临时文件：没有读线程，也不存在「子进程已退出，
/// 但后代进程还占着管道把读取方挂住」的情况。只有一个总 deadline：轮询
/// `try_wait` 到点就 kill + wait，随后只从临时文件读回前 `MAX_CAPTURE_BYTES`。
/// stderr 丢到 null：控制台从不用它，也不把路径/用户名透给前端。
fn run_capture(exe: &Path, args: &[&str], timeout: Duration) -> Result<String, String> {
    let output_path = capture_temp_path();
    let stdout_file = OpenOptions::new()
        .write(true)
        .create_new(true)
        .open(&output_path)
        .map_err(|e| format!("创建临时输出文件失败：{e}"))?;

    let mut command = Command::new(exe);
    command
        .args(args)
        .stdin(Stdio::null())
        .stdout(Stdio::from(stdout_file))
        .stderr(Stdio::null());
    #[cfg(windows)]
    {
        use std::os::windows::process::CommandExt;
        // 隐藏控制台窗口：--get-id 与 tasklist 都不该闪黑框。
        command.creation_flags(CREATE_NO_WINDOW);
    }

    let mut child = match command.spawn() {
        Ok(child) => child,
        Err(e) => {
            let _ = std::fs::remove_file(&output_path);
            return Err(format!("启动 {} 失败：{e}", exe.display()));
        }
    };

    let deadline = Instant::now() + timeout;
    let status = loop {
        match child.try_wait() {
            Ok(Some(status)) => break status,
            Ok(None) => {
                if Instant::now() >= deadline {
                    let _ = child.kill();
                    let _ = child.wait();
                    let _ = std::fs::remove_file(&output_path);
                    return Err(timeout_error(timeout));
                }
                std::thread::sleep(Duration::from_millis(20));
            }
            Err(_) => {
                let _ = child.kill();
                let _ = child.wait();
                let _ = std::fs::remove_file(&output_path);
                return Err("等待命令结束失败".to_string());
            }
        }
    };

    let captured = read_bounded(&output_path, MAX_CAPTURE_BYTES);
    let _ = std::fs::remove_file(&output_path);
    let captured = captured?;
    if status.success() {
        Ok(String::from_utf8_lossy(&captured).to_string())
    } else {
        Err(format!("命令退出码 {:?}", status.code()))
    }
}

fn timeout_error(timeout: Duration) -> String {
    format!("命令超时（{} 秒）", timeout.as_secs())
}

/// 本次调用的临时输出文件：进程号 + 单调序号，同名互不覆盖。
fn capture_temp_path() -> PathBuf {
    let seq = TMP_SEQ.fetch_add(1, Ordering::Relaxed);
    std::env::temp_dir().join(format!(
        "vega-capture-{}-{seq}.out",
        std::process::id()
    ))
}

/// 只读前 `limit` 字节，避免异常输出把内存吃满。
fn read_bounded(path: &Path, limit: u64) -> Result<Vec<u8>, String> {
    let file = std::fs::File::open(path).map_err(|e| format!("读取命令输出失败：{e}"))?;
    let mut buffer = Vec::new();
    file.take(limit)
        .read_to_end(&mut buffer)
        .map_err(|e| format!("读取命令输出失败：{e}"))?;
    Ok(buffer)
}

/// 以无窗口方式启动进程（RustDesk / Moonlight 会自绘窗口，不需要控制台）。
pub(crate) fn spawn_detached(exe: &Path, args: &[&str]) -> Result<(), String> {
    let mut command = Command::new(exe);
    command
        .args(args)
        .stdin(Stdio::null())
        .stdout(Stdio::null())
        .stderr(Stdio::null());
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

pub(crate) fn recent_path(app: &tauri::AppHandle) -> Result<PathBuf, String> {
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

/// 原子写：同目录临时文件 + rename。临时文件用 `create_new` 独占创建，
/// 文件名带进程号与序号，两个 Vega 实例不会互相踩到对方的临时文件。
pub(crate) fn write_atomic(path: &Path, contents: &str) -> Result<(), String> {
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

/// 默认浏览器/资源管理器入口：`explorer.exe` 由已知文件夹解析，
/// 不使用 `%SystemRoot%` 环境变量，也不接受 `C:\Windows` 兜底拼接。
pub(crate) fn explorer_exe() -> Option<PathBuf> {
    crate::winpaths::explorer_exe()
}

#[cfg(windows)]
fn rustdesk_process_running() -> bool {
    let Some(tasklist) = crate::winpaths::system32_exe("tasklist.exe") else {
        return false;
    };
    match run_capture(
        &tasklist,
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
    // 与串流页共用 SCM 查询：只有 ERROR_SERVICE_DOES_NOT_EXIST 返回空串
    // （未安装），查询失败返回 QUERY_FAILED，不能混为「未安装」（审计 r5 P3）。
    crate::scm::service_state_code("RustDesk")
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
    /// 公钥存在但格式无效时是通用文案，空串表示没有这个问题。
    pub key_error: String,
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
    pub(crate) fn ok(message: impl Into<String>) -> Self {
        Self {
            ok: true,
            message: message.into(),
        }
    }
    pub(crate) fn err(message: impl Into<String>) -> Self {
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
            key_error: String::new(),
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
            key_error: String::new(),
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
                key_error: String::new(),
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
                key_error: String::new(),
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
            // 畸形公钥只给通用文案，不回显任何字符（审计 P3）。
            let key_error = if key_invalid(&snapshot.key) {
                "公钥格式无效".to_string()
            } else {
                String::new()
            };
            ServerConfigView {
                server: snapshot.server,
                relay: snapshot.relay,
                key_fingerprint,
                key_present,
                key_error,
                path: display,
                error: String::new(),
            }
        }
        Err(error) => ServerConfigView {
            server: String::new(),
            relay: String::new(),
            key_fingerprint: String::new(),
            key_present: false,
            key_error: String::new(),
            path: display,
            error,
        },
    }
}

/// 安装包随包的默认中继（`resources/vega-defaults.json`）内容。
/// 只读展示：设置页用它和 RustDesk 实际配置比对，不提供任何写入能力。
#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
pub struct RelayDefaultsView {
    pub id_server: String,
    pub relay_server: String,
    pub key_present: bool,
    /// 公钥摘要（前 8 位）。设置页用它和 RustDesk 实际配置比对，不回显完整公钥。
    pub key_fingerprint: String,
    pub path: String,
    pub error: String,
}

/// 从 vega-defaults.json 文本里取展示字段。格式不对只返回错误文案，不 panic。
/// 返回 (idServer, relayServer, key)；公钥摘要由调用方计算，避免把原文带进视图。
pub fn parse_relay_defaults(text: &str) -> Result<(String, String, String), String> {
    let data: serde_json::Value =
        serde_json::from_str(text).map_err(|e| format!("默认配置不是合法 JSON：{e}"))?;
    let rustdesk = data
        .get("rustdesk")
        .ok_or_else(|| "默认配置缺少 rustdesk 段".to_string())?;
    let id_server = rustdesk
        .get("idServer")
        .and_then(|v| v.as_str())
        .map(str::trim)
        .filter(|v| !v.is_empty())
        .ok_or_else(|| "默认配置缺少 rustdesk.idServer".to_string())?
        .to_string();
    let relay_server = rustdesk
        .get("relayServer")
        .and_then(|v| v.as_str())
        .map(str::trim)
        .filter(|v| !v.is_empty())
        .ok_or_else(|| "默认配置缺少 rustdesk.relayServer".to_string())?
        .to_string();
    let key = rustdesk
        .get("key")
        .and_then(|v| v.as_str())
        .map(str::trim)
        .unwrap_or_default()
        .to_string();
    Ok((id_server, relay_server, key))
}

fn relay_defaults_path(app: &tauri::AppHandle) -> Option<PathBuf> {
    // 安装包内：<安装目录>\resources\vega-defaults.json。
    // 开发/测试环境（tauri dev）资源未必复制到 resource_dir，回落到源码目录。
    if let Ok(dir) = app.path().resource_dir() {
        // tauri.conf.json 把资源显式映射到 resources\ 下，与 NSIS 钩子用的是同一路径。
        let candidate = dir.join("resources").join("vega-defaults.json");
        if candidate.is_file() {
            return Some(candidate);
        }
        // 兼容早期安装包：当时资源被放在安装目录根下。
        let legacy = dir.join("vega-defaults.json");
        if legacy.is_file() {
            return Some(legacy);
        }
    }
    let dev = PathBuf::from(env!("CARGO_MANIFEST_DIR"))
        .join("resources")
        .join("vega-defaults.json");
    if dev.is_file() {
        return Some(dev);
    }
    None
}

#[tauri::command]
pub fn get_relay_defaults(app: tauri::AppHandle) -> RelayDefaultsView {
    let Some(path) = relay_defaults_path(&app) else {
        return RelayDefaultsView {
            id_server: String::new(),
            relay_server: String::new(),
            key_present: false,
            key_fingerprint: String::new(),
            path: String::new(),
            error: "找不到随包的 vega-defaults.json".into(),
        };
    };
    let display = path.display().to_string();
    let text = match std::fs::read_to_string(&path) {
        Ok(text) => text,
        Err(e) => {
            return RelayDefaultsView {
                id_server: String::new(),
                relay_server: String::new(),
                key_present: false,
                key_fingerprint: String::new(),
                path: display,
                error: format!("读取默认配置失败：{e}"),
            };
        }
    };
    match parse_relay_defaults(&text) {
        Ok((id_server, relay_server, key)) => RelayDefaultsView {
            id_server,
            relay_server,
            key_present: !key.is_empty(),
            key_fingerprint: key_fingerprint(&key),
            path: display,
            error: String::new(),
        },
        Err(error) => RelayDefaultsView {
            id_server: String::new(),
            relay_server: String::new(),
            key_present: false,
            key_fingerprint: String::new(),
            path: display,
            error,
        },
    }
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

/// 「打开 RustDesk 官方下载页」：URL 硬编码在 Rust 侧，前端不能传地址。
/// 用 `explorer.exe <url>` 交给系统默认浏览器，不引入 Shell 插件权限。
#[tauri::command]
pub fn open_rustdesk_download_page() -> OpResult {
    if !cfg!(windows) {
        return OpResult::err("只有 Windows 控制台能打开下载页");
    }
    let Some(explorer) = explorer_exe() else {
        return OpResult::err("找不到系统资源管理器，无法打开下载页");
    };
    match spawn_detached(&explorer, &[RUSTDESK_DOWNLOAD_URL]) {
        Ok(()) => OpResult::ok("已在默认浏览器中打开 RustDesk 官方下载页，请手动安装"),
        Err(e) => OpResult::err(format!("打开浏览器失败：{e}")),
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

/// 解析前的统一门槛：调用方的原始 deadline 已到，或收到取消标志。
///
/// 这里不重建 deadline：预算只由调用方算一次，之后一路传绝对时间点。
fn lookup_stopped(deadline: Instant, cancel: Option<&AtomicBool>) -> bool {
    cancel.is_some_and(|flag| flag.load(Ordering::Acquire)) || Instant::now() >= deadline
}

/// DNS 解析放在独立线程里，用 channel 等到调用方给的原始 deadline：
/// `to_socket_addrs` 本身没有超时参数，直接调用可能把命令拖住很久。
///
/// 三层保护：
/// 1. 启动线程前先查 deadline 和取消标志；已过期/已取消就直接返回超时，
///    不再为一次注定被丢弃的解析创建线程。
/// 2. 线程被调度起来后再查一次 —— 它可能在调用方的检查之后才被调度，
///    此时预算已经用光/已被取消，直接不解析、不回包。
/// 3. 解析返回时再查一次，迟到结果丢弃；等待时长在真正 `recv_timeout`
///    之前现算，用 spawn 前捕获的旧快照会多等。
fn resolve_with_timeout(
    host: &str,
    port: u16,
    deadline: Instant,
    cancel: Option<Arc<AtomicBool>>,
) -> Result<Vec<SocketAddr>, String> {
    let timeout_message = format!("解析 {host}:{port} 超时");
    if lookup_stopped(deadline, cancel.as_deref()) {
        return Err(timeout_message);
    }
    let (tx, rx) = mpsc::channel();
    let lookup_host = host.to_string();
    let thread_deadline = deadline;
    let thread_cancel = cancel.clone();
    std::thread::spawn(move || {
        // 线程内部第一件事：线程可能在调用方的检查之后才被调度。
        if lookup_stopped(thread_deadline, thread_cancel.as_deref()) {
            return;
        }
        let result = (lookup_host.as_str(), port)
            .to_socket_addrs()
            .map(|iter| iter.collect::<Vec<_>>())
            .map_err(|e| e.to_string());
        // 解析结果迟到（已过期/已取消）：丢弃，不回包。
        if lookup_stopped(thread_deadline, thread_cancel.as_deref()) {
            return;
        }
        let _ = tx.send(result);
    });
    // 剩余等待在真正 recv 前现算，不用 spawn 之前捕获的时长。
    let remaining = deadline.saturating_duration_since(Instant::now());
    if remaining.is_zero() {
        return Err(timeout_message);
    }
    match rx.recv_timeout(remaining) {
        Ok(Ok(addrs)) => Ok(addrs),
        Ok(Err(e)) => Err(format!("解析 {host}:{port} 失败：{e}")),
        Err(_) => Err(timeout_message),
    }
}

/// 纯阻塞探测：解析和所有连接尝试共用调用方传入的同一个绝对 deadline，
/// 不会每换一个地址就重新计时；`cancel` 置位后不再发起新的解析。
/// 命令层用 `spawn_blocking` 把它挪出 UI 线程。
pub(crate) fn probe_server_with_timeout(
    server: &str,
    deadline: Instant,
    cancel: Option<Arc<AtomicBool>>,
) -> TestResult {
    let started = Instant::now();
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
    let cancel_flag = cancel.as_deref();
    let addrs = match resolve_with_timeout(&host, port, deadline, cancel.clone()) {
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
        if lookup_stopped(deadline, cancel_flag) {
            last_error = "总超时已用完".to_string();
            break;
        }
        let remaining = deadline.saturating_duration_since(Instant::now());
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
        message: format!("TCP 连接失败（总超时已用完）：{last_error}"),
        latency_ms: started.elapsed().as_millis() as u64,
    }
}

fn probe_server(server: &str) -> TestResult {
    probe_server_with_timeout(server, Instant::now() + TEST_TIMEOUT, None)
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

/// 剪贴板写入的通用失败文案：不把 Win32 错误码或系统状态透给前端。
const CLIPBOARD_ERROR: &str = "写剪贴板失败，请重试";

/// Win32 剪贴板写入（`CF_UNICODETEXT`），必须传主窗口 HWND。
///
/// HWND 用 `isize` 传：Tauri 的 `window.hwnd()` 返回的 `HWND` 字段类型随
/// `windows` crate 版本变（`*mut c_void` / `isize` 都出现过），转成整数再传
/// 可以避免跟着上游版本改签名。
///
/// 不经过 PowerShell：那会走 PATH 解析、需要拼接命令行，还会把设备码放进
/// 子进程参数（审计 P2）。这里直接调用 user32/kernel32。
#[cfg(windows)]
fn set_clipboard_text(hwnd: isize, text: &str) -> Result<(), String> {
    use std::ffi::c_void;

    const CF_UNICODETEXT: u32 = 13;
    const GMEM_MOVEABLE: u32 = 0x0002;
    type Bool = i32;
    type Handle = *mut c_void;

    #[link(name = "user32")]
    extern "system" {
        fn OpenClipboard(hwnd: Handle) -> Bool;
        fn EmptyClipboard() -> Bool;
        fn SetClipboardData(format: u32, mem: Handle) -> Handle;
        fn CloseClipboard() -> Bool;
    }
    #[link(name = "kernel32")]
    extern "system" {
        fn GlobalAlloc(flags: u32, bytes: usize) -> Handle;
        fn GlobalLock(mem: Handle) -> *mut c_void;
        fn GlobalUnlock(mem: Handle) -> Bool;
        fn GlobalFree(mem: Handle) -> Handle;
    }

    // 剪贴板文本是 NUL 结尾的 UTF-16。
    let wide: Vec<u16> = text.encode_utf16().chain(std::iter::once(0)).collect();
    let bytes = wide.len() * std::mem::size_of::<u16>();
    // SAFETY: 每个分配都有对应释放；SetClipboardData 成功后所有权归系统，
    // 因此只有失败分支才 GlobalFree。OpenClipboard 成功后必定 CloseClipboard。
    unsafe {
        // 不能用 OpenClipboard(NULL)：NULL 关联的是调用线程的隐藏窗口，
        // 而剪贴板归主线程（Tauri 事件循环）上的主窗口所有。这里显式传
        // 主窗口 HWND，并保证调用发生在主线程。
        if OpenClipboard(hwnd as Handle) == 0 {
            return Err(CLIPBOARD_ERROR.to_string());
        }
        let result: Result<(), String> = (|| {
            if EmptyClipboard() == 0 {
                return Err(CLIPBOARD_ERROR.to_string());
            }
            let mem = GlobalAlloc(GMEM_MOVEABLE, bytes);
            if mem.is_null() {
                return Err(CLIPBOARD_ERROR.to_string());
            }
            let target = GlobalLock(mem);
            if target.is_null() {
                GlobalFree(mem);
                return Err(CLIPBOARD_ERROR.to_string());
            }
            std::ptr::copy_nonoverlapping(wide.as_ptr() as *const c_void, target, bytes);
            GlobalUnlock(mem);
            if SetClipboardData(CF_UNICODETEXT, mem).is_null() {
                GlobalFree(mem);
                // 失败时唯一的副作用是上面已经清空的剪贴板：不再写别的数据，
                // 也不再重试，只回通用错误。
                return Err(CLIPBOARD_ERROR.to_string());
            }
            Ok(())
        })();
        CloseClipboard();
        result
    }
}

/// 托盘「复制设备码」用：拿设备码写到剪贴板，不经过前端。
///
/// 两段式：`--get-id` 是子进程等待，留在调用方给的工作线程；剪贴板写入
/// 必须回主线程，用主窗口 HWND 打开剪贴板（审计 P2）。
#[cfg(windows)]
pub fn copy_device_id_to_clipboard(app: &tauri::AppHandle) -> Result<String, String> {
    let info = get_device_id_blocking();
    if info.formatted_id.is_empty() {
        return Err(if info.error.is_empty() {
            NOT_INSTALLED.to_string()
        } else {
            info.error
        });
    }
    let text = info.formatted_id.clone();
    // 两个克隆：`run_on_main_thread` 只需借用 `handle`，闭包 move 的是
    // `main_handle`。同一个变量既被借用又被移进闭包会触发 E0505。
    let handle = app.clone();
    let main_handle = handle.clone();
    let (sender, receiver) = mpsc::channel();
    handle
        .run_on_main_thread(move || {
            let result = match main_handle.get_webview_window("main") {
                Some(window) => window
                    .hwnd()
                    .map_err(|_| CLIPBOARD_ERROR.to_string())
                    .and_then(|hwnd| set_clipboard_text(hwnd.0 as isize, &text)),
                None => Err(CLIPBOARD_ERROR.to_string()),
            };
            // 主线程只回传结果，不阻塞在 worker 的等待上。
            let _ = sender.send(result);
        })
        .map_err(|_| CLIPBOARD_ERROR.to_string())?;
    match receiver.recv_timeout(Duration::from_secs(5)) {
        Ok(result) => result.map(|()| info.formatted_id),
        // 主线程 5 秒内没回：事件循环卡住或窗口已销毁，按通用失败处理。
        Err(_) => Err(CLIPBOARD_ERROR.to_string()),
    }
}

#[cfg(not(windows))]
pub fn copy_device_id_to_clipboard(_app: &tauri::AppHandle) -> Result<String, String> {
    Err(NOT_INSTALLED.to_string())
}

/* ------------------------------------------------------------------ */
/* 单元测试                                                            */
/* ------------------------------------------------------------------ */

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn resolve_returns_timeout_before_spawning_when_deadline_passed() {
        // 已过期的 deadline 不能再创建解析线程：直接返回超时。
        let past = Instant::now() - Duration::from_secs(1);
        let started = Instant::now();
        let result = resolve_with_timeout("host.invalid", 21116, past, None);
        assert!(result.is_err());
        assert!(started.elapsed() < Duration::from_secs(1));
    }

    #[test]
    fn resolve_returns_timeout_before_spawning_when_cancelled() {
        // 取消标志优先于还很远的 deadline：同样不能启动解析线程。
        let cancel = Arc::new(AtomicBool::new(true));
        let future = Instant::now() + Duration::from_secs(60);
        let started = Instant::now();
        let result = resolve_with_timeout("host.invalid", 21116, future, Some(cancel));
        assert!(result.is_err());
        assert!(started.elapsed() < Duration::from_secs(1));
    }

    #[test]
    fn probe_with_expired_deadline_reports_failure_without_resolving() {
        let past = Instant::now() - Duration::from_secs(1);
        let result = probe_server_with_timeout("host.invalid", past, None);
        assert!(!result.ok);
        assert!(result.message.contains("超时"), "{}", result.message);
    }

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
    fn device_id_format_is_three_three_three_or_three_three_four() {
        assert_eq!(format_device_id("123456789"), "123-456-789");
        assert_eq!(format_device_id("1234567890"), "123-456-7890");
        assert_eq!(format_device_id("short"), "short");
    }

    #[test]
    fn device_id_format_round_trips_through_parser() {
        // 最近设备码列表用 format_device_id 展示，粘回输入框由 parse_peer_id
        // 解析：3-3-3 与 3-3-4 都必须原样回到同一串数字。
        for id in ["123456789", "1234567890"] {
            let formatted = format_device_id(id);
            assert_eq!(parse_peer_id(&formatted).unwrap(), id, "连字符分组");
            let spaced = formatted.replace('-', " ");
            assert_eq!(parse_peer_id(&spaced).unwrap(), id, "空格分组");
        }
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
    fn ipv6_is_normalized_with_brackets_and_default_ports() {
        // ID 服务器：无括号 / 有括号缺端口都补 21116。
        assert_eq!(
            normalize_server_for_save("[::1]", RUSTDESK_DEFAULT_PORT).unwrap(),
            "[::1]:21116"
        );
        assert_eq!(
            normalize_server_for_save("2001:db8::1", RUSTDESK_DEFAULT_PORT).unwrap(),
            "[2001:db8::1]:21116"
        );
        // 已带端口时保持原端口，只统一成 [addr]:port。
        assert_eq!(
            normalize_server_for_save("[2001:db8::1]:21116", RUSTDESK_DEFAULT_PORT).unwrap(),
            "[2001:db8::1]:21116"
        );
        // IPv4 / 域名不加端口，交给 RustDesk 自己补。
        assert_eq!(
            normalize_server_for_save("relay.example.com", RUSTDESK_DEFAULT_PORT).unwrap(),
            "relay.example.com"
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
    fn malformed_key_yields_generic_status_without_echoing_value() {
        // 短到能整个塞进「前 8 位」的畸形值也不能被回显（审计 P3）。
        let snapshot = ServerSnapshot {
            server: "relay.example.com".into(),
            relay: String::new(),
            key: "SHORT".into(),
        };
        assert!(snapshot.key_present());
        assert!(key_invalid(&snapshot.key));
        assert_eq!(snapshot.key_fingerprint(), "");
        assert!(!snapshot.key_fingerprint().contains("SHORT"));
        // 非 base64 的 44 字符值同样只得到空指纹。
        let non_base64 = format!("{}!", "A".repeat(43));
        assert!(key_invalid(&non_base64));
        assert_eq!(key_fingerprint(&non_base64), "");
        // 合法公钥仍然给前 8 位。
        assert!(!key_invalid(&format!("{}=", "A".repeat(43))));
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
    fn peer_id_accepts_plain_and_grouped_forms() {
        assert_eq!(parse_peer_id("123456789").unwrap(), "123456789");
        assert_eq!(parse_peer_id("1234567890").unwrap(), "1234567890");
        // 控制台自己展示的两组分隔写法都要能原样粘回来，返回纯数字。
        assert_eq!(parse_peer_id("123 456 789").unwrap(), "123456789");
        assert_eq!(parse_peer_id("123-456-789").unwrap(), "123456789");
        assert_eq!(parse_peer_id("123 456 7890").unwrap(), "1234567890");
        assert_eq!(parse_peer_id("123-456-7890").unwrap(), "1234567890");
        // 只去掉外层空白，不做别的清洗。
        assert_eq!(parse_peer_id(" 123456789 ").unwrap(), "123456789");
    }

    #[test]
    fn peer_id_rejects_mixed_or_malformed_grouping() {
        for bad in [
            "123-456 789",   // 混用分隔符
            "123_456_789",   // 不支持的分隔符
            "12 456 789",    // 首组不足三位
            "123 45 789",    // 中组不足三位
            "123 456 78",    // 末组不足三位
            "123 456 78901", // 末组超过四位
            "123 456",       // 只有两组
            "123--456-789",  // 空分组
            "12345678",      // 8 位
            "12345678901",   // 11 位
            "12345678a",
            "",
            "   ",
        ] {
            assert!(parse_peer_id(bad).is_err(), "应当拒绝 {bad:?}");
        }
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
        // 哨兵放在真正解析失败的那一行：解析器若回显源码片段，这个测试才会失败。
        let text = format!("[options]\nkey = \"ok\"\nbroken = {secret}\n");
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
    fn read_bounded_stops_at_limit_and_fails_on_missing_file() {
        // --get-id 的输出走临时文件：只读回前 N 字节，异常输出不会撑爆内存。
        let dir = temp_dir("bounded");
        let path = dir.join("capture.out");
        std::fs::write(&path, "abcdefghij").unwrap();
        assert_eq!(read_bounded(&path, 4).unwrap(), b"abcd".to_vec());
        assert_eq!(read_bounded(&path, 100).unwrap(), b"abcdefghij".to_vec());
        assert!(read_bounded(&dir.join("missing.out"), 4).is_err());
        let _ = std::fs::remove_dir_all(&dir);
    }

    #[test]
    fn capture_temp_path_is_unique_per_call() {
        let first = capture_temp_path();
        let second = capture_temp_path();
        assert_ne!(first, second);
        // 落在系统临时目录里，名字带进程号，不会和其它实例互相覆盖。
        assert!(first.starts_with(std::env::temp_dir()));
    }

}
