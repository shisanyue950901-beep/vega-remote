//! 高性能串流页（M2c）：Sunshine / Moonlight 只读检测与固定动作。
//!
//! 架构约束：
//! - Vega 不提权，不写 Sunshine/Moonlight 配置，不接触 Sunshine 管理密码；
//! - 所有外部命令使用固定绝对路径与固定参数，不接受前端传入的 URL/命令；
//! - 管理页 URL 写死在 Rust 侧，按钮只负责交给默认浏览器；
//! - 安装命令原样取自仓库 README 的一行安装，前端只复制、不执行。

use serde::Serialize;
use std::path::{Path, PathBuf};

use crate::rustdesk::{explorer_exe, spawn_detached, OpResult};
use crate::scm::{query_service_state, ServiceState};

/// Sunshine 管理口只监听本机（安装脚本的 origin_web_ui_allowed = pc）。
const SUNSHINE_PAIRING_URL: &str = "https://localhost:47990/pin";
const SUNSHINE_SETTINGS_URL: &str = "https://localhost:47990";
const SUNSHINE_SERVICE: &str = "SunshineService";

/// README 里的一行安装命令：编译期嵌入，复制内容与文档逐字一致。
const README: &str = include_str!("../../../README.md");
/// 兜底只在 README 结构变化、grep 不到时使用；与当前 README 第 10 行一致。
const FALLBACK_INSTALL_COMMAND: &str =
    "irm https://raw.githubusercontent.com/shisanyue950901-beep/vega-remote/main/bootstrap.ps1 | iex";

fn readme_install_command() -> &'static str {
    README
        .lines()
        .map(str::trim)
        .find(|line| line.starts_with("irm ") && line.contains("| iex"))
        .unwrap_or(FALLBACK_INSTALL_COMMAND)
}

/// 系统 `Program Files`：必须是系统盘上的 Program Files，避免被伪造的
/// `ProgramFiles` 环境变量引到任意目录。
pub(crate) fn program_files_dir() -> Option<PathBuf> {
    let raw = std::env::var_os("ProgramFiles")?;
    let dir = std::fs::canonicalize(PathBuf::from(raw)).ok()?;
    let system_drive = std::env::var_os("SystemDrive").unwrap_or_else(|| "C:".into());
    let expected_raw = PathBuf::from(system_drive).join("Program Files");
    let expected = std::fs::canonicalize(expected_raw).ok()?;
    if dir == expected {
        Some(dir)
    } else {
        None
    }
}

fn under_program_files(path: &Path) -> bool {
    let Some(root) = program_files_dir() else {
        return false;
    };
    let Ok(full) = std::fs::canonicalize(path) else {
        return false;
    };
    full.starts_with(&root)
}

/// Moonlight 安装位置。`Err` 表示无法确认安全的 Program Files；
/// `Ok(None)` 表示确实没装。
pub(crate) fn moonlight_exe() -> Result<Option<PathBuf>, String> {
    if !cfg!(windows) {
        return Ok(None);
    }
    if program_files_dir().is_none() {
        return Err("无法确认系统 Program Files 目录".to_string());
    }
    let candidate = program_files_dir()
        .expect("上面已确认存在")
        .join("Moonlight Game Streaming")
        .join("Moonlight.exe");
    if !candidate.is_file() {
        return Ok(None);
    }
    if !under_program_files(&candidate) {
        return Err("Moonlight 路径不在系统 Program Files 下".to_string());
    }
    Ok(Some(candidate))
}

/// Tailscale 客户端是否安装在系统 Program Files 下（doctor 复用）。
pub(crate) fn tailscale_installed() -> bool {
    let Some(root) = program_files_dir() else {
        return false;
    };
    root.join("Tailscale").join("tailscale.exe").is_file()
}

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
pub struct GpuInfo {
    pub name: String,
    pub kind: String,
    pub encoder: String,
    pub memory_mb: u64,
}

fn classify_gpu(vendor_id: u32, memory_bytes: u64) -> (&'static str, &'static str) {
    let dedicated = match vendor_id {
        0x8086 => false,
        0x10DE | 0x1002 => memory_bytes > 512 * 1024 * 1024,
        _ => memory_bytes > 512 * 1024 * 1024,
    };
    let encoder = match vendor_id {
        0x10DE => "NVENC",
        0x1002 => "AMF",
        0x8086 => "QSV",
        _ => "未知",
    };
    (if dedicated { "独显" } else { "核显" }, encoder)
}

#[cfg(windows)]
fn list_gpus() -> Vec<GpuInfo> {
    use windows::Win32::Graphics::Dxgi::{
        CreateDXGIFactory1, IDXGIFactory1, DXGI_ADAPTER_FLAG_SOFTWARE,
    };

    let mut result = Vec::new();
    // SAFETY: 只读枚举 DXGI 适配器；每个适配器对象在循环内释放。
    unsafe {
        let factory: IDXGIFactory1 = match CreateDXGIFactory1() {
            Ok(factory) => factory,
            Err(_) => return result,
        };
        let mut index = 0u32;
        loop {
            let adapter = match factory.EnumAdapters1(index) {
                Ok(adapter) => adapter,
                Err(_) => break,
            };
            index += 1;
            let desc = match adapter.GetDesc1() {
                Ok(desc) => desc,
                Err(_) => continue,
            };
            // 跳过 Microsoft Basic Render Driver 等软件适配器。
            if desc.Flags & DXGI_ADAPTER_FLAG_SOFTWARE.0 as u32 != 0 {
                continue;
            }
            let name = String::from_utf16_lossy(&desc.Description)
                .trim_end_matches('\0')
                .trim()
                .to_string();
            if name.is_empty() {
                continue;
            }
            let vendor_id = desc.VendorId;
            let memory_bytes = desc.DedicatedVideoMemory as u64;
            let (kind, encoder) = classify_gpu(vendor_id, memory_bytes);
            result.push(GpuInfo {
                name,
                kind: kind.to_string(),
                encoder: encoder.to_string(),
                memory_mb: memory_bytes / (1024 * 1024),
            });
        }
    }
    result
}

#[cfg(not(windows))]
fn list_gpus() -> Vec<GpuInfo> {
    Vec::new()
}

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
pub struct StreamingStatus {
    pub sunshine_state: String,
    pub sunshine_label: String,
    pub gpus: Vec<GpuInfo>,
    pub moonlight_installed: bool,
    pub moonlight_error: String,
    pub host_install_command: String,
    pub client_install_command: String,
}

fn sunshine_fields(state: ServiceState) -> (String, String) {
    let key = match state {
        ServiceState::Running => "running",
        ServiceState::Stopped => "stopped",
        ServiceState::NotInstalled => "notInstalled",
        ServiceState::Unknown => "unknown",
    };
    (key.to_string(), state.label().to_string())
}

fn streaming_status_blocking() -> StreamingStatus {
    let sunshine = query_service_state(SUNSHINE_SERVICE);
    let (sunshine_state, sunshine_label) = sunshine_fields(sunshine);
    let (moonlight_installed, moonlight_error) = match moonlight_exe() {
        Ok(Some(_)) => (true, String::new()),
        Ok(None) => (false, String::new()),
        Err(error) => (false, error),
    };
    let command = readme_install_command().to_string();
    StreamingStatus {
        sunshine_state,
        sunshine_label,
        gpus: list_gpus(),
        moonlight_installed,
        moonlight_error,
        // README 的一行安装会交互询问被控端/控制端；两个按钮复制同一条命令，
        // 由用户按提示选择角色。
        host_install_command: command.clone(),
        client_install_command: command,
    }
}

#[tauri::command]
pub async fn get_streaming_status() -> StreamingStatus {
    tauri::async_runtime::spawn_blocking(streaming_status_blocking)
        .await
        .unwrap_or_else(|_| StreamingStatus {
            sunshine_state: "unknown".to_string(),
            sunshine_label: "无法查询".to_string(),
            gpus: Vec::new(),
            moonlight_installed: false,
            moonlight_error: "读取串流状态失败".to_string(),
            host_install_command: readme_install_command().to_string(),
            client_install_command: readme_install_command().to_string(),
        })
}

fn open_fixed_url(url: &str, ok_message: &str) -> OpResult {
    match spawn_detached(&explorer_exe(), &[url]) {
        Ok(()) => OpResult {
            ok: true,
            message: ok_message.to_string(),
        },
        Err(error) => OpResult {
            ok: false,
            message: format!("打开浏览器失败：{error}"),
        },
    }
}

/// 「打开配对」：URL 固定为 Sunshine 本机管理页，PIN 由 Sunshine 页面接收。
#[tauri::command]
pub fn open_sunshine_pairing() -> OpResult {
    if !cfg!(windows) {
        return OpResult {
            ok: false,
            message: "只有 Windows 控制台能打开 Sunshine 管理页".to_string(),
        };
    }
    open_fixed_url(
        SUNSHINE_PAIRING_URL,
        "已在默认浏览器中打开 Sunshine 配对页，请在页面中输入 PIN",
    )
}

#[tauri::command]
pub fn open_sunshine_settings() -> OpResult {
    if !cfg!(windows) {
        return OpResult {
            ok: false,
            message: "只有 Windows 控制台能打开 Sunshine 管理页".to_string(),
        };
    }
    open_fixed_url(
        SUNSHINE_SETTINGS_URL,
        "已在默认浏览器中打开 Sunshine 设置页",
    )
}

/// 「开始串流」：无参数启动已校验路径的 Moonlight.exe。
#[tauri::command]
pub fn start_moonlight_stream() -> OpResult {
    match moonlight_exe() {
        Ok(Some(path)) => match spawn_detached(&path, &[]) {
            Ok(()) => OpResult {
                ok: true,
                message: "已打开 Moonlight，请在 Moonlight 中选择已配对主机".to_string(),
            },
            Err(error) => OpResult {
                ok: false,
                message: format!("启动 Moonlight 失败：{error}"),
            },
        },
        Ok(None) => OpResult {
            ok: false,
            message: "未安装 Moonlight".to_string(),
        },
        Err(error) => OpResult {
            ok: false,
            message: error,
        },
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn install_command_comes_from_readme_one_liner() {
        let command = readme_install_command();
        assert!(command.starts_with("irm "));
        assert!(command.ends_with("| iex"));
        assert!(command.contains("bootstrap.ps1"));
    }

    #[test]
    fn gpu_classification_uses_vendor_and_memory() {
        assert_eq!(classify_gpu(0x8086, 16 * 1024 * 1024 * 1024), ("核显", "QSV"));
        assert_eq!(classify_gpu(0x10DE, 8 * 1024 * 1024 * 1024), ("独显", "NVENC"));
        assert_eq!(classify_gpu(0x1002, 4 * 1024 * 1024 * 1024), ("独显", "AMF"));
        // 显存 <= 512 MB 的 NVIDIA/AMD 适配器按核显展示（例如共享显存的老设备）。
        assert_eq!(classify_gpu(0x10DE, 256 * 1024 * 1024), ("核显", "NVENC"));
    }

    #[test]
    fn sunshine_state_keys_cover_all_four_states() {
        assert_eq!(sunshine_fields(ServiceState::Running).0, "running");
        assert_eq!(sunshine_fields(ServiceState::Stopped).0, "stopped");
        assert_eq!(
            sunshine_fields(ServiceState::NotInstalled).0,
            "notInstalled"
        );
        assert_eq!(sunshine_fields(ServiceState::Unknown).0, "unknown");
    }
}
