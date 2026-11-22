//! 长期密码后端（T4-fix1a）：密码只经「创建时即带 DACL」的临时文件交给提权助手，
//! 绝不进命令行/日志/返回值；状态读助手成功后写入的 pw-state.json，验证方式读 RustDesk2.toml。
use crate::rustdesk::{self, OpResult};
use serde::Serialize;
use std::path::{Path, PathBuf};
use std::time::Duration;
const MIN_LEN: usize = 8;
const MAX_LEN: usize = 64;
const HELPER_SCRIPT: &str = "vega-pwhelper.ps1";
const STATE_FILE: &str = "pw-state.json";
const PAYLOAD_TTL_SECS: u64 = 30;
const HELPER_TIMEOUT_MS: u32 = 60_000;
const SYMBOLS: &str = "!#$%&*+,-./:;<=>?@^_~";
const CLEAR_VERIFICATION: &str = "use-temporary-password";
const SW_HIDE: i32 = 0;
const ERROR_CANCELLED: u32 = 1223;
const WAIT_TIMEOUT: u32 = 258;
#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
pub struct PasswordStatus { pub has_permanent: bool, pub verify_method: String }
pub fn validate_password(password: &str) -> Result<(), String> {
    let chars: Vec<char> = password.chars().collect();
    if !(MIN_LEN..=MAX_LEN).contains(&chars.len()) { return Err(format!("密码需为 {MIN_LEN}~{MAX_LEN} 位")); }
    if chars.iter().any(|&c| !(c.is_ascii_alphanumeric() || SYMBOLS.contains(c))) { return Err("密码只能包含字母、数字和指定符号".into()); }
    if !(chars.iter().any(char::is_ascii_alphabetic) && chars.iter().any(char::is_ascii_digit)) { return Err("密码需同时包含字母和数字".into()); }
    Ok(())
}
pub fn map_verify(verify: &str) -> Result<&'static str, String> {
    match verify {
        "temporary" => Ok("use-temporary-password"),
        "permanent" => Ok("use-permanent-password"),
        "both" => Ok("use-both-passwords"),
        _ => Err("验证方式只能是 temporary|permanent|both".into()),
    }
}
/// 载荷文件 SDDL：仅当前用户、Administrators、SYSTEM 完全控制。
pub fn build_sddl(sid: &str) -> String {
    format!("D:P(A;;FA;;;{sid})(A;;FA;;;BA)(A;;FA;;;SY)")
}
pub fn build_helper_args(helper: &Path, payload: &Path) -> Result<String, String> {
    let (helper, payload) = (helper.to_string_lossy(), payload.to_string_lossy());
    if helper.contains('"') || payload.contains('"') { return Err("路径不能包含双引号".into()); }
    Ok(format!("-NoProfile -NonInteractive -ExecutionPolicy Bypass -File \"{helper}\" -InputFile \"{payload}\""))
}
/// 助手退出码 → 固定中文原因（不读 stderr）。
pub fn map_exit_code(code: i32) -> Result<(), String> {
    match code {
        0 => Ok(()),
        10 => Err("载荷无效或过期".into()),
        11 => Err("找不到 RustDesk".into()),
        12 => Err("RustDesk 拒绝修改".into()),
        13 => Err("已改密码但验证方式回读不一致".into()),
        other => Err(format!("助手失败（代码 {other}）")),
    }
}
fn toml_table(text: &str) -> Option<toml::Table> {
    (!text.trim().is_empty()).then(|| toml::from_str::<toml::Table>(text).ok()).flatten()
}
pub fn parse_verify_method(text: &str) -> String {
    let raw = toml_table(text).and_then(|d| d.get("options")?.get("verification-method")?.as_str().map(str::to_owned));
    match raw.unwrap_or_default().trim() {
        "use-permanent-password" => "permanent",
        "use-both-passwords" => "both",
        _ => "temporary",
    }.to_string()
}
fn config_dir() -> Option<PathBuf> {
    rustdesk::user_config_path()?.parent().map(Path::to_path_buf)
}
fn state_path(app: &tauri::AppHandle) -> Option<PathBuf> {
    use tauri::Manager;
    app.path().app_data_dir().ok().map(|dir| dir.join(STATE_FILE))
}
fn read_permanent_set(app: &tauri::AppHandle) -> bool {
    state_path(app)
        .and_then(|p| std::fs::read_to_string(p).ok())
        .and_then(|t| serde_json::from_str::<serde_json::Value>(&t).ok())
        .and_then(|v| v.get("permanent_set")?.as_bool())
        .unwrap_or(false)
}
pub(crate) fn write_pw_state(app: &tauri::AppHandle, permanent_set: bool) -> Result<(), String> {
    let path = state_path(app).ok_or_else(|| "取应用数据目录失败".to_string())?;
    if let Some(dir) = path.parent() { std::fs::create_dir_all(dir).map_err(|e| format!("创建状态目录失败：{e}"))?; }
    std::fs::write(&path, serde_json::json!({ "permanent_set": permanent_set }).to_string())
        .map_err(|e| format!("写入状态文件失败：{e}"))
}
fn now_unix() -> u64 {
    std::time::SystemTime::now().duration_since(std::time::UNIX_EPOCH).map(|d| d.as_secs()).unwrap_or(0)
}
fn build_payload(mode: &str, password: Option<&str>, verification: &str) -> String {
    let mut value = serde_json::json!({ "mode": mode, "verification": verification, "expires": now_unix() + PAYLOAD_TTL_SECS });
    if let Some(pw) = password { value["password"] = serde_json::Value::String(pw.to_string()); }
    value.to_string()
}
#[tauri::command]
pub async fn get_password_status(app: tauri::AppHandle) -> PasswordStatus {
    tauri::async_runtime::spawn_blocking(move || {
        let dir = config_dir().unwrap_or_default();
        PasswordStatus {
            has_permanent: read_permanent_set(&app),
            verify_method: std::fs::read_to_string(dir.join("RustDesk2.toml")).map(|t| parse_verify_method(&t)).unwrap_or_else(|_| "temporary".into()),
        }
    }).await.unwrap_or(PasswordStatus { has_permanent: false, verify_method: "temporary".into() })
}
#[tauri::command]
pub async fn set_permanent_password(password: String, verify: String, app: tauri::AppHandle) -> OpResult {
    let verification = match validate_password(&password).and_then(|()| map_verify(&verify)) {
        Ok(value) => value,
        Err(msg) => return OpResult::err(msg),
    };
    run_command(app, "set", Some(password), verification, "长期密码已设置", true).await
}
#[tauri::command]
pub async fn clear_permanent_password(app: tauri::AppHandle) -> OpResult {
    run_command(app, "clear", None, CLEAR_VERIFICATION, "长期密码已清除，验证方式已改回临时密码", false).await
}
async fn run_command(app: tauri::AppHandle, mode: &'static str, password: Option<String>, verification: &'static str, success: &'static str, state: bool) -> OpResult {
    match tauri::async_runtime::spawn_blocking(move || run_blocking(&app, mode, password.as_deref(), verification, success, state)).await {
        Ok(result) => result,
        Err(_) => OpResult::err("后台任务执行失败"),
    }
}
#[cfg(not(windows))]
fn run_blocking(_: &tauri::AppHandle, _: &str, _: Option<&str>, _: &str, _: &str, _: bool) -> OpResult {
    OpResult::err("仅支持 Windows")
}
#[cfg(windows)]
fn run_blocking(app: &tauri::AppHandle, mode: &str, password: Option<&str>, verification: &str, success: &str, state: bool) -> OpResult {
    let json = build_payload(mode, password, verification);
    let path = match payload_dir().and_then(|dir| create_payload_file(&dir, &json)) {
        Ok(path) => path,
        Err(msg) => return OpResult::err(msg),
    };
    spawn_watchdog(path.clone());
    let outcome = run_helper(app, &path);
    let leftover = std::fs::remove_file(&path).is_err();
    if let Err(mut msg) = outcome {
        if leftover { msg.push_str(&format!("；临时文件未能删除：{}", path.display())); }
        return OpResult::err(msg);
    }
    let mut message = success.to_string();
    if let Err(e) = write_pw_state(app, state) { message.push_str(&format!("；状态记录失败：{e}")); }
    if leftover { message.push_str(&format!("；临时文件未能删除：{}", path.display())); }
    OpResult::ok(message)
}
#[cfg(windows)]
fn payload_dir() -> Result<PathBuf, String> {
    let base = std::env::var_os("LOCALAPPDATA").map(PathBuf::from).ok_or_else(|| "取不到 %LOCALAPPDATA%".to_string())?;
    let dir = base.join("Vega").join("pw");
    std::fs::create_dir_all(&dir).map_err(|_| "创建临时目录失败".to_string())?;
    Ok(dir)
}
#[cfg(windows)]
fn wide(text: &str) -> Vec<u16> { text.encode_utf16().chain(std::iter::once(0)).collect() }
#[cfg(windows)]
fn random_hex32() -> String {
    use std::sync::atomic::{AtomicU64, Ordering};
    static SEQ: AtomicU64 = AtomicU64::new(0);
    let nanos = std::time::SystemTime::now().duration_since(std::time::UNIX_EPOCH).map(|d| d.as_nanos() as u64).unwrap_or(0);
    let mut state = nanos ^ ((std::process::id() as u64) << 32) ^ SEQ.fetch_add(1, Ordering::Relaxed).wrapping_mul(0x9E37_79B9_7F4A_7C15);
    state ^= &state as *const u64 as u64;
    let mut out = String::with_capacity(32);
    for _ in 0..2 {
        state ^= state << 13; state ^= state >> 7; state ^= state << 17;
        out.push_str(&format!("{state:016x}"));
    }
    out
}
#[cfg(windows)]
fn current_user_sid() -> Result<String, String> {
    use windows_sys::Win32::Foundation::{CloseHandle, LocalFree, HANDLE};
    use windows_sys::Win32::Security::Authorization::ConvertSidToStringSidW;
    use windows_sys::Win32::Security::{GetTokenInformation, OpenProcessToken, TokenUser, TOKEN_QUERY, TOKEN_USER};
    use windows_sys::Win32::System::Threading::GetCurrentProcess;
    let mut token: HANDLE = std::ptr::null_mut();
    // SAFETY: 令牌句柄由 API 写出，成功后才使用并关闭。
    if unsafe { OpenProcessToken(GetCurrentProcess(), TOKEN_QUERY, &mut token) } == 0 { return Err("无法获取当前进程令牌".into()); }
    let mut size = 0u32;
    unsafe { GetTokenInformation(token, TokenUser, std::ptr::null_mut(), 0, &mut size) };
    let mut buf = vec![0usize; (size.max(1) as usize).div_ceil(std::mem::size_of::<usize>())];
    let ok = unsafe { GetTokenInformation(token, TokenUser, buf.as_mut_ptr().cast(), size, &mut size) };
    unsafe { CloseHandle(token) };
    if ok == 0 { return Err("无法读取令牌用户".into()); }
    let user = unsafe { &*(buf.as_ptr() as *const TOKEN_USER) };
    let mut raw: *mut u16 = std::ptr::null_mut();
    if unsafe { ConvertSidToStringSidW(user.User.Sid, &mut raw) } == 0 { return Err("无法转换用户 SID".into()); }
    let mut len = 0usize;
    unsafe { while *raw.add(len) != 0 { len += 1; } }
    let sid = String::from_utf16_lossy(unsafe { std::slice::from_raw_parts(raw, len) });
    unsafe { LocalFree(raw.cast()) };
    Ok(sid)
}
/// 带 DACL 一次性创建并写入载荷；任何失败都删除文件。
#[cfg(windows)]
fn create_payload_file(dir: &Path, json: &str) -> Result<PathBuf, String> {
    use windows_sys::Win32::Foundation::{CloseHandle, LocalFree, INVALID_HANDLE_VALUE};
    use windows_sys::Win32::Security::Authorization::{ConvertStringSecurityDescriptorToSecurityDescriptorW, SDDL_REVISION_1};
    use windows_sys::Win32::Security::SECURITY_ATTRIBUTES;
    use windows_sys::Win32::Storage::FileSystem::{CreateFileW, WriteFile, CREATE_NEW, FILE_ATTRIBUTE_NORMAL, GENERIC_WRITE};
    let sddl = wide(&build_sddl(&current_user_sid()?));
    let path = dir.join(format!("vega-pw-{}.json", random_hex32()));
    let path_w = wide(&path.to_string_lossy());
    let mut descriptor: *mut core::ffi::c_void = std::ptr::null_mut();
    // SAFETY: SDDL 以 NUL 结尾；descriptor 由系统分配，用完 LocalFree。
    unsafe {
        if ConvertStringSecurityDescriptorToSecurityDescriptorW(sddl.as_ptr(), SDDL_REVISION_1, &mut descriptor, std::ptr::null_mut()) == 0 {
            return Err("无法构造文件安全描述符".into());
        }
        let attrs = SECURITY_ATTRIBUTES { nLength: std::mem::size_of::<SECURITY_ATTRIBUTES>() as u32, lpSecurityDescriptor: descriptor, bInheritHandle: 0 };
        let handle = CreateFileW(path_w.as_ptr(), GENERIC_WRITE, 0, &attrs, CREATE_NEW, FILE_ATTRIBUTE_NORMAL, std::ptr::null_mut());
        LocalFree(descriptor);
        if handle == INVALID_HANDLE_VALUE { return Err("创建临时文件失败".into()); }
        let mut written = 0u32;
        let ok = WriteFile(handle, json.as_ptr(), json.len() as u32, &mut written, std::ptr::null_mut());
        CloseHandle(handle);
        if ok == 0 || written as usize != json.len() {
            let _ = std::fs::remove_file(&path);
            return Err("写入临时文件失败".into());
        }
    }
    Ok(path)
}
#[cfg(windows)]
fn spawn_watchdog(path: PathBuf) {
    std::thread::spawn(move || { std::thread::sleep(Duration::from_secs(PAYLOAD_TTL_SECS)); let _ = std::fs::remove_file(&path); });
}
#[cfg(windows)]
fn installed_helper(app: &tauri::AppHandle) -> Option<PathBuf> {
    use tauri::Manager;
    app.path().resource_dir().ok().map(|dir| dir.join("resources").join(HELPER_SCRIPT)).filter(|p| p.is_file())
}
#[cfg(all(windows, not(debug_assertions)))]
fn helper_script(app: &tauri::AppHandle) -> Option<PathBuf> { installed_helper(app) }
#[cfg(all(windows, debug_assertions))]
fn helper_script(app: &tauri::AppHandle) -> Option<PathBuf> {
    installed_helper(app).or_else(|| {
        let dev = PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("resources").join(HELPER_SCRIPT);
        dev.is_file().then_some(dev)
    })
}
#[cfg(windows)]
fn powershell_path() -> Option<PathBuf> {
    use windows_sys::Win32::System::SystemInformation::GetSystemDirectoryW;
    let mut buffer = [0u16; 260];
    // SAFETY: 缓冲区按元素个数传入，返回值落在范围内才读。
    let len = unsafe { GetSystemDirectoryW(buffer.as_mut_ptr(), buffer.len() as u32) };
    if len == 0 || len as usize >= buffer.len() { return None; }
    Some(PathBuf::from(String::from_utf16_lossy(&buffer[..len as usize])).join("WindowsPowerShell").join("v1.0").join("powershell.exe"))
}
/// `ShellExecuteExW(runas)` 拉起助手并等待退出码。
#[cfg(windows)]
fn run_helper(app: &tauri::AppHandle, payload: &Path) -> Result<(), String> {
    use windows_sys::Win32::Foundation::{CloseHandle, GetLastError};
    use windows_sys::Win32::System::Threading::{GetExitCodeProcess, WaitForSingleObject};
    use windows_sys::Win32::UI::Shell::{ShellExecuteExW, SEE_MASK_NOCLOSEPROCESS, SHELLEXECUTEINFOW};
    let helper = helper_script(app).ok_or_else(|| "找不到提权助手 vega-pwhelper.ps1".to_string())?;
    let powershell = powershell_path().ok_or_else(|| "找不到系统 PowerShell".to_string())?;
    let args = build_helper_args(&helper, payload)?;
    let (file_w, verb_w, args_w) = (wide(&powershell.to_string_lossy()), wide("runas"), wide(&args));
    let mut info: SHELLEXECUTEINFOW = unsafe { std::mem::zeroed() };
    info.cbSize = std::mem::size_of::<SHELLEXECUTEINFOW>() as u32;
    info.fMask = SEE_MASK_NOCLOSEPROCESS;
    info.lpVerb = verb_w.as_ptr();
    info.lpFile = file_w.as_ptr();
    info.lpParameters = args_w.as_ptr();
    info.nShow = SW_HIDE;
    // SAFETY: info 已置零并填好 cbSize/字符串指针；进程句柄在成功后关闭。
    if unsafe { ShellExecuteExW(&mut info) } == 0 {
        let code = unsafe { GetLastError() };
        return Err(if code == ERROR_CANCELLED { "已取消".into() } else { format!("无法启动提权助手（错误码 {code}）") });
    }
    let waited = unsafe { WaitForSingleObject(info.hProcess, HELPER_TIMEOUT_MS) };
    let mut code = 0u32;
    let got = unsafe { GetExitCodeProcess(info.hProcess, &mut code) };
    unsafe { CloseHandle(info.hProcess) };
    if waited == WAIT_TIMEOUT { return Err("提权助手超时未完成".into()); }
    if got == 0 { return Err("无法读取提权助手退出码".into()); }
    map_exit_code(code as i32)
}
#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn password_rules() {
        assert!(validate_password("abcd1234").is_ok() && validate_password(&"a1".repeat(32)).is_ok());
        for bad in ["abc1234", "abcdefgh", "12345678", "abcd 1234", "abcd\"1234", "abcd\\1234", "abcd`1234", "abcd1234密码", "abcd'1234", "abcd\t1234"] {
            assert!(validate_password(bad).is_err(), "{bad:?}");
        }
        assert!(validate_password(&"a1".repeat(33)).is_err());
        assert!(!validate_password("short1").unwrap_err().contains("short1"));
    }
    #[test]
    fn sddl_body() {
        assert_eq!(build_sddl("S-1-5-21-1-2-3-1001"), "D:P(A;;FA;;;S-1-5-21-1-2-3-1001)(A;;FA;;;BA)(A;;FA;;;SY)");
    }
    #[test]
    fn helper_arguments() {
        let got = build_helper_args(Path::new(r"C:\h.ps1"), Path::new(r"C:\p.json")).unwrap();
        assert_eq!(got, "-NoProfile -NonInteractive -ExecutionPolicy Bypass -File \"C:\\h.ps1\" -InputFile \"C:\\p.json\"");
        assert!(build_helper_args(Path::new("C:\\a\"b.ps1"), Path::new(r"C:\p.json")).is_err());
        assert!(build_helper_args(Path::new(r"C:\h.ps1"), Path::new("C:\\a\"b.json")).is_err());
    }
    #[test]
    fn exit_codes() {
        assert!(map_exit_code(0).is_ok());
        assert_eq!(map_exit_code(10).unwrap_err(), "载荷无效或过期");
        assert_eq!(map_exit_code(11).unwrap_err(), "找不到 RustDesk");
        assert_eq!(map_exit_code(12).unwrap_err(), "RustDesk 拒绝修改");
        assert_eq!(map_exit_code(13).unwrap_err(), "已改密码但验证方式回读不一致");
        assert_eq!(map_exit_code(7).unwrap_err(), "助手失败（代码 7）");
    }
    #[test]
    fn verify_mapping_and_parse() {
        for (given, want) in [("temporary", "use-temporary-password"), ("permanent", "use-permanent-password"), ("both", "use-both-passwords")] {
            assert_eq!(map_verify(given).unwrap(), want);
        }
        assert!(map_verify("use-both-passwords").is_err() && map_verify("").is_err());
    }
}
