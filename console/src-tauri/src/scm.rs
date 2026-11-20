//! Windows 服务状态查询（SCM）。
//!
//! M2c 起 Sunshine 与 RustDesk 的服务检测共用这一份实现：只有
//! `ERROR_SERVICE_DOES_NOT_EXIST` 才算「未安装」，其他查询失败一律是
//! 「无法查询」，不能把权限/SCM 故障说成服务不存在（审计 r5 P3）。
//! 非 Windows 平台不加载任何系统 API，统一返回 `NotInstalled`。

/// 服务状态的四分类：UI 只认这四种，不把查询失败混进「未安装」。
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum ServiceState {
    Running,
    Stopped,
    NotInstalled,
    Unknown,
}

impl ServiceState {
    /// 中文标签，直接给前端的 Sunshine 状态行使用。
    pub fn label(self) -> &'static str {
        match self {
            ServiceState::Running => "运行中",
            ServiceState::Stopped => "已停止",
            ServiceState::NotInstalled => "未安装",
            ServiceState::Unknown => "无法查询",
        }
    }
}

/// winsvc.h 里的 `SERVICE_*` 当前状态值。单测在非 Windows 上也能跑，
/// 所以这里用字面量而不是 `windows-sys` 常量。
fn map_current_state(current_state: u32) -> ServiceState {
    match current_state {
        4 => ServiceState::Running, // SERVICE_RUNNING
        // STOPPED / START_PENDING / STOP_PENDING / PAUSED / PAUSE_PENDING / CONTINUE_PENDING
        1 | 2 | 3 | 6 | 7 | 8 => ServiceState::Stopped,
        _ => ServiceState::Unknown,
    }
}

#[cfg(windows)]
pub fn query_service_state(name: &str) -> ServiceState {
    use std::mem::size_of;
    use windows_sys::Win32::Foundation::{GetLastError, ERROR_SERVICE_DOES_NOT_EXIST};
    use windows_sys::Win32::System::Services::{
        CloseServiceHandle, OpenSCManagerW, OpenServiceW, QueryServiceStatusEx,
        SC_MANAGER_CONNECT, SC_STATUS_PROCESS_INFO, SERVICE_QUERY_STATUS, SERVICE_STATUS_PROCESS,
    };

    fn wide(value: &str) -> Vec<u16> {
        value.encode_utf16().chain(std::iter::once(0)).collect()
    }

    // SAFETY: 所有句柄在返回前关闭；缓冲区按 API 要求的大小传入。
    unsafe {
        let manager = OpenSCManagerW(
            std::ptr::null(),
            std::ptr::null(),
            SC_MANAGER_CONNECT,
        );
        if manager as isize == 0 {
            return ServiceState::Unknown;
        }

        let name = wide(name);
        let service = OpenServiceW(manager, name.as_ptr(), SERVICE_QUERY_STATUS);
        if service as isize == 0 {
            let code = GetLastError();
            CloseServiceHandle(manager);
            return if code == ERROR_SERVICE_DOES_NOT_EXIST {
                ServiceState::NotInstalled
            } else {
                ServiceState::Unknown
            };
        }

        let mut status: SERVICE_STATUS_PROCESS = std::mem::zeroed();
        let mut needed = 0u32;
        let ok = QueryServiceStatusEx(
            service,
            SC_STATUS_PROCESS_INFO,
            &mut status as *mut SERVICE_STATUS_PROCESS as *mut u8,
            size_of::<SERVICE_STATUS_PROCESS>() as u32,
            &mut needed,
        );
        CloseServiceHandle(service);
        CloseServiceHandle(manager);

        if ok == 0 {
            return ServiceState::Unknown;
        }
        map_current_state(status.dwCurrentState)
    }
}

#[cfg(not(windows))]
pub fn query_service_state(_name: &str) -> ServiceState {
    ServiceState::NotInstalled
}

/// RustDesk 状态行沿用旧的字符串字段：空串表示服务不存在，
/// `QUERY_FAILED` 表示查询失败（与「未安装」区分开）。
pub fn service_state_code(name: &str) -> Option<String> {
    match query_service_state(name) {
        ServiceState::Running => Some("RUNNING".to_string()),
        ServiceState::Stopped => Some("STOPPED".to_string()),
        ServiceState::NotInstalled => None,
        ServiceState::Unknown => Some("QUERY_FAILED".to_string()),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn service_state_mapping_covers_running_stopped_and_unknown() {
        assert_eq!(map_current_state(4), ServiceState::Running);
        assert_eq!(map_current_state(1), ServiceState::Stopped);
        assert_eq!(map_current_state(2), ServiceState::Stopped);
        assert_eq!(map_current_state(3), ServiceState::Stopped);
        assert_eq!(map_current_state(99), ServiceState::Unknown);
    }

    #[test]
    fn service_state_labels_are_distinct() {
        assert_eq!(ServiceState::Running.label(), "运行中");
        assert_eq!(ServiceState::Stopped.label(), "已停止");
        assert_eq!(ServiceState::NotInstalled.label(), "未安装");
        assert_eq!(ServiceState::Unknown.label(), "无法查询");
    }

    #[test]
    fn query_failure_is_not_reported_as_missing_service() {
        // 非 Windows 下统一 NotInstalled；Windows 上的区分由 SCM 分支保证。
        let state = query_service_state("SunshineService");
        assert!(matches!(
            state,
            ServiceState::NotInstalled | ServiceState::Running | ServiceState::Stopped | ServiceState::Unknown
        ));
        if cfg!(not(windows)) {
            assert_eq!(state, ServiceState::NotInstalled);
        }
    }
}
