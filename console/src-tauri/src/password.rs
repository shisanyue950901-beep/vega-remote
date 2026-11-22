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
/// `RPC_E_CHANGED_MODE`（0x80010106）：线程已用别的模型初始化 COM，此时不再 CoUninitialize。
const RPC_E_CHANGED_MODE: i32 = 0x8001_0106u32 as i32;
/// 句柄/等待相关常量：与 `Win32::System::Threading` 的定义一致，此处本地定义以免误导入。
const WAIT_OBJECT_0: u32 = 0;
const WAIT_TIMEOUT: u32 = 258;
const WAIT_FAILED: u32 = 0xFFFF_FFFF;
/// 卷标志 `FILE_PERSISTENT_ACLS`（支持按文件设置 DACL）。
const FILE_PERSISTENT_ACLS: u32 = 0x0000_0008;
/// `FILE_READ_ATTRIBUTES`：`GetVolumeInformationByHandleW` 要求句柄带此权限。
const FILE_READ_ATTRIBUTES: u32 = 0x0000_0080;
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
        13 => Err("长期密码已更新，但验证方式未能确认，请在 RustDesk 中检查".into()),
        14 => Err("RustDesk 无响应，结果未知".into()),
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
    // 删除失败只在真错误时提起；NotFound 已在 remove_if_exists 里当成成功。
    let leftover = remove_if_exists(&path).err();
    if let Err(mut msg) = outcome {
        if let Some(err) = leftover { msg.push_str(&format!("；临时文件未能删除（{err}）：{}", path.display())); }
        return OpResult::err(msg);
    }
    let mut message = success.to_string();
    if let Err(e) = write_pw_state(app, state) { message.push_str(&format!("；状态记录失败：{e}")); }
    if let Some(err) = leftover { message.push_str(&format!("；临时文件未能删除（{err}）：{}", path.display())); }
    OpResult::ok(message)
}
#[cfg(windows)]
fn payload_dir() -> Result<PathBuf, String> {
    let base = std::env::var_os("LOCALAPPDATA").map(PathBuf::from).ok_or_else(|| "取不到 %LOCALAPPDATA%".to_string())?;
    let dir = base.join("Vega").join("pw");
    std::fs::create_dir_all(&dir).map_err(|_| "创建临时目录失败".to_string())?;
    Ok(dir)
}
/// 字符串转 NUL 结尾宽串（`OsStrExt::encode_wide`，不经过 UTF-8 假设）。
#[cfg(windows)]
fn wide(text: &str) -> Vec<u16> {
    use std::os::windows::ffi::OsStrExt;
    std::ffi::OsStr::new(text).encode_wide().chain(std::iter::once(0)).collect()
}
/// 路径转 NUL 结尾宽串；用 `as_os_str()` 逐码元转换，避免 `to_string_lossy` 改写非法码点。
#[cfg(windows)]
fn wide_path(path: &Path) -> Vec<u16> {
    use std::os::windows::ffi::OsStrExt;
    path.as_os_str().encode_wide().chain(std::iter::once(0)).collect()
}
/// 删除文件：`NotFound` 视为已删除成功，其余错误才返回原因。
#[cfg_attr(not(windows), allow(dead_code))]
fn remove_if_exists(path: &Path) -> Result<(), String> {
    match std::fs::remove_file(path) {
        Ok(()) => Ok(()),
        Err(err) if err.kind() == std::io::ErrorKind::NotFound => Ok(()),
        Err(err) => Err(err.to_string()),
    }
}
/// 去掉 `\\?\` 扩展路径前缀（`\\?\UNC\srv\share` 还原成 `\\srv\share`）。
/// `canonicalize` 在 Windows 上返回的正是带前缀的形式，PowerShell 的 `-File` 与路径比较都用去掉后的。
#[cfg_attr(not(windows), allow(dead_code))]
fn strip_extended_prefix(path: &Path) -> PathBuf {
    let text = path.to_string_lossy();
    if let Some(rest) = text.strip_prefix(r"\\?\UNC\") {
        return PathBuf::from(format!(r"\\{rest}"));
    }
    match text.strip_prefix(r"\\?\") {
        Some(rest) => PathBuf::from(rest),
        None => path.to_path_buf(),
    }
}
/// 纯函数：规范化后的助手路径是否落在任一受信任根内。返回去掉 `\\?\` 的最终路径。
/// 根与路径都先去前缀再比较，避免 `\\?\C:\Program Files` 与 `c:\program files` 因形式不同而漏判。
#[cfg_attr(not(windows), allow(dead_code))]
fn trusted_helper_path(canonical: &Path, roots: &[PathBuf]) -> Option<PathBuf> {
    let final_path = strip_extended_prefix(canonical);
    roots
        .iter()
        .map(|root| strip_extended_prefix(root))
        .any(|root| under_root(&final_path, &root))
        .then_some(final_path)
}
/// `path` 是否落在 `root` 目录内（Windows 路径按 ASCII 忽略大小写比较）。
#[cfg_attr(not(windows), allow(dead_code))]
fn under_root(path: &Path, root: &Path) -> bool {
    fn norm(path: &Path) -> String {
        path.to_string_lossy().trim_end_matches(['\\', '/']).to_ascii_lowercase()
    }
    let (path, root) = (norm(path), norm(root));
    !root.is_empty() && (path == root || path.starts_with(&format!("{root}\\")))
}
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
    // OpenProcessToken / GetCurrentProcess 在 System::Threading；LocalFree 在 Foundation；
    // ConvertSidToStringSidW 在 Security::Authorization；GetTokenInformation 在 Security。
    use windows_sys::Win32::Foundation::{CloseHandle, LocalFree, HANDLE};
    use windows_sys::Win32::Security::Authorization::ConvertSidToStringSidW;
    use windows_sys::Win32::Security::{GetTokenInformation, TokenUser, TOKEN_QUERY, TOKEN_USER};
    use windows_sys::Win32::System::Threading::{GetCurrentProcess, OpenProcessToken};

    let mut token: HANDLE = std::ptr::null_mut();
    // SAFETY: 令牌句柄由 API 写出，成功后才使用并关闭。
    if unsafe { OpenProcessToken(GetCurrentProcess(), TOKEN_QUERY, &mut token) } == 0 {
        return Err("无法获取当前进程令牌".into());
    }
    let mut size = 0u32;
    // 第一轮只为拿所需长度；返回 0 是预期结果。
    unsafe { GetTokenInformation(token, TokenUser, std::ptr::null_mut(), 0, &mut size) };
    if (size as usize) < std::mem::size_of::<TOKEN_USER>() {
        unsafe { CloseHandle(token) };
        return Err("无法读取令牌用户".into());
    }
    // 用 Vec<u64> 保证 8 字节对齐，容得下 TOKEN_USER（内含指针）。
    let words = (size as usize).div_ceil(std::mem::size_of::<u64>());
    let mut buf = vec![0u64; words.max(1)];
    let ok = unsafe { GetTokenInformation(token, TokenUser, buf.as_mut_ptr().cast(), size, &mut size) };
    unsafe { CloseHandle(token) };
    if ok == 0 {
        return Err("无法读取令牌用户".into());
    }
    let user = unsafe { &*(buf.as_ptr() as *const TOKEN_USER) };
    let mut raw: *mut u16 = std::ptr::null_mut();
    if unsafe { ConvertSidToStringSidW(user.User.Sid, &mut raw) } == 0 {
        return Err("无法转换用户 SID".into());
    }
    let mut len = 0usize;
    unsafe { while *raw.add(len) != 0 { len += 1; } }
    let sid = String::from_utf16_lossy(unsafe { std::slice::from_raw_parts(raw, len) });
    unsafe { LocalFree(raw.cast()) };
    Ok(sid)
}
/// 带 DACL 一次性创建并写入载荷；任何失败都删除文件。
///
/// 写入前先用 `GetVolumeInformationByHandleW` 确认卷带 `FILE_PERSISTENT_ACLS`：
/// FAT/exFAT 之类不支持按文件 DACL 的卷上，文件权限等于没设，直接拒绝。
#[cfg(windows)]
fn create_payload_file(dir: &Path, json: &str) -> Result<PathBuf, String> {
    // GENERIC_WRITE 在 Foundation；CreateFileW/WriteFile/GetVolumeInformationByHandleW 在
    // Storage::FileSystem（WriteFile 另需 feature Win32_System_IO）；LocalFree 在 Foundation。
    use windows_sys::Win32::Foundation::{CloseHandle, LocalFree, GENERIC_WRITE, INVALID_HANDLE_VALUE};
    use windows_sys::Win32::Security::Authorization::{
        ConvertStringSecurityDescriptorToSecurityDescriptorW, SDDL_REVISION_1,
    };
    use windows_sys::Win32::Security::SECURITY_ATTRIBUTES;
    use windows_sys::Win32::Storage::FileSystem::{
        CreateFileW, GetVolumeInformationByHandleW, WriteFile, CREATE_NEW, FILE_ATTRIBUTE_NORMAL,
    };

    let sddl = wide(&build_sddl(&current_user_sid()?));
    let path = dir.join(format!("vega-pw-{}.json", random_hex32()));
    let path_w = wide_path(&path);
    let mut descriptor: *mut core::ffi::c_void = std::ptr::null_mut();
    // SAFETY: SDDL 以 NUL 结尾；descriptor 由系统分配，用完 LocalFree。
    unsafe {
        if ConvertStringSecurityDescriptorToSecurityDescriptorW(
            sddl.as_ptr(),
            SDDL_REVISION_1,
            &mut descriptor,
            std::ptr::null_mut(),
        ) == 0
        {
            return Err("无法构造文件安全描述符".into());
        }
        let attrs = SECURITY_ATTRIBUTES {
            nLength: std::mem::size_of::<SECURITY_ATTRIBUTES>() as u32,
            lpSecurityDescriptor: descriptor,
            bInheritHandle: 0,
        };
        // FILE_READ_ATTRIBUTES 供随后的卷查询使用；DACL 给了 FA，包含该权限。
        let handle = CreateFileW(
            path_w.as_ptr(),
            GENERIC_WRITE | FILE_READ_ATTRIBUTES,
            0,
            &attrs,
            CREATE_NEW,
            FILE_ATTRIBUTE_NORMAL,
            std::ptr::null_mut(),
        );
        LocalFree(descriptor);
        if handle == INVALID_HANDLE_VALUE {
            return Err("创建临时文件失败".into());
        }
        let mut flags = 0u32;
        let (mut serial, mut max_component) = (0u32, 0u32);
        let volume = GetVolumeInformationByHandleW(
            handle,
            std::ptr::null_mut(),
            0,
            &mut serial,
            &mut max_component,
            &mut flags,
            std::ptr::null_mut(),
            0,
        );
        if volume == 0 || flags & FILE_PERSISTENT_ACLS == 0 {
            CloseHandle(handle);
            let _ = remove_if_exists(&path);
            return Err(if volume == 0 {
                "无法读取临时文件所在磁盘的属性".into()
            } else {
                "临时文件所在磁盘不支持权限控制".into()
            });
        }
        let mut written = 0u32;
        let ok = WriteFile(
            handle,
            json.as_ptr().cast(),
            json.len() as u32,
            &mut written,
            std::ptr::null_mut(),
        );
        CloseHandle(handle);
        if ok == 0 || written as usize != json.len() {
            let _ = remove_if_exists(&path);
            return Err("写入临时文件失败".into());
        }
    }
    Ok(path)
}
/// 看门狗：TTL 到点后删掉载荷。删除失败不再静默吞掉，也不向上报假失败
/// （项目未引入 log，故仅忽略错误码）。
#[cfg(windows)]
fn spawn_watchdog(path: PathBuf) {
    std::thread::spawn(move || {
        std::thread::sleep(Duration::from_secs(PAYLOAD_TTL_SECS));
        if remove_if_exists(&path).is_err() {
            // 无 log crate：不打印路径（避免泄露），也不回报失败给前端。
        }
    });
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
/// 发行版必须把助手装在受保护目录（系统 `Program Files`）内：
/// 否则同用户进程可以改写这个 PowerShell 脚本，提权即被劫持。
/// 根目录取自 `winpaths::program_files_dirs()`（已知文件夹 + 系统卷校验），不读可被启动环境改写的环境变量。
/// 返回规范化并去掉 `\\?\` 的最终路径，交给 `-File` 使用。
#[cfg(all(windows, not(debug_assertions)))]
fn ensure_helper_location(helper: &Path) -> Result<PathBuf, String> {
    let canonical = std::fs::canonicalize(helper).map_err(|_| "无法定位提权助手".to_string())?;
    let roots = crate::winpaths::program_files_dirs();
    if roots.is_empty() {
        return Err("无法确定系统 Program Files 目录，无法设置长期密码".into());
    }
    trusted_helper_path(&canonical, &roots)
        .ok_or_else(|| "Vega 未安装在受保护目录，无法设置长期密码".into())
}
#[cfg(all(windows, debug_assertions))]
fn ensure_helper_location(helper: &Path) -> Result<PathBuf, String> { Ok(strip_extended_prefix(helper)) }
/// `%SystemRoot%\System32`（`GetSystemDirectoryW`）。
#[cfg(windows)]
fn system32_dir() -> Option<PathBuf> {
    use windows_sys::Win32::System::SystemInformation::GetSystemDirectoryW;

    let mut buffer = [0u16; 260];
    // SAFETY: 缓冲区按元素个数传入，返回值落在范围内才读。
    let len = unsafe { GetSystemDirectoryW(buffer.as_mut_ptr(), buffer.len() as u32) };
    if len == 0 || len as usize >= buffer.len() { return None; }
    Some(PathBuf::from(String::from_utf16_lossy(&buffer[..len as usize])))
}
#[cfg(windows)]
fn powershell_path() -> Option<PathBuf> {
    system32_dir().map(|dir| dir.join("WindowsPowerShell").join("v1.0").join("powershell.exe"))
}
/// `ShellExecuteExW(runas)` 拉起助手并等待退出码。
#[cfg(windows)]
fn run_helper(app: &tauri::AppHandle, payload: &Path) -> Result<(), String> {
    use windows_sys::Win32::Foundation::{CloseHandle, GetLastError};
    use windows_sys::Win32::System::Com::{
        CoInitializeEx, CoUninitialize, COINIT_APARTMENTTHREADED, COINIT_DISABLE_OLE1DDE,
    };
    use windows_sys::Win32::System::Threading::{GetExitCodeProcess, WaitForSingleObject};
    use windows_sys::Win32::UI::Shell::{
        ShellExecuteExW, SEE_MASK_NOCLOSEPROCESS, SEE_MASK_NOASYNC, SHELLEXECUTEINFOW,
    };

    let helper = helper_script(app).ok_or_else(|| "找不到提权助手 vega-pwhelper.ps1".to_string())?;
    let helper = ensure_helper_location(&helper)?;
    let system32 = system32_dir().ok_or_else(|| "找不到 System32 目录".to_string())?;
    let powershell = powershell_path().ok_or_else(|| "找不到系统 PowerShell".to_string())?;
    let args = build_helper_args(&helper, payload)?;
    let (file_w, dir_w, verb_w, args_w) = (
        wide_path(&powershell),
        wide_path(&system32),
        wide("runas"),
        wide(&args),
    );
    // ShellExecuteExW 要求调用线程已初始化 COM；S_FALSE(1) 也算成功，只需配对 CoUninitialize。
    let hr = unsafe {
        CoInitializeEx(
            std::ptr::null_mut(),
            (COINIT_APARTMENTTHREADED | COINIT_DISABLE_OLE1DDE) as u32,
        )
    };
    // 初始化失败且不是「本线程已是别的套间」时直接返回：没有 COM 就不能调 ShellExecuteExW。
    // RPC_E_CHANGED_MODE 不增加引用计数，也不需要 CoUninitialize。
    if hr < 0 && hr != RPC_E_CHANGED_MODE {
        return Err(format!("无法初始化 COM（错误码 0x{:08X}）", hr as u32));
    }
    let com_ready = hr >= 0;

    let mut info: SHELLEXECUTEINFOW = unsafe { std::mem::zeroed() };
    info.cbSize = std::mem::size_of::<SHELLEXECUTEINFOW>() as u32;
    // SEE_MASK_NOASYNC：调用返回后仍持有 lpFile/lpParameters 指向的缓冲区（缓冲区还在栈上）。
    info.fMask = SEE_MASK_NOCLOSEPROCESS | SEE_MASK_NOASYNC;
    info.lpVerb = verb_w.as_ptr();
    info.lpFile = file_w.as_ptr();
    info.lpParameters = args_w.as_ptr();
    info.lpDirectory = dir_w.as_ptr();
    info.nShow = SW_HIDE;
    // SAFETY: info 已置零并填好 cbSize/字符串指针；进程句柄在成功后关闭。
    if unsafe { ShellExecuteExW(&mut info) } == 0 {
        let code = unsafe { GetLastError() };
        if com_ready { unsafe { CoUninitialize() } }
        return Err(if code == ERROR_CANCELLED { "已取消".into() } else { format!("无法启动提权助手（错误码 {code}）") });
    }
    if info.hProcess.is_null() {
        if com_ready { unsafe { CoUninitialize() } }
        return Err("提权助手未返回进程句柄".into());
    }
    let waited = unsafe { WaitForSingleObject(info.hProcess, HELPER_TIMEOUT_MS) };
    let result = match waited {
        WAIT_OBJECT_0 => {
            let mut code = 0u32;
            if unsafe { GetExitCodeProcess(info.hProcess, &mut code) } == 0 {
                Err("无法读取提权助手退出码".to_string())
            } else {
                map_exit_code(code as i32)
            }
        }
        WAIT_TIMEOUT => Err("操作超时，结果未知，请稍后查看状态".to_string()),
        WAIT_FAILED => {
            let code = unsafe { GetLastError() };
            Err(format!("等待提权助手失败（错误码 {code}）"))
        }
        other => Err(format!("等待提权助手返回未知状态（{other}）")),
    };
    unsafe { CloseHandle(info.hProcess) };
    if com_ready { unsafe { CoUninitialize() } }
    result
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
        assert_eq!(map_exit_code(13).unwrap_err(), "长期密码已更新，但验证方式未能确认，请在 RustDesk 中检查");
        assert_eq!(map_exit_code(14).unwrap_err(), "RustDesk 无响应，结果未知");
        assert_eq!(map_exit_code(7).unwrap_err(), "助手失败（代码 7）");
    }
    #[test]
    fn verify_mapping_and_parse() {
        for (given, want) in [("temporary", "use-temporary-password"), ("permanent", "use-permanent-password"), ("both", "use-both-passwords")] {
            assert_eq!(map_verify(given).unwrap(), want);
        }
        assert!(map_verify("use-both-passwords").is_err() && map_verify("").is_err());
    }
    #[test]
    fn trusted_helper_path_strips_verbatim_and_checks_prefix() {
        let roots = vec![PathBuf::from(r"C:\Program Files"), PathBuf::from(r"\\?\C:\Program Files (x86)")];
        let cases = [
            (r"\\?\C:\Program Files\Vega\resources\vega-pwhelper.ps1", Some(r"C:\Program Files\Vega\resources\vega-pwhelper.ps1")),
            (r"\\?\c:\program files\vega\resources\vega-pwhelper.ps1", Some(r"c:\program files\vega\resources\vega-pwhelper.ps1")),
            (r"\\?\C:\Program Files (x86)\Vega\h.ps1", Some(r"C:\Program Files (x86)\Vega\h.ps1")),
        ];
        for (given, want) in cases {
            assert_eq!(trusted_helper_path(Path::new(given), &roots), want.map(PathBuf::from), "{given}");
        }
        // 前缀必须按目录边界：`C:\Program Files Evil\` 不能冒充 `C:\Program Files\`。
        for bad in [
            r"\\?\C:\Program Files Evil\h.ps1",
            r"C:\Program FilesEvil\h.ps1",
            r"\\?\C:\Users\me\Program Files\Vega\h.ps1",
            r"\\?\C:\Program FilesX\Vega\h.ps1",
        ] {
            assert_eq!(trusted_helper_path(Path::new(bad), &roots), None, "{bad}");
        }
        assert_eq!(trusted_helper_path(Path::new(r"C:\Program Files\Vega\h.ps1"), &[]), None);
        assert_eq!(trusted_helper_path(Path::new(r"\\?\C:\Program Files"), &roots), Some(PathBuf::from(r"C:\Program Files")));
    }
    #[test]
    fn strip_extended_prefix_handles_verbatim_forms() {
        assert_eq!(strip_extended_prefix(Path::new(r"\\?\C:\Vega\h.ps1")), PathBuf::from(r"C:\Vega\h.ps1"));
        assert_eq!(strip_extended_prefix(Path::new(r"\\?\UNC\srv\share\h.ps1")), PathBuf::from(r"\\srv\share\h.ps1"));
        assert_eq!(strip_extended_prefix(Path::new(r"C:\Vega\h.ps1")), PathBuf::from(r"C:\Vega\h.ps1"));
    }
    #[test]
    fn under_root_is_case_insensitive_and_boundary_aware() {
        let root = Path::new(r"C:\Program Files\Vega");
        assert!(under_root(Path::new(r"C:\Program Files\Vega\resources\vega-pwhelper.ps1"), root));
        assert!(under_root(Path::new(r"c:\program files\vega\resources\h.ps1"), root));
        assert!(under_root(Path::new(r"C:\Program Files\Vega"), root));
        assert!(under_root(Path::new(r"C:\Program Files\Vega\"), root));
        assert!(!under_root(Path::new(r"C:\Program Files\Vega-evil\h.ps1"), root));
        assert!(!under_root(Path::new(r"C:\Users\me\Vega\resources\h.ps1"), root));
        assert!(!under_root(Path::new(r"C:\h.ps1"), root));
        assert!(!under_root(Path::new(r"C:\Program Files\Vega\x"), Path::new("")));
    }
    #[test]
    fn remove_missing_file_counts_as_success() {
        let dir = std::env::temp_dir().join(format!("vega-pw-test-{}", std::process::id()));
        std::fs::create_dir_all(&dir).unwrap();
        let file = dir.join("payload.json");
        std::fs::write(&file, "{}").unwrap();
        assert!(remove_if_exists(&file).is_ok());
        assert!(!file.exists());
        // 已不存在（NotFound）也算成功。
        assert!(remove_if_exists(&file).is_ok());
        let _ = std::fs::remove_dir_all(&dir);
    }
}
