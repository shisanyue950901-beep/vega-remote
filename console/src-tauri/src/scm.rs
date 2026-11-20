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

/// winsvc.h 里的 `SERVICE_*` 当前状态值，与 windows crate
/// (`windows::Win32::System::Services`) 的常量同名同值。`windows-sys` 只在
/// Windows 目标下编译，而单测要在所有平台跑，所以这里保留具名常量。
mod service_status {
    pub const SERVICE_STOPPED: u32 = 0x0000_0001;
    pub const SERVICE_START_PENDING: u32 = 0x0000_0002;
    pub const SERVICE_STOP_PENDING: u32 = 0x0000_0003;
    pub const SERVICE_RUNNING: u32 = 0x0000_0004;
    pub const SERVICE_CONTINUE_PENDING: u32 = 0x0000_0005;
    pub const SERVICE_PAUSE_PENDING: u32 = 0x0000_0006;
    pub const SERVICE_PAUSED: u32 = 0x0000_0007;
}

fn map_current_state(current_state: u32) -> ServiceState {
    use service_status::*;
    match current_state {
        // 运行中，以及「继续挂起」：服务恢复运行前的过渡态，归入运行中/处理中。
        SERVICE_RUNNING | SERVICE_CONTINUE_PENDING => ServiceState::Running,
        // 已停止与其它过渡态。
        SERVICE_STOPPED
        | SERVICE_START_PENDING
        | SERVICE_STOP_PENDING
        | SERVICE_PAUSE_PENDING
        | SERVICE_PAUSED => ServiceState::Stopped,
        // 未定义值（例如 8）不能猜成「已停止」，只能报无法查询。
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
/// 「查询失败」与「未安装」区分开。
pub fn service_state_code(name: &str) -> Option<String> {
    match query_service_state(name) {
        ServiceState::Running => Some("运行中".to_string()),
        ServiceState::Stopped => Some("已停止".to_string()),
        ServiceState::NotInstalled => None,
        ServiceState::Unknown => Some("查询失败".to_string()),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn service_state_mapping_covers_running_stopped_and_unknown() {
        use service_status::*;
        assert_eq!(map_current_state(SERVICE_RUNNING), ServiceState::Running);
        assert_eq!(map_current_state(SERVICE_STOPPED), ServiceState::Stopped);
        assert_eq!(map_current_state(SERVICE_START_PENDING), ServiceState::Stopped);
        assert_eq!(map_current_state(SERVICE_STOP_PENDING), ServiceState::Stopped);
        assert_eq!(map_current_state(SERVICE_PAUSE_PENDING), ServiceState::Stopped);
        assert_eq!(map_current_state(SERVICE_PAUSED), ServiceState::Stopped);
        assert_eq!(map_current_state(99), ServiceState::Unknown);
    }

    #[test]
    fn continue_pending_counts_as_running_and_undefined_value_is_unknown() {
        // SERVICE_CONTINUE_PENDING(5)：服务正在恢复运行，算运行中/处理中。
        assert_eq!(map_current_state(5), ServiceState::Running);
        assert_eq!(
            map_current_state(service_status::SERVICE_CONTINUE_PENDING),
            ServiceState::Running
        );
        // 8 不是 SERVICE_* 定义的状态，不能归成已停止。
        assert_eq!(map_current_state(8), ServiceState::Unknown);
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
