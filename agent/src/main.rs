//! Vega 访问码服务（vega-agent.exe）。
//!
//! 以 LocalSystem 的 Windows 服务 `VegaAgent` 运行；`--console` 用于前台调试。
//! 服务启动时读/建 `%ProgramData%\Vega\agent\state.json`，总是把当前访问码重新
//! 应用一次到 RustDesk，然后启动命名管道与 rotate 会话轮换线程。

#![cfg_attr(windows, windows_subsystem = "windows")]

mod code;
mod log;
mod pipe;
mod rustdesk;
mod state;
mod watch;

#[cfg(windows)]
mod winutil;

use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, Mutex};

pub const SERVICE_NAME: &str = "VegaAgent";
pub const SERVICE_DISPLAY_NAME: &str = "Vega 访问码服务";

static STOP: AtomicBool = AtomicBool::new(false);

/// 访问码状态在进程内只有一份；所有修改都在锁内完成落盘与内存更新。
pub struct Agent {
    state: Mutex<state::State>,
}

impl Agent {
    pub fn snapshot(&self) -> Result<(String, String), String> {
        let guard = self.state.lock().map_err(|_| "状态锁不可用".to_string())?;
        Ok((guard.code.clone(), guard.mode_name().to_string()))
    }

    /// rotate 模式立即生成新码并应用。
    pub fn refresh(&self) -> Result<(String, String), String> {
        self.install(state::State::new_rotate()?)
    }

    /// 固定访问码：6–32 位字母或数字。
    pub fn set_fixed(&self, code: &str) -> Result<(String, String), String> {
        self.install(state::State::new_fixed(code)?)
    }

    /// 切回 rotate 模式并立即换新码。
    pub fn set_rotate(&self) -> Result<(String, String), String> {
        self.install(state::State::new_rotate()?)
    }

    /// 会话结束后轮换；fixed 模式不动。
    pub fn rotate_after_session(&self) -> Result<Option<(String, String)>, String> {
        let mut guard = self.state.lock().map_err(|_| "状态锁不可用".to_string())?;
        if guard.mode != state::Mode::Rotate {
            return Ok(None);
        }
        let next = state::State::new_rotate()?;
        state::save(&next)?;
        *guard = next.clone();
        drop(guard);
        apply_state(&next);
        log::event("访问码已轮换");
        Ok(Some((next.code, next.mode_name().to_string())))
    }

    fn install(&self, next: state::State) -> Result<(String, String), String> {
        let mut guard = self.state.lock().map_err(|_| "状态锁不可用".to_string())?;
        state::save(&next)?;
        *guard = next.clone();
        drop(guard);
        apply_state(&next);
        log::event("访问码已更新");
        Ok((next.code, next.mode_name().to_string()))
    }
}

/// 把状态里的码应用到 RustDesk；失败只记日志，不影响访问码服务本身可用。
fn apply_state(current: &state::State) {
    match rustdesk::apply_code(&current.code) {
        Ok(()) => log::event("访问码已应用到 RustDesk"),
        Err(err) => log::event(&format!("应用访问码到 RustDesk 失败：{err}")),
    }
}

/// 建目录、恢复状态、重新应用访问码。
fn bootstrap() -> Result<Arc<Agent>, String> {
    log::init();
    state::ensure_agent_dir()?;
    let current = match state::load() {
        Ok(Some(existing)) if existing.is_valid() => existing,
        Ok(Some(_)) => {
            log::event("状态文件中的访问码无效，已重新生成");
            let fresh = state::State::new_rotate()?;
            state::save(&fresh)?;
            fresh
        }
        Ok(None) => {
            let fresh = state::State::new_rotate()?;
            state::save(&fresh)?;
            fresh
        }
        Err(err) => {
            log::event(&format!("读取状态失败，按首次启动处理：{err}"));
            let fresh = state::State::new_rotate()?;
            state::save(&fresh)?;
            fresh
        }
    };
    // 设计约定：启动时总是重新应用一次，接受状态码与 RustDesk 短暂不一致的风险。
    apply_state(&current);
    log::event(&format!("访问码服务已启动（模式：{}）", current.mode_name()));
    Ok(Arc::new(Agent {
        state: Mutex::new(current),
    }))
}

fn start_workers(agent: &Arc<Agent>) {
    pipe::start(agent.clone());
    watch::start(agent.clone());
}

fn main() {
    let console = std::env::args().any(|arg| arg == "--console");
    log::set_console(console);
    #[cfg(windows)]
    {
        if console {
            run_console();
        } else {
            run_service();
        }
    }
    #[cfg(not(windows))]
    {
        let _ = console;
        eprintln!("vega-agent 只支持 Windows");
        std::process::exit(1);
    }
}

#[cfg(windows)]
fn run_console() {
    match bootstrap() {
        Ok(agent) => {
            start_workers(&agent);
            eprintln!("vega-agent 以前台模式运行，按 Ctrl+C 退出");
            loop {
                std::thread::sleep(std::time::Duration::from_secs(3600));
            }
        }
        Err(err) => {
            eprintln!("vega-agent 启动失败：{err}");
            std::process::exit(1);
        }
    }
}

#[cfg(windows)]
fn run_service() {
    use windows_sys::Win32::Foundation::GetLastError;
    use windows_sys::Win32::System::Services::{
        StartServiceCtrlDispatcherW, SERVICE_TABLE_ENTRYW,
    };

    let name = winutil::wide(SERVICE_NAME);
    let mut table = [
        SERVICE_TABLE_ENTRYW {
            lpServiceName: name.as_ptr() as *mut u16,
            lpServiceProc: Some(service_main),
        },
        // SAFETY: 全零即终止项（lpServiceName 为空、lpServiceProc 为 None）。
        unsafe { std::mem::zeroed::<SERVICE_TABLE_ENTRYW>() },
    ];
    // SAFETY: table 以空项结尾，name 缓冲区在调用期间存活。
    let ok = unsafe { StartServiceCtrlDispatcherW(table.as_mut_ptr()) };
    if ok == 0 {
        let error = unsafe { GetLastError() };
        eprintln!("连接服务控制管理器失败（错误码 {error}）");
        std::process::exit(1);
    }
}

#[cfg(windows)]
unsafe extern "system" fn service_main(_argc: u32, _argv: *mut *mut u16) {
    use windows_sys::Win32::System::Services::{
        RegisterServiceCtrlHandlerW, SERVICE_STATUS_HANDLE,
    };

    const SERVICE_START_PENDING: u32 = 0x0000_0002;
    const SERVICE_RUNNING: u32 = 0x0000_0004;
    const SERVICE_STOPPED: u32 = 0x0000_0001;
    const SERVICE_ACCEPT_STOP: u32 = 0x0000_0001;

    fn report(
        handle: SERVICE_STATUS_HANDLE,
        state: u32,
        accepted: u32,
        exit_code: u32,
        wait_hint: u32,
    ) {
        use windows_sys::Win32::System::Services::{SetServiceStatus, SERVICE_STATUS};
        const SERVICE_WIN32_OWN_PROCESS: u32 = 0x0000_0010;
        // SAFETY: 全零结构体随后逐字段填好，传给 SetServiceStatus。
        let mut status: SERVICE_STATUS = unsafe { std::mem::zeroed() };
        status.dwServiceType = SERVICE_WIN32_OWN_PROCESS;
        status.dwCurrentState = state;
        status.dwControlsAccepted = accepted;
        status.dwWin32ExitCode = exit_code;
        status.dwCheckPoint = 0;
        status.dwWaitHint = wait_hint;
        // SAFETY: handle 来自 RegisterServiceCtrlHandlerW，status 在调用期间有效。
        unsafe {
            SetServiceStatus(handle, &status);
        }
    }

    let name = winutil::wide(SERVICE_NAME);
    // SAFETY: 名称以 NUL 结尾；处理函数签名匹配 LPHANDLER_FUNCTIONW。
    let handle = RegisterServiceCtrlHandlerW(name.as_ptr(), Some(service_ctrl_handler));
    if handle == 0 {
        return;
    }
    report(handle, SERVICE_START_PENDING, 0, 0, 120_000);

    let agent = match bootstrap() {
        Ok(agent) => agent,
        Err(err) => {
            log::event(&format!("服务启动失败：{err}"));
            report(handle, SERVICE_STOPPED, 0, 1, 0);
            return;
        }
    };
    start_workers(&agent);
    report(handle, SERVICE_RUNNING, SERVICE_ACCEPT_STOP, 0, 0);

    while !STOP.load(Ordering::Relaxed) {
        std::thread::sleep(std::time::Duration::from_millis(200));
    }
    report(handle, SERVICE_STOPPED, 0, 0, 0);
}

#[cfg(windows)]
unsafe extern "system" fn service_ctrl_handler(control: u32) {
    use windows_sys::Win32::System::Services::SERVICE_CONTROL_STOP;

    if control == SERVICE_CONTROL_STOP {
        STOP.store(true, Ordering::Relaxed);
        log::event("收到停止信号");
    }
}
