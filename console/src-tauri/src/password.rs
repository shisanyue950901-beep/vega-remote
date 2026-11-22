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
/// 发行版只接受一种安装目录形状，返回规范化并去掉 `\\?\` 的助手路径交给 `-File` 使用：
///   * `<X>:\Vega`（任意盘根的直接子目录），或
///   * `<ProgramFiles>\Vega`，根目录取自 `winpaths::program_files_dirs()`
///     （已知文件夹 + 系统卷校验，不读可被启动环境改写的环境变量）。
///
/// 位置对了不等于安全：`Program Files` 下被手工建出来的目录完全可以带宽松 ACL，
/// 所以不再有「前缀命中就直接放行」的快路径，一律走完整校验：
///   1. 安装目录形状必须是上面两条之一；
///   2. exe、exe_dir、resources、助手文件四段原始路径都不是重解析点，
///      且 `canonicalize` 结果与原始路径一致（校验途中不能被链接换走）；
///   3. exe_dir 的每一级祖先（直到盘根，含 `Program Files` 根）所有者必须是
///      SYSTEM / Administrators / TrustedInstaller，且不能把删除子项、改写 ACL、
///      改所有者、完全控制授予其他主体（建子目录/建文件允许）；
///   4. exe_dir、resources、助手文件三层的所有者与 DACL 只允许上面三个主体写入。
/// 任何一条不满足都返回固定文案 `INSECURE_INSTALL_DIR`，前端直接显示。
#[cfg(all(windows, not(debug_assertions)))]
fn ensure_helper_location(helper: &Path) -> Result<PathBuf, String> {
    validate_helper_location(helper).ok_or_else(|| INSECURE_INSTALL_DIR.to_string())
}

/// 完整校验一次助手位置；通过时返回去掉 `\\?\` 的助手路径。
/// 发版路径里每次拉起提权助手前都要跑一遍（`run_helper` 在 `ShellExecuteExW` 紧前面再跑一次）。
#[cfg(all(windows, not(debug_assertions)))]
fn validate_helper_location(helper: &Path) -> Option<PathBuf> {
    let exe = std::env::current_exe().ok()?;
    let raw_exe_dir = exe.parent()?.to_path_buf();
    let raw_resources = raw_exe_dir.join("resources");
    // 1. 位置规则：`<X>:\Vega` 或 `<ProgramFiles>\Vega`。
    if !allowed_install_dir(&raw_exe_dir, &crate::winpaths::program_files_dirs()) {
        return None;
    }
    // 2. 先按未规范化的原始路径验重解析点，再要求 canonicalize 结果与原始路径一致。
    for raw in [exe.as_path(), raw_exe_dir.as_path(), raw_resources.as_path(), helper] {
        if !raw_matches_canonical(raw) {
            return None;
        }
    }
    // 3. 祖先链：exe_dir 的每一级父目录直到盘根，都不能把控制权交给非管理员。
    for ancestor in ancestor_chain(&raw_exe_dir) {
        if !path_ancestor_admin_only_control(&ancestor) {
            return None;
        }
    }
    // 4. 三层 DACL：安装目录、resources、助手文件；助手必须在 resources 里。
    let canonical_exe_dir = std::fs::canonicalize(&raw_exe_dir).ok()?;
    let canonical_resources = std::fs::canonicalize(&raw_resources).ok()?;
    let canonical_helper = std::fs::canonicalize(helper).ok()?;
    if !canonical_helper.is_file() {
        return None;
    }
    if !same_path(canonical_helper.parent()?, &canonical_resources) {
        return None;
    }
    if !path_acl_admin_only_write(&canonical_exe_dir)
        || !path_acl_admin_only_write(&canonical_resources)
        || !path_acl_admin_only_write(&canonical_helper)
    {
        return None;
    }
    Some(strip_extended_prefix(&canonical_helper))
}
#[cfg(all(windows, debug_assertions))]
fn ensure_helper_location(helper: &Path) -> Result<PathBuf, String> { Ok(strip_extended_prefix(helper)) }

// ---------------------------------------------------------------------------
// t6b：安装目录 ACL 校验
//
// t6 曾把安装目录固定成 Program Files，理由是长期密码助手
// `resources\vega-pwhelper.ps1` 必须放在普通用户不可写的目录里：提权助手会以
// runas 执行该脚本，脚本可写就等于把「管理员执行任意 PowerShell」交给任何本地用户。
// t6b 放开目录限制（用户可以装到 D:\Vega），改由安装器用 icacls 把目录 ACL 收紧成
// 「只有 SYSTEM / Administrators 可写」，控制台在每次提权前自己再验一遍：
//   * 安装目录只能是 `<X>:\Vega` 或 `<ProgramFiles>\Vega`（`Program Files` 根来自
//     `winpaths::program_files_dirs()`），更深或改名的目录不认；
//   * 不再有「在 Program Files 前缀下就跳过检查」的快路径：`Program Files` 里被手工
//     建出来、带宽松 ACL 的子目录一样危险，所以 `Program Files\Vega` 也必须过同一套校验；
//   * 助手必须在 `<exe_dir>\resources` 里，exe_dir 是当前控制台 exe 的真实目录；
//   * exe、exe_dir、exe_dir\resources、助手文件四段原始路径都不能是重解析点
//     （junction/symlink），且 canonicalize 之后必须与原始路径一致；
//   * exe_dir 的每一级祖先直到盘根（含 `Program Files` 根）都不能把删除子项、改写 ACL、
//     改所有者、完全控制授予非管理员主体，所有者本身也必须是受信任主体；
//   * exe_dir、exe_dir\resources、助手文件三者的所有者必须是 SYSTEM / Administrators /
//     TrustedInstaller；
//   * 三者的 DACL 里，凡是授予写权限的 allow ACE，被授权者只能是上面三个主体
//     （CREATOR OWNER 只允许出现在 INHERIT_ONLY 的继承 ACE 上，它不作用于对象本身）。
// 任何一条不满足都拒绝设置长期密码，并提示重新运行安装包修复。
// ---------------------------------------------------------------------------

/// 拒绝时给用户看的统一文案。
#[allow(dead_code)]
const INSECURE_INSTALL_DIR: &str =
    "Vega 安装目录权限不安全，无法设置长期密码。请重新运行安装包修复。";
/// 受信任的主体：本地系统、内置管理员组、TrustedInstaller。
const SID_LOCAL_SYSTEM: &str = "S-1-5-18";
const SID_ADMINISTRATORS: &str = "S-1-5-32-544";
const SID_TRUSTED_INSTALLER: &str =
    "S-1-5-80-956008885-3418522649-1831038044-1853292631-2271478464";
/// CREATOR OWNER：只有带 INHERIT_ONLY 的继承 ACE 才可放行。
const SID_CREATOR_OWNER: &str = "S-1-3-0";

/// `ACCESS_ALLOWED_ACE_TYPE`：只接受这种普通 allow ACE。
const ACE_TYPE_ACCESS_ALLOWED: u8 = 0x00;
/// `INHERIT_ONLY_ACE`：ACE 只作用于子对象，不作用于对象本身。
const ACE_FLAG_INHERIT_ONLY: u8 = 0x08;
/// 写类访问权限位（含泛化位）：出现在 allow ACE 里就必须是受信任主体。
const ACE_WRITE_BITS: u32 = 0x0000_0002 // FILE_WRITE_DATA / FILE_ADD_FILE
    | 0x0000_0004 // FILE_APPEND_DATA / FILE_ADD_SUBDIRECTORY
    | 0x0000_0010 // FILE_WRITE_EA
    | 0x0000_0100 // FILE_WRITE_ATTRIBUTES
    | 0x0000_0040 // FILE_DELETE_CHILD
    | 0x0001_0000 // DELETE
    | 0x0004_0000 // WRITE_DAC
    | 0x0008_0000 // WRITE_OWNER
    | 0x1000_0000 // GENERIC_ALL
    | 0x4000_0000; // GENERIC_WRITE
/// 祖先目录上「足以接管子项」的权限位：能删子项、能改 ACL、能改所有者、或直接完全控制。
/// `FILE_ADD_SUBDIRECTORY` / `FILE_ADD_FILE`（0x4 / 0x2）不在其中：往盘根建目录是正常用法。
const ACE_ANCESTOR_FORBIDDEN_BITS: u32 = 0x0001_0000 // DELETE
    | 0x0000_0040 // FILE_DELETE_CHILD
    | 0x0004_0000 // WRITE_DAC
    | 0x0008_0000 // WRITE_OWNER
    | 0x1000_0000 // GENERIC_ALL
    | 0x4000_0000; // GENERIC_WRITE

/// 一条 ACE：`(ace_type, ace_flags, access_mask, SID 字符串)`。
type AceRecord = (u8, u8, u32, String);

/// SID 是否属于受信任主体（SYSTEM / Administrators / TrustedInstaller）。
fn is_trusted_sid(sid: &str) -> bool {
    sid.eq_ignore_ascii_case(SID_LOCAL_SYSTEM)
        || sid.eq_ignore_ascii_case(SID_ADMINISTRATORS)
        || sid.eq_ignore_ascii_case(SID_TRUSTED_INSTALLER)
}

/// ACE 类型分类：`Some(true)` = allow，`Some(false)` = deny/audit（不影响判定），
/// `None` = 未知或无法确认授权对象的类型（一律拒绝）。
///
/// 只有普通 `ACCESS_ALLOWED_ACE_TYPE`（0x00）算 allow。`ACCESS_ALLOWED_COMPOUND_ACE_TYPE`
/// （0x04）以及 0x05/0x09/0x0B 等带对象或回调的 allow 类型，都无法用本文件的简单模型确认
/// 授权对象，直接判为不安全。只有 deny（0x01 及其对象/回调变体）和 audit/alarm
/// （0x02、0x03 及其对象/回调变体）可以跳过：它们不放行访问。
fn ace_class(ace_type: u8) -> Option<bool> {
    match ace_type {
        // ACCESS_ALLOWED_ACE_TYPE
        0x00 => Some(true),
        // ACCESS_DENIED_ACE_TYPE / SYSTEM_AUDIT_ACE_TYPE / SYSTEM_ALARM_ACE_TYPE，
        // 以及它们的 OBJECT / CALLBACK / CALLBACK_OBJECT 变体：不放行访问。
        0x01 | 0x02 | 0x03 | 0x06 | 0x07 | 0x08 | 0x0A | 0x0C | 0x0D | 0x0E | 0x0F | 0x10 => {
            Some(false)
        }
        // 0x04 ACCESS_ALLOWED_COMPOUND、0x05 / 0x09 / 0x0B 等 allow 变体，以及未知类型：拒绝。
        _ => None,
    }
}

/// 纯判定逻辑（可单测）：`owner` 是对象所有者 SID，`dacl` 是 DACL 里的 ACE 列表；
/// `None` 表示 DACL 为空（NULL DACL = 所有人完全控制）。
fn dacl_admin_only_write(owner: &str, dacl: Option<&[AceRecord]>) -> bool {
    if !is_trusted_sid(owner) {
        return false;
    }
    let Some(aces) = dacl else {
        return false;
    };
    for (ace_type, flags, mask, sid) in aces {
        match ace_class(*ace_type) {
            // 未知 ACE 类型：不能证明安全，拒绝。
            None => return false,
            Some(false) => continue,
            Some(true) => {}
        }
        // allow ACE 只接受普通 ACCESS_ALLOWED_ACE。
        if *ace_type != ACE_TYPE_ACCESS_ALLOWED {
            return false;
        }
        if mask & ACE_WRITE_BITS == 0 {
            continue; // 只读/执行权限谁都可以有。
        }
        if is_trusted_sid(sid) {
            continue;
        }
        // CREATOR OWNER 的继承 ACE 只作用于子对象，可以放行；作用于对象本身的不行。
        if sid.eq_ignore_ascii_case(SID_CREATOR_OWNER) && flags & ACE_FLAG_INHERIT_ONLY != 0 {
            continue;
        }
        return false;
    }
    true
}

/// 祖先目录判定（纯函数）：`owner` 是对象所有者 SID，`dacl` 是 DACL 里的 ACE 列表。
///
/// 祖先目录只需要「不给别人接管子项的能力」：所有者必须是受信任主体，allow ACE 里不得把
/// `DELETE` / `FILE_DELETE_CHILD` / `WRITE_DAC` / `WRITE_OWNER` / `GENERIC_ALL` /
/// `GENERIC_WRITE` 授予其他主体。`FILE_ADD_SUBDIRECTORY` / `FILE_ADD_FILE` 允许：
/// 盘根上给 `Authenticated Users` 建目录是 Windows 默认 ACL 的一部分。
/// `INHERIT_ONLY` 的 ACE 只作用于子对象，不影响本目录，因此跳过。
#[cfg_attr(not(windows), allow(dead_code))]
fn ancestor_admin_only_control(owner: &str, dacl: Option<&[AceRecord]>) -> bool {
    if !is_trusted_sid(owner) {
        return false;
    }
    let Some(aces) = dacl else {
        return false; // NULL DACL：所有人完全控制。
    };
    for (ace_type, flags, mask, sid) in aces {
        match ace_class(*ace_type) {
            None => return false,
            Some(false) => continue,
            Some(true) => {}
        }
        // allow ACE 只接受普通 ACCESS_ALLOWED_ACE。
        if *ace_type != ACE_TYPE_ACCESS_ALLOWED {
            return false;
        }
        if mask & ACE_ANCESTOR_FORBIDDEN_BITS == 0 {
            continue; // 只读/执行、建子目录、建文件都不足以接管。
        }
        if flags & ACE_FLAG_INHERIT_ONLY != 0 {
            continue; // 只作用于子对象，不作用于祖先目录本身。
        }
        if is_trusted_sid(sid) {
            continue;
        }
        return false;
    }
    true
}

/// `path` 是否就是盘根（`C:` / `C:\` / `\\?\C:\`），纯字符串判断，不依赖平台路径语法。
#[allow(dead_code)]
fn is_drive_root(path: &Path) -> bool {
    let text = strip_extended_prefix(path).to_string_lossy().replace('/', "\\");
    let trimmed = text.trim_end_matches('\\');
    let bytes = trimmed.as_bytes();
    bytes.len() == 2 && bytes[1] == b':' && bytes[0].is_ascii_alphabetic()
}

/// 安装目录形状（纯函数）：`exe_dir` 必须正好是 `<X>:\Vega`，或 `<ProgramFiles>\Vega`
/// 且 `ProgramFiles` 出现在 `program_files`（来自 `winpaths::program_files_dirs()`）里。
/// 前缀相同但更深或改了名的目录一律不认。
#[allow(dead_code)]
fn allowed_install_dir(exe_dir: &Path, program_files: &[PathBuf]) -> bool {
    let dir = strip_extended_prefix(exe_dir);
    let text = dir.to_string_lossy().replace('/', "\\");
    let text = text.trim_end_matches('\\');
    let Some((parent_text, name)) = text.rsplit_once('\\') else {
        return false;
    };
    if !name.eq_ignore_ascii_case("Vega") {
        return false;
    }
    let parent = PathBuf::from(parent_text);
    if is_drive_root(&parent) {
        return true;
    }
    program_files
        .iter()
        .any(|root| same_path(&parent, &strip_extended_prefix(root)))
}

/// 原始路径不是重解析点，并且 `canonicalize` 之后与原始路径一致（去前缀、忽略大小写）。
/// `winpaths::is_reparse_point` 在拿不到属性时也返回 true，因此这里不再单独处理
/// `INVALID_FILE_ATTRIBUTES`。
#[cfg(windows)]
#[allow(dead_code)]
fn raw_matches_canonical(raw: &Path) -> bool {
    if crate::winpaths::is_reparse_point(raw) {
        return false;
    }
    match std::fs::canonicalize(raw) {
        Ok(canonical) => {
            same_path(&strip_extended_prefix(&canonical), &strip_extended_prefix(raw))
        }
        Err(_) => false,
    }
}

/// `exe_dir` 的祖先链：父目录、祖父目录……直到盘根（含）。
#[cfg(windows)]
#[allow(dead_code)]
fn ancestor_chain(exe_dir: &Path) -> Vec<PathBuf> {
    let mut out = Vec::new();
    let mut current = exe_dir.parent();
    while let Some(path) = current {
        out.push(path.to_path_buf());
        current = path.parent();
    }
    out
}

/// 单个祖先目录的 ACL 是否「不能接管子项」。
#[cfg(windows)]
#[allow(dead_code)]
fn path_ancestor_admin_only_control(path: &Path) -> bool {
    if crate::winpaths::is_reparse_point(path) {
        return false;
    }
    match path_owner_and_dacl(path) {
        Some((owner, dacl)) => ancestor_admin_only_control(&owner, dacl.as_deref()),
        None => false,
    }
}

/// 两个路径是否指向同一目录（Windows 路径按 ASCII 忽略大小写，忽略 `\\?\` 前缀与尾部斜杠）。
#[cfg_attr(not(windows), allow(dead_code))]
fn same_path(a: &Path, b: &Path) -> bool {
    let (a, b) = (strip_extended_prefix(a), strip_extended_prefix(b));
    under_root(&a, &b) && under_root(&b, &a)
}

/// `ACL_SIZE_INFORMATION` 只用到 `AceCount`，其余字段保留占位，按 Win32 布局声明。
#[cfg(windows)]
#[repr(C)]
#[allow(dead_code)]
struct AclSizeInfo {
    ace_count: u32,
    acl_bytes_in_use: u32,
    acl_bytes_free: u32,
}

/// 直接声明 advapi32 的三个安全 API：只需要指针与原始字节，不依赖结构体字段名。
/// （GetNamedSecurityInfoW 在 advapi32 也导出；GetAce / GetAclInformation 同理。）
#[cfg(windows)]
#[allow(non_snake_case)]
#[link(name = "advapi32")]
extern "system" {
    fn GetNamedSecurityInfoW(
        object_name: *const u16,
        object_type: i32,
        security_info: u32,
        owner: *mut *mut core::ffi::c_void,
        group: *mut *mut core::ffi::c_void,
        dacl: *mut *mut core::ffi::c_void,
        sacl: *mut *mut core::ffi::c_void,
        sd: *mut *mut core::ffi::c_void,
    ) -> u32;
    fn GetAce(acl: *const core::ffi::c_void, index: u32, ace: *mut *mut core::ffi::c_void) -> i32;
    fn GetAclInformation(
        acl: *const core::ffi::c_void,
        info: *mut core::ffi::c_void,
        info_len: u32,
        info_class: i32,
    ) -> i32;
}

/// `SE_FILE_OBJECT`
#[cfg(windows)]
const SE_FILE_OBJECT: i32 = 1;
/// `OWNER_SECURITY_INFORMATION`
#[cfg(windows)]
const OWNER_SECURITY_INFORMATION: u32 = 0x0000_0001;
/// `DACL_SECURITY_INFORMATION`
#[cfg(windows)]
const DACL_SECURITY_INFORMATION: u32 = 0x0000_0004;
/// `AclSizeInformation`
#[cfg(windows)]
const ACL_SIZE_INFORMATION_CLASS: i32 = 2;
/// `ACE_HEADER` 固定 4 字节：AceType(1) + AceFlags(1) + AceSize(2)，之后是 Mask(4) 与 SID。
#[cfg(windows)]
const ACCESS_ALLOWED_ACE_SID_OFFSET: usize = 8;

/// 读取一个路径的所有者 SID 与 DACL(ACE 列表)；任何一步失败都返回 `None`。
#[cfg(windows)]
fn path_owner_and_dacl(path: &Path) -> Option<(String, Option<Vec<AceRecord>>)> {
    // ConvertSidToStringSidW 在 Security::Authorization（仓库已有用例）；LocalFree 在 Foundation。
    use std::ffi::c_void;
    use std::os::windows::ffi::OsStrExt;
    use windows_sys::Win32::Foundation::LocalFree;
    use windows_sys::Win32::Security::Authorization::ConvertSidToStringSidW;

    /// SID（PSID）→ 字符串；失败返回 None。
    fn sid_to_string(sid: *mut c_void) -> Option<String> {
        if sid.is_null() {
            return None;
        }
        let mut raw: *mut u16 = std::ptr::null_mut();
        // SAFETY: sid 由系统给出；字符串由 LocalFree 释放。
        if unsafe { ConvertSidToStringSidW(sid, &mut raw) } == 0 || raw.is_null() {
            return None;
        }
        let mut len = 0usize;
        unsafe {
            while *raw.add(len) != 0 {
                len += 1;
            }
        }
        let text = String::from_utf16_lossy(unsafe { std::slice::from_raw_parts(raw, len) });
        unsafe { LocalFree(raw.cast()) };
        Some(text)
    }

    let wide: Vec<u16> = path.as_os_str().encode_wide().chain(std::iter::once(0)).collect();
    let mut owner: *mut c_void = std::ptr::null_mut();
    let mut dacl: *mut c_void = std::ptr::null_mut();
    let mut sd: *mut c_void = std::ptr::null_mut();
    // SAFETY: `wide` 以 NUL 结尾；输出指针由系统写入，安全描述符用 LocalFree 释放。
    let status = unsafe {
        GetNamedSecurityInfoW(
            wide.as_ptr(),
            SE_FILE_OBJECT,
            DACL_SECURITY_INFORMATION | OWNER_SECURITY_INFORMATION,
            &mut owner,
            std::ptr::null_mut(),
            &mut dacl,
            std::ptr::null_mut(),
            &mut sd,
        )
    };
    if status != 0 {
        return None;
    }
    // 从这里开始无论怎么返回都要释放安全描述符。
    let finish = |value: Option<(String, Option<Vec<AceRecord>>)>| {
        if !sd.is_null() {
            unsafe { LocalFree(sd.cast()) };
        }
        value
    };

    let Some(owner_sid) = sid_to_string(owner) else {
        return finish(None);
    };

    // NULL DACL：所有人都完全控制，直接按「无 DACL」上报。
    if dacl.is_null() {
        return finish(Some((owner_sid, None)));
    }
    let mut info = AclSizeInfo { ace_count: 0, acl_bytes_in_use: 0, acl_bytes_free: 0 };
    let ok = unsafe {
        GetAclInformation(
            dacl,
            (&mut info as *mut AclSizeInfo).cast(),
            std::mem::size_of::<AclSizeInfo>() as u32,
            ACL_SIZE_INFORMATION_CLASS,
        )
    };
    if ok == 0 {
        return finish(None);
    }
    let mut aces: Vec<AceRecord> = Vec::with_capacity(info.ace_count as usize);
    for index in 0..info.ace_count {
        let mut ace: *mut c_void = std::ptr::null_mut();
        if unsafe { GetAce(dacl, index, &mut ace) } == 0 || ace.is_null() {
            return finish(None);
        }
        // SAFETY: GetAce 返回的指针至少含 4 字节 ACE_HEADER；allow ACE 之后是 Mask 与 SID。
        // 只按 Win32 固定布局读原始字节，避免依赖具体结构体定义。
        let bytes = ace as *const u8;
        let ace_type = unsafe { *bytes };
        let ace_flags = unsafe { *bytes.add(1) };
        let mut record: AceRecord = (ace_type, ace_flags, 0, String::new());
        if ace_type == ACE_TYPE_ACCESS_ALLOWED {
            let mask = unsafe { *(ace as *const u32).add(1) }; // 偏移 4：AccessMask
            let sid = unsafe { bytes.add(ACCESS_ALLOWED_ACE_SID_OFFSET) as *mut c_void };
            record.2 = mask;
            // 转换不了 SID：记为不可信主体（保证判定为失败），不中断整份 DACL。
            record.3 = sid_to_string(sid).unwrap_or_else(|| "<unknown>".to_string());
        }
        aces.push(record);
    }
    finish(Some((owner_sid, Some(aces))))
}

#[cfg(not(windows))]
#[allow(dead_code)]
fn path_owner_and_dacl(_path: &Path) -> Option<(String, Option<Vec<AceRecord>>)> {
    None
}

/// 单个路径的 ACL 是否「只有管理员可写」。
#[allow(dead_code)]
fn path_acl_admin_only_write(path: &Path) -> bool {
    // 重解析点（junction/symlink）一律不信任：GetNamedSecurityInfoW 看的是链接本身，
    // 而实际内容可能在别处。
    if crate::winpaths::is_reparse_point(path) {
        return false;
    }
    match path_owner_and_dacl(path) {
        Some((owner, dacl)) => dacl_admin_only_write(&owner, dacl.as_deref()),
        None => false,
    }
}

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
    // 第一遍：尽早失败，错误文案统一。
    let helper = ensure_helper_location(&helper)?;
    let system32 = system32_dir().ok_or_else(|| "找不到 System32 目录".to_string())?;
    let powershell = powershell_path().ok_or_else(|| "找不到系统 PowerShell".to_string())?;
    let (file_w, dir_w, verb_w) = (
        wide_path(&powershell),
        wide_path(&system32),
        wide("runas"),
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

    // 紧挨着 ShellExecuteExW 再跑一遍完整校验：从第一次校验到这里之间，安装目录或助手文件
    // 仍可能被换掉。这一遍给出的路径才是真正交给 PowerShell `-File` 的路径。
    let revalidated = match ensure_helper_location(&helper) {
        Ok(path) => path,
        Err(err) => {
            if com_ready { unsafe { CoUninitialize() } }
            return Err(err);
        }
    };
    if !same_path(&revalidated, &helper) {
        if com_ready { unsafe { CoUninitialize() } }
        return Err(INSECURE_INSTALL_DIR.to_string());
    }
    let args = match build_helper_args(&revalidated, payload) {
        Ok(args) => args,
        Err(err) => {
            if com_ready { unsafe { CoUninitialize() } }
            return Err(err);
        }
    };
    let args_w = wide(&args);

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
    // ---- t6b-fix：安装目录形状（纯函数） ----
    #[test]
    fn allowed_install_dir_accepts_only_drive_child_or_program_files_child() {
        let roots = vec![
            PathBuf::from(r"\\?\C:\Program Files"),
            PathBuf::from(r"C:\Program Files (x86)"),
        ];
        // 盘根的直接子目录 `X:\Vega`。
        for ok in [r"C:\Vega", r"D:\Vega", r"c:\vega", r"\\?\E:\Vega", r"D:\Vega\"] {
            assert!(allowed_install_dir(Path::new(ok), &roots), "{ok}");
        }
        // Program Files 根的直接子目录，大小写与 verbatim 前缀都不影响。
        for ok in [
            r"C:\Program Files\Vega",
            r"\\?\C:\Program Files\Vega",
            r"c:\program files\vega",
            r"C:\Program Files (x86)\Vega",
        ] {
            assert!(allowed_install_dir(Path::new(ok), &roots), "{ok}");
        }
        // 更深一层、改名、盘根下别的名字、名字只是前缀相同的目录：都不认。
        for bad in [
            r"C:\Vega\sub",
            r"C:\Program Files\Vega\sub",
            r"C:\Program Files\Vega2",
            r"C:\Program Files\Vega-Evil",
            r"C:\Vega2",
            r"C:\Other",
            r"C:\Program Files",
            r"\\srv\share\Vega",
            // 名字对但父目录不是盘根 / 不是 Program Files 根。
            r"C:\Users\me\Vega",
            r"C:\Program Files Evil\Vega",
        ] {
            assert!(!allowed_install_dir(Path::new(bad), &roots), "{bad}");
        }
        assert!(!allowed_install_dir(Path::new(r"C:\Program Files\Vega"), &[]));
    }
    #[test]
    fn is_drive_root_matches_letter_colon_only() {
        for ok in ["C:", r"C:\", r"\\?\D:\", "d:/"] {
            assert!(is_drive_root(Path::new(ok)), "{ok}");
        }
        for bad in [r"C:\Vega", r"\\srv\share", "", r"C:temp"] {
            assert!(!is_drive_root(Path::new(bad)), "{bad}");
        }
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
    // ---- t6b：安装目录 DACL 判定 ----
    /// 便捷构造一条 allow ACE：`(sid, mask, flags)`。
    fn ace(sid: &str, mask: u32, flags: u8) -> AceRecord {
        (ACE_TYPE_ACCESS_ALLOWED, flags, mask, sid.to_string())
    }
    const FILE_ALL: u32 = 0x001F_01FF; // FILE_ALL_ACCESS
    const FILE_READ_EXEC: u32 = 0x0012_00A9; // 只读 + 执行
    #[test]
    fn dacl_admin_only_write_accepts_installer_acl() {
        // 安装器 icacls 之后的典型 DACL：SYSTEM/Administrators 完全控制，Users 只读执行。
        let aces = vec![
            ace(SID_LOCAL_SYSTEM, FILE_ALL, 0),
            ace(SID_ADMINISTRATORS, FILE_ALL, 0),
            ace("S-1-5-32-545", FILE_READ_EXEC, 0),
            ace(SID_TRUSTED_INSTALLER, FILE_ALL, 0),
        ];
        assert!(dacl_admin_only_write(SID_ADMINISTRATORS, Some(&aces)));
        assert!(dacl_admin_only_write(SID_LOCAL_SYSTEM, Some(&aces)));
        assert!(dacl_admin_only_write(SID_TRUSTED_INSTALLER, Some(&aces)));
        // 空 DACL：不授予任何写权限，算安全。
        assert!(dacl_admin_only_write(SID_ADMINISTRATORS, Some(&[])));
    }
    #[test]
    fn dacl_admin_only_write_rejects_user_writes() {
        // Users 有 FILE_WRITE_DATA：提权助手可被替换 → 拒绝。
        let aces = vec![
            ace(SID_ADMINISTRATORS, FILE_ALL, 0),
            ace("S-1-5-32-545", 0x0000_0002, 0),
        ];
        assert!(!dacl_admin_only_write(SID_ADMINISTRATORS, Some(&aces)));
        // Authenticated Users 有修改（DELETE 等）：同样拒绝。
        let aces = vec![
            ace(SID_ADMINISTRATORS, FILE_ALL, 0),
            ace("S-1-5-11", 0x0001_0000 | 0x0000_0002, 0),
        ];
        assert!(!dacl_admin_only_write(SID_ADMINISTRATORS, Some(&aces)));
        // GENERIC_ALL 给 Everyone：拒绝。
        let aces = vec![ace("S-1-1-0", 0x1000_0000, 0)];
        assert!(!dacl_admin_only_write(SID_ADMINISTRATORS, Some(&aces)));
    }
    #[test]
    fn dacl_admin_only_write_creator_owner_rules() {
        // CREATOR OWNER 的继承 ACE（INHERIT_ONLY）只作用于子对象，放行。
        let inherit_only = vec![
            ace(SID_ADMINISTRATORS, FILE_ALL, 0),
            ace(SID_CREATOR_OWNER, FILE_ALL, ACE_FLAG_INHERIT_ONLY),
        ];
        assert!(dacl_admin_only_write(SID_ADMINISTRATORS, Some(&inherit_only)));
        // 不带 INHERIT_ONLY 时它作用于目录本身：拒绝。
        let direct = vec![
            ace(SID_ADMINISTRATORS, FILE_ALL, 0),
            ace(SID_CREATOR_OWNER, FILE_ALL, 0),
        ];
        assert!(!dacl_admin_only_write(SID_ADMINISTRATORS, Some(&direct)));
    }
    #[test]
    fn dacl_admin_only_write_rejects_null_dacl_and_untrusted_owner() {
        // NULL DACL（None）：所有人完全控制。
        assert!(!dacl_admin_only_write(SID_ADMINISTRATORS, None));
        // 所有者是普通用户：他可以改回 DACL。
        let aces = vec![ace(SID_ADMINISTRATORS, FILE_ALL, 0)];
        assert!(!dacl_admin_only_write("S-1-5-21-1-2-3-1001", Some(&aces)));
        // 所有者缺失 / 空字符串同样拒绝。
        assert!(!dacl_admin_only_write("", Some(&aces)));
    }
    #[test]
    fn dacl_admin_only_write_rejects_non_plain_allow_aces() {
        // ACCESS_ALLOWED_OBJECT_ACE_TYPE（0x05）：带对象类型的 allow，无法确认授权对象。
        let aces = vec![(0x05u8, 0u8, FILE_ALL, SID_ADMINISTRATORS.to_string())];
        assert!(!dacl_admin_only_write(SID_ADMINISTRATORS, Some(&aces)));
        // 未知 ACE 类型：不能证明安全。
        let aces = vec![(0x7Fu8, 0u8, FILE_READ_EXEC, SID_ADMINISTRATORS.to_string())];
        assert!(!dacl_admin_only_write(SID_ADMINISTRATORS, Some(&aces)));
        // DENY ACE 不放行访问，不影响判定。
        let aces = vec![
            ace(SID_ADMINISTRATORS, FILE_ALL, 0),
            (0x01u8, 0u8, FILE_ALL, "S-1-5-11".to_string()),
        ];
        assert!(dacl_admin_only_write(SID_ADMINISTRATORS, Some(&aces)));
    }
    // ---- t6b-fix：祖先目录规则与 ACE 类型 ----
    const SID_USERS: &str = "S-1-5-32-545";
    const SID_AUTHENTICATED_USERS: &str = "S-1-5-11";
    const FILE_ADD_FILE: u32 = 0x0000_0002;
    const FILE_ADD_SUBDIRECTORY: u32 = 0x0000_0004;
    const FILE_DELETE_CHILD: u32 = 0x0000_0040;
    const DELETE: u32 = 0x0001_0000;
    const WRITE_DAC: u32 = 0x0004_0000;
    const WRITE_OWNER: u32 = 0x0008_0000;
    #[test]
    fn ancestor_allows_create_folder_on_drive_root() {
        // 盘根默认 ACL：Authenticated Users 能建目录/建文件，Users 只读执行，
        // CREATOR OWNER 只在 INHERIT_ONLY 里出现。这必须放行，否则盘根安装全被拒。
        let aces = vec![
            ace(SID_LOCAL_SYSTEM, FILE_ALL, 0),
            ace(SID_ADMINISTRATORS, FILE_ALL, 0),
            ace(SID_USERS, FILE_READ_EXEC, 0),
            ace(SID_USERS, FILE_ADD_SUBDIRECTORY | FILE_ADD_FILE, 0),
            ace(SID_AUTHENTICATED_USERS, FILE_ADD_SUBDIRECTORY | FILE_ADD_FILE, 0),
            ace(SID_AUTHENTICATED_USERS, FILE_ALL, ACE_FLAG_INHERIT_ONLY),
            ace(SID_CREATOR_OWNER, FILE_ALL, ACE_FLAG_INHERIT_ONLY),
        ];
        assert!(ancestor_admin_only_control(SID_LOCAL_SYSTEM, Some(&aces)));
        // 空 DACL 同样安全。
        assert!(ancestor_admin_only_control(SID_ADMINISTRATORS, Some(&[])));
    }
    #[test]
    fn ancestor_rejects_users_modify_without_inherit_only() {
        // Users 拿到 DELETE + WRITE_DAC：能删掉 `Vega` 再建同名目录 → 拒绝。
        for mask in [
            DELETE,
            FILE_DELETE_CHILD,
            WRITE_DAC,
            WRITE_OWNER,
            0x1000_0000, // GENERIC_ALL
            0x4000_0000, // GENERIC_WRITE
            DELETE | WRITE_DAC | FILE_DELETE_CHILD, // 「修改」档
        ] {
            let aces = vec![
                ace(SID_ADMINISTRATORS, FILE_ALL, 0),
                ace(SID_USERS, mask, 0),
            ];
            assert!(!ancestor_admin_only_control(SID_ADMINISTRATORS, Some(&aces)), "mask=0x{mask:08X}");
        }
        // 同样的权限只出现在 INHERIT_ONLY 的 ACE 上：不作用于祖先目录本身，放行。
        let aces = vec![
            ace(SID_ADMINISTRATORS, FILE_ALL, 0),
            ace(SID_USERS, DELETE | WRITE_DAC | FILE_DELETE_CHILD, ACE_FLAG_INHERIT_ONLY),
        ];
        assert!(ancestor_admin_only_control(SID_ADMINISTRATORS, Some(&aces)));
    }
    #[test]
    fn ancestor_rejects_user_owned_or_null_dacl() {
        let aces = vec![ace(SID_ADMINISTRATORS, FILE_ALL, 0)];
        // 所有者在普通用户手里：他能改回 DACL。
        assert!(!ancestor_admin_only_control("S-1-5-21-1-2-3-1001", Some(&aces)));
        assert!(!ancestor_admin_only_control("", Some(&aces)));
        // NULL DACL。
        assert!(!ancestor_admin_only_control(SID_ADMINISTRATORS, None));
        // TrustedInstaller 作为所有者是允许的（Program Files 根就是）。
        assert!(ancestor_admin_only_control(SID_TRUSTED_INSTALLER, Some(&aces)));
    }
    #[test]
    fn ace_class_rejects_compound_and_other_allow_variants() {
        // 只有普通 ACCESS_ALLOWED_ACE 算 allow。
        assert_eq!(ace_class(0x00), Some(true));
        // deny / audit / alarm 及其对象、回调变体：不放行访问，可跳过。
        for skipped in [0x01u8, 0x02, 0x03, 0x06, 0x07, 0x08, 0x0A, 0x0C, 0x0D, 0x0E, 0x0F, 0x10] {
            assert_eq!(ace_class(skipped), Some(false), "0x{skipped:02X}");
        }
        // ACCESS_ALLOWED_COMPOUND(0x04) 与其他 allow 变体、未知类型：一律拒绝。
        for rejected in [0x04u8, 0x05, 0x09, 0x0B, 0x11, 0x7F] {
            assert_eq!(ace_class(rejected), None, "0x{rejected:02X}");
        }
    }
    #[test]
    fn compound_allow_ace_is_rejected_by_both_dacl_rules() {
        // 0x04 曾被当成 deny/audit 跳过；现在两条判定都必须拒绝。
        let aces = vec![
            ace(SID_ADMINISTRATORS, FILE_ALL, 0),
            (0x04u8, 0u8, FILE_ALL, SID_ADMINISTRATORS.to_string()),
        ];
        assert!(!dacl_admin_only_write(SID_ADMINISTRATORS, Some(&aces)));
        assert!(!ancestor_admin_only_control(SID_ADMINISTRATORS, Some(&aces)));
    }
    #[test]
    fn same_path_compares_directories_case_insensitively() {
        assert!(same_path(Path::new(r"C:\Vega\resources"), Path::new(r"c:\vega\resources\")));
        assert!(same_path(Path::new(r"\\?\D:\Vega"), Path::new(r"D:\Vega")));
        assert!(!same_path(Path::new(r"D:\Vega\resources"), Path::new(r"D:\Vega")));
        assert!(!same_path(Path::new(r"D:\Vega"), Path::new(r"D:\Vega2")));
    }
    #[test]
    fn dacl_error_text_is_the_documented_one() {
        assert_eq!(INSECURE_INSTALL_DIR, "Vega 安装目录权限不安全，无法设置长期密码。请重新运行安装包修复。");
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
