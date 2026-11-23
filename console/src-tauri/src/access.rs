//! 访问码服务（`vega-agent`）的命名管道客户端。
//!
//! 控制台不读 RustDesk 的临时密码，也不自己保存访问码：它只通过
//! `\\.\pipe\VegaAgent` 向 LocalSystem 的 `VegaAgent` 服务要当前访问码。
//! 协议是一行 JSON 请求、一行 JSON 回复，单条消息不超过 4 KiB。
//!
//! 管道调用是阻塞的，Tauri 命令统一走 `spawn_blocking`；整次调用（打开管道、
//! 写入、读取）限时 3 秒，超时返回中文错误，不把线程永久卡在服务端上。

use std::time::Duration;

use serde::{Deserialize, Serialize};

/// 与 agent 侧 `MAX_MESSAGE` 一致：请求和回复都不得超过 4 KiB。
pub const MAX_MESSAGE: usize = 4096;
/// 管道名：与 agent 的 `pipe::PIPE_NAME` 保持一致。
pub const PIPE_PATH: &str = r"\\.\pipe\VegaAgent";
/// 等待管道实例就绪的上限。
const WAIT_PIPE_MS: u32 = 2000;
/// 整次管道调用的上限。
const CALL_TIMEOUT: Duration = Duration::from_secs(3);
const FIXED_MIN_LEN: usize = 6;
const FIXED_MAX_LEN: usize = 32;

/// 前端需要的访问码视图。`rotatesAfterSession` 由 agent 的 `mode` 推导：
/// `rotate` → true，`fixed` → false。
#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct AccessCode {
    pub code: String,
    pub rotates_after_session: bool,
}

/// 一行请求。`serde(tag = "op")` 让四个操作共用同一套序列化规则。
#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
#[serde(tag = "op", rename_all = "snake_case")]
pub enum Request {
    Get,
    Refresh,
    SetFixed { code: String },
    SetRotate,
}

impl Request {
    /// 序列化成「一行 JSON + 换行」；换行是协议的帧分隔符。
    pub fn encode(&self) -> Result<Vec<u8>, String> {
        if let Request::SetFixed { code } = self {
            validate_fixed(code)?;
        }
        let mut line = serde_json::to_vec(self).map_err(|_| "生成访问码请求失败".to_string())?;
        line.push(b'\n');
        if line.len() > MAX_MESSAGE {
            return Err("访问码请求过长".to_string());
        }
        Ok(line)
    }
}

/// agent 的回复。字段全部可选，缺字段由 `parse_reply` 给出具体中文原因。
#[derive(Debug, Deserialize)]
struct Reply {
    ok: bool,
    #[serde(default)]
    code: Option<String>,
    #[serde(default)]
    mode: Option<String>,
    #[serde(default)]
    error: Option<String>,
}

/// 解析 agent 的一行回复。错误信息只来自 agent 或本模块的固定文案，
/// 绝不回显请求里的访问码。
pub fn parse_reply(raw: &str) -> Result<AccessCode, String> {
    let line = raw.trim_end_matches(['\r', '\n']);
    if line.len() > MAX_MESSAGE {
        return Err("访问码服务返回内容过长".to_string());
    }
    if line.trim().is_empty() {
        return Err("访问码服务返回空响应".to_string());
    }
    let reply: Reply =
        serde_json::from_str(line).map_err(|_| "访问码服务返回格式无效".to_string())?;
    if !reply.ok {
        let message = reply
            .error
            .as_deref()
            .map(str::trim)
            .filter(|text| !text.is_empty())
            .unwrap_or("访问码服务返回未知错误");
        return Err(message.to_string());
    }
    let code = reply
        .code
        .map(|code| code.trim().to_string())
        .filter(|code| !code.is_empty())
        .ok_or_else(|| "访问码服务未返回访问码".to_string())?;
    let mode = reply
        .mode
        .map(|mode| mode.trim().to_ascii_lowercase())
        .filter(|mode| !mode.is_empty())
        .ok_or_else(|| "访问码服务未返回访问码模式".to_string())?;
    let rotates_after_session = match mode.as_str() {
        "rotate" => true,
        "fixed" => false,
        _ => return Err("访问码服务返回未知模式".to_string()),
    };
    Ok(AccessCode {
        code,
        rotates_after_session,
    })
}

/// 固定访问码规则：6–32 位 ASCII 字母或数字。与 agent 侧校验一致，
/// 先在控制台拦一次，用户能立刻看到原因，不必等管道往返。
pub fn validate_fixed(code: &str) -> Result<(), String> {
    if code.is_empty() {
        return Err("访问码不能为空".to_string());
    }
    if code.len() < FIXED_MIN_LEN {
        return Err(format!("访问码至少需要 {FIXED_MIN_LEN} 位"));
    }
    if code.len() > FIXED_MAX_LEN {
        return Err(format!("访问码最多 {FIXED_MAX_LEN} 位"));
    }
    if !code.bytes().all(|byte| byte.is_ascii_alphanumeric()) {
        return Err("访问码只能包含字母或数字".to_string());
    }
    Ok(())
}

/// 在独立线程里跑管道调用，主流程最多等 3 秒。
fn call_with_timeout(request: Request) -> Result<AccessCode, String> {
    let (sender, receiver) = std::sync::mpsc::channel();
    std::thread::spawn(move || {
        let _ = sender.send(call_pipe(&request));
    });
    match receiver.recv_timeout(CALL_TIMEOUT) {
        Ok(result) => result,
        Err(std::sync::mpsc::RecvTimeoutError::Timeout) => {
            Err("访问码服务响应超时，请检查 Vega 访问码服务".to_string())
        }
        Err(std::sync::mpsc::RecvTimeoutError::Disconnected) => {
            Err("访问码服务连接已断开".to_string())
        }
    }
}

async fn call(request: Request) -> Result<AccessCode, String> {
    tauri::async_runtime::spawn_blocking(move || call_with_timeout(request))
        .await
        .map_err(|_| "访问码服务后台任务失败".to_string())?
}

#[cfg(windows)]
fn call_pipe(request: &Request) -> Result<AccessCode, String> {
    use windows_sys::Win32::Foundation::{CloseHandle, INVALID_HANDLE_VALUE};
    use windows_sys::Win32::Storage::FileSystem::{CreateFileW, FILE_ATTRIBUTE_NORMAL};
    use windows_sys::Win32::System::Pipes::WaitNamedPipeW;

    // 本地定义以避开 windows-sys 版本间常量位置差异。
    const GENERIC_READ: u32 = 0x8000_0000;
    const GENERIC_WRITE: u32 = 0x4000_0000;
    const OPEN_EXISTING: u32 = 3;
    const ERROR_PIPE_BUSY: u32 = 231;
    const ERROR_FILE_NOT_FOUND: u32 = 2;

    let name = wide(PIPE_PATH);
    let mut handle = unsafe {
        CreateFileW(
            name.as_ptr(),
            GENERIC_READ | GENERIC_WRITE,
            0,
            std::ptr::null(),
            OPEN_EXISTING,
            FILE_ATTRIBUTE_NORMAL,
            Default::default(),
        )
    };
    if handle == INVALID_HANDLE_VALUE {
        // SAFETY: 无参数、无副作用。
        let mut error = unsafe { windows_sys::Win32::Foundation::GetLastError() };
        if error == ERROR_PIPE_BUSY {
            // 服务在，但所有实例都在忙：等一个实例空出来再重试一次。
            // SAFETY: name 以 NUL 结尾且在调用期间存活。
            if unsafe { WaitNamedPipeW(name.as_ptr(), WAIT_PIPE_MS) } == 0 {
                return Err("访问码服务未运行".to_string());
            }
            handle = unsafe {
                CreateFileW(
                    name.as_ptr(),
                    GENERIC_READ | GENERIC_WRITE,
                    0,
                    std::ptr::null(),
                    OPEN_EXISTING,
                    FILE_ATTRIBUTE_NORMAL,
                    Default::default(),
                )
            };
            if handle == INVALID_HANDLE_VALUE {
                error = unsafe { windows_sys::Win32::Foundation::GetLastError() };
            }
        }
        if handle == INVALID_HANDLE_VALUE {
            return Err(if error == ERROR_FILE_NOT_FOUND || error == ERROR_PIPE_BUSY {
                "访问码服务未运行".to_string()
            } else {
                "无法连接访问码服务".to_string()
            });
        }
    }

    let result = (|| {
        let payload = request.encode()?;
        write_all(handle, &payload)?;
        let line = read_line(handle)?;
        parse_reply(&line)
    })();

    // SAFETY: handle 由本函数独占，写完/读完后立即关闭。
    unsafe {
        CloseHandle(handle);
    }
    result
}

#[cfg(not(windows))]
fn call_pipe(_request: &Request) -> Result<AccessCode, String> {
    Err("仅支持 Windows".to_string())
}

#[cfg(windows)]
fn write_all(handle: windows_sys::Win32::Foundation::HANDLE, mut data: &[u8]) -> Result<(), String> {
    use windows_sys::Win32::Storage::FileSystem::WriteFile;

    while !data.is_empty() {
        let mut written = 0u32;
        // SAFETY: data 有效，written 是输出；同步写。
        let ok = unsafe {
            WriteFile(
                handle,
                data.as_ptr() as *const std::ffi::c_void,
                data.len() as u32,
                &mut written,
                std::ptr::null_mut(),
            )
        };
        if ok == 0 || written == 0 {
            return Err("写入访问码请求失败".to_string());
        }
        data = &data[written as usize..];
    }
    Ok(())
}

#[cfg(windows)]
fn read_line(handle: windows_sys::Win32::Foundation::HANDLE) -> Result<String, String> {
    use windows_sys::Win32::Storage::FileSystem::ReadFile;

    let mut data: Vec<u8> = Vec::new();
    let mut buffer = [0u8; 512];
    loop {
        let mut read = 0u32;
        // SAFETY: buffer 有效，read 是输出；同步读。
        let ok = unsafe {
            ReadFile(
                handle,
                buffer.as_mut_ptr() as *mut std::ffi::c_void,
                buffer.len() as u32,
                &mut read,
                std::ptr::null_mut(),
            )
        };
        if ok == 0 {
            return Err("读取访问码回复失败".to_string());
        }
        if read == 0 {
            return Err("访问码服务关闭了连接".to_string());
        }
        data.extend_from_slice(&buffer[..read as usize]);
        if let Some(position) = data.iter().position(|byte| *byte == b'\n') {
            data.truncate(position);
            break;
        }
        if data.len() > MAX_MESSAGE {
            return Err("访问码服务返回内容过长".to_string());
        }
    }
    String::from_utf8(data).map_err(|_| "访问码服务返回编码无效".to_string())
}

#[cfg(windows)]
fn wide(value: &str) -> Vec<u16> {
    use std::os::windows::ffi::OsStrExt;
    std::ffi::OsStr::new(value)
        .encode_wide()
        .chain(std::iter::once(0))
        .collect()
}

#[tauri::command]
pub async fn get_access_code() -> Result<AccessCode, String> {
    call(Request::Get).await
}

#[tauri::command]
pub async fn refresh_access_code() -> Result<AccessCode, String> {
    call(Request::Refresh).await
}

#[tauri::command]
pub async fn set_fixed_access_code(code: String) -> Result<AccessCode, String> {
    validate_fixed(&code)?;
    call(Request::SetFixed { code }).await
}

#[tauri::command]
pub async fn set_rotate_access_code() -> Result<AccessCode, String> {
    call(Request::SetRotate).await
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn message_limit_matches_agent() {
        assert_eq!(MAX_MESSAGE, 4096);
        assert_eq!(PIPE_PATH, r"\\.\pipe\VegaAgent");
    }

    #[test]
    fn request_serialization_matches_protocol() {
        let cases = [
            (Request::Get, r#"{"op":"get"}"#),
            (Request::Refresh, r#"{"op":"refresh"}"#),
            (Request::SetRotate, r#"{"op":"set_rotate"}"#),
            (
                Request::SetFixed {
                    code: "Abc123".to_string(),
                },
                r#"{"op":"set_fixed","code":"Abc123"}"#,
            ),
        ];
        for (request, want) in cases {
            let encoded = match request.encode() {
                Ok(encoded) => encoded,
                Err(err) => panic!("序列化失败：{err}"),
            };
            assert_eq!(encoded.last(), Some(&b'\n'));
            assert_eq!(String::from_utf8_lossy(&encoded).trim_end(), want);
        }
    }

    #[test]
    fn set_fixed_request_escapes_json() {
        let request = Request::SetFixed {
            code: "a\"b".to_string(),
        };
        // 非法字符在本地校验就被拦下，不会发到管道。
        assert!(request.encode().is_err());
        let request = Request::SetFixed {
            code: "Abc123".to_string(),
        };
        let encoded = String::from_utf8(request.encode().unwrap()).unwrap();
        assert!(encoded.contains(r#""code":"Abc123""#));
    }

    #[test]
    fn fixed_validation_rejects_bad_input_without_echo() {
        assert!(validate_fixed("482916").is_ok());
        assert!(validate_fixed("Abc123").is_ok());
        assert!(validate_fixed("0123456789abcdefABCDEF01234567").is_ok());
        for bad in [
            "",
            "12345",
            "123456789012345678901234567890123",
            "123 456",
            "123-456",
            "访问码一二三四五",
            "12345é",
        ] {
            let err = validate_fixed(bad).unwrap_err();
            if !bad.is_empty() {
                assert!(!err.contains(bad), "错误信息不应回显输入：{bad:?}");
            }
        }
    }

    #[test]
    fn parse_reply_reads_rotate_and_fixed() {
        let rotate = parse_reply("{\"ok\":true,\"code\":\"482916\",\"mode\":\"rotate\"}\n")
            .expect("rotate 回复应可解析");
        assert_eq!(rotate.code, "482916");
        assert!(rotate.rotates_after_session);

        let fixed = parse_reply("{\"ok\":true,\"code\":\"Abc123\",\"mode\":\"fixed\"}")
            .expect("fixed 回复应可解析");
        assert_eq!(fixed.code, "Abc123");
        assert!(!fixed.rotates_after_session);

        // CRLF 与首尾空白不影响解析。
        let padded = parse_reply("  {\"ok\":true,\"code\":\"482916\",\"mode\":\"rotate\"}\r\n")
            .expect("带空白的回复应可解析");
        assert_eq!(padded.code, "482916");
    }

    #[test]
    fn parse_reply_surfaces_agent_error() {
        let err = parse_reply("{\"ok\":false,\"error\":\"访问码只能包含字母或数字\"}")
            .expect_err("ok=false 必须报错");
        assert_eq!(err, "访问码只能包含字母或数字");
        // 没有 error 字段时给固定文案，不把 JSON 原文抛给用户。
        let err = parse_reply("{\"ok\":false}").expect_err("ok=false 必须报错");
        assert_eq!(err, "访问码服务返回未知错误");
    }

    #[test]
    fn parse_reply_rejects_missing_fields_and_bad_shapes() {
        for raw in [
            "{\"ok\":true,\"mode\":\"rotate\"}",
            "{\"ok\":true,\"code\":\"482916\"}",
            "{\"ok\":true,\"code\":\"\",\"mode\":\"rotate\"}",
            "{\"ok\":true,\"code\":\"482916\",\"mode\":\"bogus\"}",
            "{\"code\":\"482916\",\"mode\":\"rotate\"}",
            "not json",
            "",
            "   ",
        ] {
            assert!(parse_reply(raw).is_err(), "应拒绝：{raw}");
        }
        assert_eq!(
            parse_reply("{\"ok\":true,\"code\":\"482916\",\"mode\":\"bogus\"}").unwrap_err(),
            "访问码服务返回未知模式"
        );
        assert_eq!(
            parse_reply("{\"ok\":true,\"mode\":\"rotate\"}").unwrap_err(),
            "访问码服务未返回访问码"
        );
        assert_eq!(
            parse_reply("{\"ok\":true,\"code\":\"482916\"}").unwrap_err(),
            "访问码服务未返回访问码模式"
        );
    }

    #[test]
    fn parse_reply_rejects_oversized_message() {
        let oversized = format!(
            "{{\"ok\":true,\"code\":\"{}\",\"mode\":\"rotate\"}}",
            "1".repeat(MAX_MESSAGE)
        );
        assert_eq!(
            parse_reply(&oversized).unwrap_err(),
            "访问码服务返回内容过长"
        );
    }

    #[test]
    fn oversized_fixed_request_is_rejected_before_pipe() {
        // 超长固定码先被 6–32 位规则拦下，不会构造出超 4 KiB 的消息。
        let request = Request::SetFixed {
            code: "a".repeat(MAX_MESSAGE),
        };
        assert!(request.encode().is_err());
    }
}
