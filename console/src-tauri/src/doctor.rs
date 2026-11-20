//! 设置 → 诊断（M2c）：有界 doctor + 脱敏日志导出。
//!
//! doctor 只做本地检查：服务状态、文件是否存在、本机 TCP 连接、UDP 路由选择。
//! 所有网络探测共用 8 秒总预算；结果里不放地址、主机名、用户名或用户目录路径。
//! 导出日志再统一做一次脱敏，然后交给资源管理器打开目录。

use std::io::Write;
use std::net::{Ipv6Addr, SocketAddr, TcpStream, UdpSocket};
use std::path::{Path, PathBuf};
use std::time::{Duration, Instant, SystemTime, UNIX_EPOCH};

use serde::Serialize;

use crate::rustdesk::{get_server_config, locate_rustdesk, probe_server_with_timeout, spawn_detached};
use crate::scm::{query_service_state, ServiceState};
use crate::streaming::{moonlight_exe, tailscale_installed};

const DOCTOR_BUDGET: Duration = Duration::from_secs(8);
const SUNSHINE_SERVICE: &str = "SunshineService";
const SUNSHINE_PORT: u16 = 47990;
const TCP_PROBE_TIMEOUT: Duration = Duration::from_secs(1);

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
enum DoctorStatus {
    Pass,
    Warn,
    Fail,
}

impl DoctorStatus {
    fn label(self) -> &'static str {
        match self {
            DoctorStatus::Pass => "通过",
            DoctorStatus::Warn => "警告",
            DoctorStatus::Fail => "失败",
        }
    }
}

#[derive(Clone, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct DoctorItem {
    pub item: String,
    pub status: String,
    pub advice: String,
}

fn item(name: &str, status: DoctorStatus, advice: &str) -> DoctorItem {
    DoctorItem {
        item: name.to_string(),
        status: status.label().to_string(),
        advice: advice.to_string(),
    }
}

fn remaining(deadline: Instant) -> Duration {
    deadline.saturating_duration_since(Instant::now())
}

/* ------------------------------------------------------------------ */
/* 单项检查（纯函数带单测）                                              */
/* ------------------------------------------------------------------ */

/// 47990 可达性与 Sunshine 服务状态的关系：只有可达才算通过；
/// Sunshine 正在运行却连不上就是失败，其余情况给警告而不是失败。
fn port_47990_status(reachable: bool, sunshine: ServiceState) -> (DoctorStatus, &'static str) {
    if reachable {
        return (DoctorStatus::Pass, "本机管理页可访问");
    }
    match sunshine {
        ServiceState::Running => (
            DoctorStatus::Fail,
            "Sunshine 正在运行但 47990 不可访问，检查防火墙或重启 Sunshine",
        ),
        ServiceState::Stopped => (
            DoctorStatus::Warn,
            "Sunshine 未运行，启动后再检查 47990",
        ),
        ServiceState::NotInstalled => (
            DoctorStatus::Warn,
            "未安装 Sunshine，串流前先安装/修复",
        ),
        ServiceState::Unknown => (
            DoctorStatus::Warn,
            "无法确认 Sunshine 服务状态，请以管理员身份检查服务",
        ),
    }
}

fn is_global_unicast(ip: &Ipv6Addr) -> bool {
    // 2000::/3：前三位是 001。
    (ip.segments()[0] & 0xE000) == 0x2000
}

/// 绑定 [::]:0 并 connect 一个全球单播地址，只看本地选中的源地址；
/// UDP connect 不发包。
fn has_global_ipv6() -> bool {
    let Ok(socket) = UdpSocket::bind("[::]:0") else {
        return false;
    };
    if socket.connect("2001:4860:4860::8888:53").is_err() {
        return false;
    }
    match socket.local_addr() {
        Ok(SocketAddr::V6(addr)) => is_global_unicast(addr.ip()),
        _ => false,
    }
}

fn probe_local_port(port: u16, timeout: Duration) -> bool {
    if timeout.is_zero() {
        return false;
    }
    let addr = SocketAddr::from(([127, 0, 0, 1], port));
    TcpStream::connect_timeout(&addr, timeout).is_ok()
}

/* ------------------------------------------------------------------ */
/* doctor 主流程                                                        */
/* ------------------------------------------------------------------ */

fn doctor_items() -> Vec<DoctorItem> {
    let deadline = Instant::now() + DOCTOR_BUDGET;
    let mut items = Vec::new();

    let rustdesk_installed = locate_rustdesk().is_some();
    items.push(if rustdesk_installed {
        item("RustDesk", DoctorStatus::Pass, "")
    } else {
        item(
            "RustDesk",
            DoctorStatus::Fail,
            "从 RustDesk 官方发行页手动安装后重新运行 doctor",
        )
    });

    // RustDesk ID 服务器：复用现有 TCP 探测，最多 3 秒，并受总预算约束。
    if !rustdesk_installed {
        items.push(item(
            "RustDesk ID 服务器",
            DoctorStatus::Warn,
            "未安装 RustDesk，跳过服务器连通性检查",
        ));
    } else {
        let config = get_server_config();
        if config.server.trim().is_empty() {
            items.push(item(
                "RustDesk ID 服务器",
                DoctorStatus::Warn,
                "在 RustDesk 的 设置 → 网络 中填写 ID 服务器",
            ));
        } else {
            let budget = remaining(deadline).min(Duration::from_secs(3));
            let result = probe_server_with_timeout(&config.server, budget);
            items.push(if result.ok {
                item("RustDesk ID 服务器", DoctorStatus::Pass, "")
            } else {
                item(
                    "RustDesk ID 服务器",
                    DoctorStatus::Fail,
                    "检查 RustDesk 设置 → 网络 中的服务器地址与本机网络",
                )
            });
        }
    }

    let sunshine = query_service_state(SUNSHINE_SERVICE);
    items.push(match sunshine {
        ServiceState::Running => item("Sunshine 服务", DoctorStatus::Pass, ""),
        ServiceState::Stopped => item(
            "Sunshine 服务",
            DoctorStatus::Warn,
            "Sunshine 已停止，启动服务或打开 Sunshine 设置",
        ),
        ServiceState::NotInstalled => item(
            "Sunshine 服务",
            DoctorStatus::Fail,
            "未安装 Sunshine，使用串流页的「安装/修复 Sunshine」",
        ),
        ServiceState::Unknown => item(
            "Sunshine 服务",
            DoctorStatus::Fail,
            "无法查询 Sunshine 服务，请以管理员身份检查服务状态",
        ),
    });

    let port_reachable = probe_local_port(SUNSHINE_PORT, remaining(deadline).min(TCP_PROBE_TIMEOUT));
    let (port_status, port_advice) = port_47990_status(port_reachable, sunshine);
    items.push(item("Sunshine 管理页 47990", port_status, port_advice));

    items.push(if has_global_ipv6() {
        item("公网 IPv6", DoctorStatus::Pass, "")
    } else {
        item(
            "公网 IPv6",
            DoctorStatus::Warn,
            "未检测到公网 IPv6，可改用 Tailscale 组网",
        )
    });

    items.push(if tailscale_installed() {
        item("Tailscale", DoctorStatus::Pass, "")
    } else {
        item(
            "Tailscale",
            DoctorStatus::Warn,
            "未安装 Tailscale；没有 IPv6 直连时建议安装",
        )
    });

    items.push(match moonlight_exe() {
        Ok(Some(_)) => item("Moonlight", DoctorStatus::Pass, ""),
        Ok(None) => item(
            "Moonlight",
            DoctorStatus::Warn,
            "未安装 Moonlight，使用串流页的「安装 Moonlight」",
        ),
        Err(error) => item("Moonlight", DoctorStatus::Warn, &error),
    });

    items
}

#[tauri::command]
pub async fn run_doctor() -> Vec<DoctorItem> {
    tauri::async_runtime::spawn_blocking(doctor_items)
        .await
        .unwrap_or_else(|_| {
            vec![item(
                "诊断",
                DoctorStatus::Fail,
                "诊断线程失败，请重试",
            )]
        })
}

/* ------------------------------------------------------------------ */
/* 脱敏 + 导出                                                          */
/* ------------------------------------------------------------------ */

fn replace_case_insensitive(text: &str, needle: &str, replacement: &str) -> String {
    if needle.len() < 2 {
        return text.to_string();
    }
    let lower_text = text.to_lowercase();
    let lower_needle = needle.to_lowercase();
    let mut result = String::with_capacity(text.len());
    let mut cursor = 0usize;
    while let Some(offset) = lower_text[cursor..].find(&lower_needle) {
        let start = cursor + offset;
        result.push_str(&text[cursor..start]);
        result.push_str(replacement);
        cursor = start + needle.len();
    }
    result.push_str(&text[cursor..]);
    result
}

fn looks_like_hostname(core: &str) -> bool {
    if !core.contains('.') || core.starts_with('.') || core.ends_with('.') {
        return false;
    }
    if core.chars().all(|c| c.is_ascii_digit() || c == '.') {
        return false;
    }
    let labels: Vec<&str> = core.split('.').collect();
    if labels.len() < 2 {
        return false;
    }
    labels.iter().all(|label| {
        !label.is_empty()
            && label
                .chars()
                .all(|c| c.is_ascii_alphanumeric() || c == '-' || c == '_')
    }) && labels
        .last()
        .map(|label| {
            label.len() >= 2 && label.chars().all(|c| c.is_ascii_alphabetic())
        })
        .unwrap_or(false)
}

fn split_edge_punctuation(token: &str) -> (&str, &str, &str) {
    let leading = token
        .char_indices()
        .find(|&(_, c)| {
            !c.is_ascii_punctuation()
                || matches!(c, '[' | '(' | '{' | '"' | '\'')
        })
        .map(|(index, _)| index)
        .unwrap_or(token.len());
    let rest = &token[leading..];
    let trailing = rest
        .char_indices()
        .rev()
        .find(|&(_, c)| {
            !c.is_ascii_punctuation()
                || matches!(c, ']' | ')' | '}' | '"' | '\'')
        })
        .map(|(index, c)| index + c.len_utf8())
        .unwrap_or(rest.len());
    (&token[..leading], &rest[..trailing], &rest[trailing..])
}

fn mask_core(core: &str) -> String {
    if core.is_empty() {
        return String::new();
    }
    if core.contains('@') {
        return "<email>".to_string();
    }
    // [IPv6]:port 这种带端口的写法先拆括号，再按地址解析。
    if let Some(end) = core.find("]:") {
        if core[..end].parse::<Ipv6Addr>().is_ok() {
            return "<ip>".to_string();
        }
    }
    let bracketed = core.trim_start_matches('[').trim_end_matches(']');
    if bracketed.parse::<std::net::Ipv4Addr>().is_ok()
        || bracketed.parse::<Ipv6Addr>().is_ok()
    {
        return "<ip>".to_string();
    }
    // host:port（IPv4 / 主机名）
    if let Some((host, port)) = core.rsplit_once(':') {
        if port.chars().all(|c| c.is_ascii_digit()) && !host.is_empty() {
            if host.parse::<std::net::Ipv4Addr>().is_ok() {
                return "<ip>".to_string();
            }
            if looks_like_hostname(host) {
                return "<host>".to_string();
            }
        }
    }
    if core.contains('\\') || core.contains('/') {
        return "<path>".to_string();
    }
    if looks_like_hostname(core) {
        return "<host>".to_string();
    }
    core.to_string()
}

fn redact_token(token: &str) -> String {
    let (leading, core, trailing) = split_edge_punctuation(token);
    format!("{leading}{}{trailing}", mask_core(core))
}

fn redact_with(input: &str, profile: Option<&str>) -> String {
    let mut text = input.to_string();
    if let Some(profile) = profile {
        if profile.len() >= 3 {
            text = replace_case_insensitive(&text, profile, "<profile>");
        }
    }
    for key in ["USERNAME", "COMPUTERNAME", "USERDOMAIN"] {
        if let Ok(value) = std::env::var(key) {
            if value.len() >= 2 {
                text = replace_case_insensitive(&text, &value, "<已隐藏>");
            }
        }
    }
    text.split_whitespace()
        .map(redact_token)
        .collect::<Vec<_>>()
        .join(" ")
}

fn redact_text(input: &str) -> String {
    let profile = std::env::var("USERPROFILE").ok();
    redact_with(input, profile.as_deref())
}

#[cfg(windows)]
fn windows_build() -> String {
    use windows_sys::Win32::System::Registry::{RegGetValueW, HKEY_LOCAL_MACHINE, RRF_RT_REG_SZ};

    let subkey: Vec<u16> = "SOFTWARE\\Microsoft\\Windows NT\\CurrentVersion"
        .encode_utf16()
        .chain(std::iter::once(0))
        .collect();
    let value: Vec<u16> = "CurrentBuild"
        .encode_utf16()
        .chain(std::iter::once(0))
        .collect();
    let mut buffer = [0u16; 64];
    let mut size = (buffer.len() * std::mem::size_of::<u16>()) as u32;
    // SAFETY: 缓冲区长度按字节传入，API 只写入该范围内。
    let status = unsafe {
        RegGetValueW(
            HKEY_LOCAL_MACHINE,
            subkey.as_ptr(),
            value.as_ptr(),
            RRF_RT_REG_SZ,
            std::ptr::null_mut(),
            buffer.as_mut_ptr() as *mut std::ffi::c_void,
            &mut size,
        )
    };
    if status != 0 {
        return "unknown".to_string();
    }
    let length = buffer.iter().position(|c| *c == 0).unwrap_or(buffer.len());
    String::from_utf16_lossy(&buffer[..length])
}

#[cfg(not(windows))]
fn windows_build() -> String {
    "unknown".to_string()
}

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
struct DoctorLog {
    app_version: String,
    windows_build: String,
    generated_at: u64,
    items: Vec<DoctorItem>,
}

fn log_directory() -> PathBuf {
    let root = std::env::var_os("LOCALAPPDATA")
        .map(PathBuf::from)
        .unwrap_or_else(std::env::temp_dir);
    root.join("Vega").join("logs")
}

fn export_blocking() -> Result<(), String> {
    let items = doctor_items();
    let redacted: Vec<DoctorItem> = items
        .into_iter()
        .map(|entry| DoctorItem {
            item: redact_text(&entry.item),
            status: redact_text(&entry.status),
            advice: redact_text(&entry.advice),
        })
        .collect();
    let now = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|duration| duration.as_secs())
        .unwrap_or(0);
    let log = DoctorLog {
        app_version: env!("CARGO_PKG_VERSION").to_string(),
        windows_build: windows_build(),
        generated_at: now,
        items: redacted,
    };
    let json = serde_json::to_string_pretty(&log)
        .map_err(|_| "生成脱敏日志失败".to_string())?;

    let directory = log_directory();
    std::fs::create_dir_all(&directory)
        .map_err(|_| "创建日志目录失败".to_string())?;
    let path = directory.join(format!("doctor-{now}.json"));
    let mut file = std::fs::File::create(&path)
        .map_err(|_| "写入脱敏日志失败".to_string())?;
    file.write_all(json.as_bytes())
        .map_err(|_| "写入脱敏日志失败".to_string())?;
    file.write_all(b"\n")
        .map_err(|_| "写入脱敏日志失败".to_string())?;

    if cfg!(windows) {
        let directory_text = directory.display().to_string();
        spawn_detached(Path::new("explorer.exe"), &[directory_text.as_str()])
            .map_err(|_| "日志已导出，但打开目录失败".to_string())?;
    }
    Ok(())
}

#[tauri::command]
pub async fn export_doctor_log() -> crate::rustdesk::OpResult {
    let result = tauri::async_runtime::spawn_blocking(export_blocking).await;
    match result {
        Ok(Ok(())) => crate::rustdesk::OpResult {
            ok: true,
            message: "脱敏日志已导出并打开所在目录".to_string(),
        },
        Ok(Err(message)) => crate::rustdesk::OpResult {
            ok: false,
            message,
        },
        Err(_) => crate::rustdesk::OpResult {
            ok: false,
            message: "导出脱敏日志失败".to_string(),
        },
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn doctor_status_labels_are_chinese() {
        assert_eq!(DoctorStatus::Pass.label(), "通过");
        assert_eq!(DoctorStatus::Warn.label(), "警告");
        assert_eq!(DoctorStatus::Fail.label(), "失败");
    }

    #[test]
    fn port_47990_mapping_depends_on_sunshine_state() {
        assert_eq!(
            port_47990_status(true, ServiceState::NotInstalled).0,
            DoctorStatus::Pass
        );
        assert_eq!(
            port_47990_status(false, ServiceState::Running).0,
            DoctorStatus::Fail
        );
        assert_eq!(
            port_47990_status(false, ServiceState::Stopped).0,
            DoctorStatus::Warn
        );
        assert_eq!(
            port_47990_status(false, ServiceState::Unknown).0,
            DoctorStatus::Warn
        );
    }

    #[test]
    fn ipv6_global_unicast_check_only_accepts_2000_slash_3() {
        assert!(is_global_unicast(&"2001:4860:4860::8888".parse().unwrap()));
        assert!(is_global_unicast(&"2a00:1450::1".parse().unwrap()));
        assert!(!is_global_unicast(&"fe80::1".parse().unwrap()));
        assert!(!is_global_unicast(&"fd00::1".parse().unwrap()));
        assert!(!is_global_unicast(&"::1".parse().unwrap()));
    }

    #[test]
    fn redaction_masks_addresses_hostnames_and_paths() {
        let input = "IPv4 192.168.1.20 IPv6 2001:4860:4860::8888 host pc.example.com profile C:\\Users\\alice file C:\\Users\\alice\\AppData\\x.log";
        let output = redact_with(input, Some("C:\\Users\\alice"));
        assert!(!output.contains("192.168.1.20"));
        assert!(!output.contains("2001:4860"));
        assert!(!output.contains("pc.example.com"));
        assert!(!output.contains("alice"));
        assert!(output.contains("<ip>"));
        assert!(output.contains("<host>"));
        assert!(output.contains("<profile>"));
        assert!(output.contains("<path>"));
    }

    #[test]
    fn redaction_keeps_plain_versions_and_status_text() {
        let output = redact_with("版本 0.5.0 状态 通过", None);
        assert_eq!(output, "版本 0.5.0 状态 通过");
    }

    #[test]
    fn redaction_masks_host_port_and_bracketed_ipv6() {
        let output = redact_with("server 192.0.2.1:21116 relay [2001:db8::1]:21117", None);
        assert!(!output.contains("192.0.2.1"));
        assert!(!output.contains("2001:db8"));
        assert_eq!(output.matches("<ip>").count(), 2);
    }
}
