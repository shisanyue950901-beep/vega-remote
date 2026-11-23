//! 命名管道 `\\.\pipe\VegaAgent`：单行 JSON 请求、单行 JSON 回复。
//!
//! DACL 只给 SYSTEM 全部、Interactive Users 读写；PIPE_REJECT_REMOTE_CLIENTS
//! 拒绝远程连接。连接建立后先比对客户端会话号与当前活动控制台会话号，避免同机
//! 其他登录用户改访问码。单条消息上限 4 KiB。

use serde::Deserialize;
use serde_json::{json, Value};
use std::sync::Arc;

use crate::Agent;

pub const MAX_MESSAGE: usize = 4096;
pub const PIPE_NAME: &str = r"\\.\pipe\VegaAgent";
pub const PIPE_SDDL: &str = "D:P(A;;GA;;;SY)(A;;GRGW;;;IU)";

#[derive(Deserialize)]
struct Request {
    op: String,
    #[serde(default)]
    code: Option<String>,
}

pub fn start(agent: Arc<Agent>) {
    #[cfg(windows)]
    {
        std::thread::spawn(move || serve(agent));
    }
    #[cfg(not(windows))]
    {
        let _ = agent;
    }
}

#[cfg(windows)]
fn serve(agent: Arc<Agent>) {
    use windows_sys::Win32::Foundation::CloseHandle;
    use windows_sys::Win32::System::Pipes::DisconnectNamedPipe;

    loop {
        let handle = match create_pipe() {
            Ok(handle) => handle,
            Err(err) => {
                crate::log::event(&format!("创建命名管道失败：{err}"));
                std::thread::sleep(std::time::Duration::from_secs(1));
                continue;
            }
        };
        if !connect_pipe(handle) {
            // SAFETY: handle 由 create_pipe 返回且未被其他线程持有。
            unsafe {
                CloseHandle(handle);
            }
            std::thread::sleep(std::time::Duration::from_millis(200));
            continue;
        }
        let shared = agent.clone();
        // 连接建立后把句柄交给工作线程独占；工作线程结束后断开并关闭。
        std::thread::spawn(move || {
            handle_client(handle, shared);
            // SAFETY: 句柄由本工作线程独占。
            unsafe {
                DisconnectNamedPipe(handle);
                CloseHandle(handle);
            }
        });
    }
}

#[cfg(windows)]
fn create_pipe() -> Result<windows_sys::Win32::Foundation::HANDLE, String> {
    use std::mem::size_of;
    use windows_sys::Win32::Foundation::{GetLastError, INVALID_HANDLE_VALUE};
    use windows_sys::Win32::Security::SECURITY_ATTRIBUTES;
    use windows_sys::Win32::System::Pipes::{
        CreateNamedPipeW, PIPE_ACCESS_DUPLEX, PIPE_READMODE_BYTE, PIPE_REJECT_REMOTE_CLIENTS,
        PIPE_TYPE_BYTE, PIPE_UNLIMITED_INSTANCES, PIPE_WAIT,
    };

    let name = crate::winutil::wide(PIPE_NAME);
    let descriptor = crate::winutil::sddl_descriptor(PIPE_SDDL)?;
    let attributes = SECURITY_ATTRIBUTES {
        nLength: size_of::<SECURITY_ATTRIBUTES>() as u32,
        lpSecurityDescriptor: descriptor,
        bInheritHandle: 0,
    };
    // SAFETY: name 以 NUL 结尾；安全描述符在调用期间有效，调用后释放。
    let handle = unsafe {
        CreateNamedPipeW(
            name.as_ptr(),
            PIPE_ACCESS_DUPLEX,
            PIPE_TYPE_BYTE | PIPE_READMODE_BYTE | PIPE_WAIT | PIPE_REJECT_REMOTE_CLIENTS,
            PIPE_UNLIMITED_INSTANCES,
            MAX_MESSAGE as u32,
            MAX_MESSAGE as u32,
            0,
            &attributes,
        )
    };
    let error = unsafe { GetLastError() };
    crate::winutil::free_descriptor(descriptor);
    if handle == INVALID_HANDLE_VALUE {
        return Err(format!("CreateNamedPipeW 失败（错误码 {error}）"));
    }
    Ok(handle)
}

#[cfg(windows)]
fn connect_pipe(handle: windows_sys::Win32::Foundation::HANDLE) -> bool {
    use windows_sys::Win32::Foundation::GetLastError;
    use windows_sys::Win32::System::Pipes::ConnectNamedPipe;

    const ERROR_PIPE_CONNECTED: u32 = 535;
    // SAFETY: handle 是已创建的管道实例；同步模式，OVERLAPPED 传空。
    let ok = unsafe { ConnectNamedPipe(handle, std::ptr::null_mut()) };
    if ok != 0 {
        return true;
    }
    // 客户端可能在 ConnectNamedPipe 之前就已完成连接，这是正常竞态。
    unsafe { GetLastError() == ERROR_PIPE_CONNECTED }
}

#[cfg(windows)]
fn handle_client(handle: windows_sys::Win32::Foundation::HANDLE, agent: Arc<Agent>) {
    if !client_allowed(handle) {
        let _ = write_response(
            handle,
            &json!({"ok": false, "error": "只允许当前登录会话访问访问码服务"}),
        );
        return;
    }
    let line = match read_request(handle) {
        Ok(line) => line,
        Err(err) => {
            let _ = write_response(handle, &json!({"ok": false, "error": err}));
            return;
        }
    };
    let response = dispatch(&agent, &line);
    let _ = write_response(handle, &response);
}

#[cfg(windows)]
fn client_allowed(handle: windows_sys::Win32::Foundation::HANDLE) -> bool {
    use windows_sys::Win32::System::Pipes::GetNamedPipeClientSessionId;
    use windows_sys::Win32::System::RemoteDesktop::WTSGetActiveConsoleSessionId;

    let mut session = 0u32;
    // SAFETY: handle 是已连接的管道实例，session 是有效输出。
    let ok = unsafe { GetNamedPipeClientSessionId(handle, &mut session) };
    if ok == 0 {
        return false;
    }
    // SAFETY: 无参数、无副作用。
    let console = unsafe { WTSGetActiveConsoleSessionId() };
    console != u32::MAX && session == console
}

#[cfg(windows)]
fn read_request(handle: windows_sys::Win32::Foundation::HANDLE) -> Result<String, String> {
    use std::ptr;
    use windows_sys::Win32::Storage::FileSystem::ReadFile;

    let mut data: Vec<u8> = Vec::new();
    let mut buffer = [0u8; 1024];
    loop {
        let mut read = 0u32;
        // SAFETY: buffer 有效，read 是输出；同步读。
        let ok = unsafe {
            ReadFile(
                handle,
                buffer.as_mut_ptr() as *mut std::ffi::c_void,
                buffer.len() as u32,
                &mut read,
                ptr::null_mut(),
            )
        };
        if ok == 0 {
            return Err("读取请求失败".to_string());
        }
        if read == 0 {
            return Err("连接已关闭".to_string());
        }
        data.extend_from_slice(&buffer[..read as usize]);
        if let Some(position) = data.iter().position(|byte| *byte == b'\n') {
            data.truncate(position);
            break;
        }
        if data.len() > MAX_MESSAGE {
            return Err("请求过大".to_string());
        }
    }
    if data.len() > MAX_MESSAGE {
        return Err("请求过大".to_string());
    }
    String::from_utf8(data).map_err(|_| "请求编码无效".to_string())
}

#[cfg(windows)]
fn write_response(handle: windows_sys::Win32::Foundation::HANDLE, value: &Value) -> Result<(), String> {
    use std::ptr;
    use windows_sys::Win32::Storage::FileSystem::WriteFile;

    let mut payload = serde_json::to_vec(value).map_err(|_| "响应序列化失败".to_string())?;
    payload.push(b'\n');
    let mut written = 0u32;
    // SAFETY: payload 有效，written 是输出；同步写。
    let ok = unsafe {
        WriteFile(
            handle,
            payload.as_ptr() as *const std::ffi::c_void,
            payload.len() as u32,
            &mut written,
            ptr::null_mut(),
        )
    };
    if ok == 0 {
        return Err("写入响应失败".to_string());
    }
    Ok(())
}

fn dispatch(agent: &Agent, line: &str) -> Value {
    let request: Request = match serde_json::from_str(line) {
        Ok(request) => request,
        Err(_) => return json!({"ok": false, "error": "请求格式无效"}),
    };
    let result = match request.op.as_str() {
        "get" => agent.snapshot(),
        "refresh" => agent.refresh(),
        "set_fixed" => match request.code.as_deref() {
            Some(code) => agent.set_fixed(code),
            None => Err("缺少访问码".to_string()),
        },
        "set_rotate" => agent.set_rotate(),
        _ => Err("不支持的操作".to_string()),
    };
    match result {
        Ok((code, mode)) => json!({"ok": true, "code": code, "mode": mode}),
        Err(error) => json!({"ok": false, "error": error}),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn message_limit_is_four_kib() {
        assert_eq!(MAX_MESSAGE, 4096);
    }

    #[test]
    fn pipe_sddl_only_allows_system_and_interactive_users() {
        assert!(PIPE_SDDL.contains(";;;SY"));
        assert!(PIPE_SDDL.contains(";;;IU"));
        assert!(!PIPE_SDDL.contains(";;;WD"));
    }
}
