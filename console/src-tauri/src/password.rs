//! 长期密码后端（T4d2）。见 docs/ui/console-design-v0.2.md 第 6 节：控制台不常驻提权；密码只经
//! DACL 收紧的临时文件交给提权助手，绝不进命令行/日志/返回值；状态只回答「是否已设置」和验证方式。
use crate::rustdesk::{self, OpResult};
use serde::Serialize;
use std::path::{Path, PathBuf};
use std::time::Duration;
const MIN_LEN: usize = 8;
const MAX_LEN: usize = 64;
const HELPER_SCRIPT: &str = "vega-pwhelper.ps1";
const HELPER_TIMEOUT: Duration = Duration::from_secs(30);
/// ERROR_CANCELLED：用户在 UAC 点了「否」。
const UAC_CANCELLED: i32 = 1223;
/// 内置 Administrators 组；`*` 前缀按 SID 解析，不受语言/改名影响。
const ADMIN_SID: &str = "*S-1-5-32-544:R";
#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
pub struct PasswordStatus { pub has_permanent: bool, pub verify_method: String }
/// 8~64 位、含字母和数字、无控制字符。错误信息绝不回显密码。
pub fn validate_password(password: &str) -> Result<(), String> {
    let chars: Vec<char> = password.chars().collect();
    let strong = chars.iter().any(|c| c.is_alphabetic()) && chars.iter().any(|c| c.is_ascii_digit());
    match ((MIN_LEN..=MAX_LEN).contains(&chars.len()), chars.iter().any(|c| c.is_control()), strong) {
        (false, ..) => Err(format!("密码需为 {MIN_LEN}~{MAX_LEN} 位")),
        (_, true, _) => Err("密码不能包含控制字符".into()),
        (_, _, false) => Err("密码需同时包含字母和数字".into()),
        _ => Ok(()),
    }
}
/// 前端验证方式 → RustDesk `verification-method` 配置值。
pub fn map_verify(verify: &str) -> Result<&'static str, String> {
    match verify {
        "temporary" => Ok("use-temporary-password"),
        "permanent" => Ok("use-permanent-password"),
        "both" => Ok("use-both-passwords"),
        _ => Err("验证方式只能是 temporary|permanent|both".into()),
    }
}
fn toml_table(text: &str) -> Option<toml::Table> {
    (!text.trim().is_empty()).then(|| toml::from_str::<toml::Table>(text).ok()).flatten()
}
/// RustDesk2.toml `[options] verification-method` 反解；缺省/未知 → temporary。
pub fn parse_verify_method(text: &str) -> String {
    let raw = toml_table(text).and_then(|d| {
        d.get("options")?.get("verification-method")?.as_str().map(str::to_owned)
    });
    match raw.unwrap_or_default().trim() {
        "use-permanent-password" => "permanent",
        "use-both-passwords" => "both",
        _ => "temporary",
    }
    .to_string()
}
/// RustDesk.toml 有非空 `password` 即视为已设置（内容永不外传）。
pub fn has_permanent_password(text: &str) -> bool {
    toml_table(text).and_then(|d| Some(!d.get("password")?.as_str()?.trim().is_empty())).unwrap_or(false)
}
/// icacls 参数：继承全清，Administrators 只读、当前用户读写；逐个参数传、不经 shell。
pub fn build_icacls_args(file: &str, user: &str) -> Vec<String> {
    vec![file.to_string(), "/inheritance:r".into(), "/grant:r".into(), ADMIN_SID.into(),
        format!("{user}:RW")]
}
fn config_dir() -> Option<PathBuf> {
    rustdesk::user_config_path()?.parent().map(Path::to_path_buf)
}
/// 提权助手：安装目录 `resources\vega-pwhelper.ps1`，dev 回落源码目录。
fn helper_script(app: &tauri::AppHandle) -> Option<PathBuf> {
    use tauri::Manager;
    let installed = app.path().resource_dir().ok().and_then(|dir| {
        [dir.join("resources").join(HELPER_SCRIPT), dir.join(HELPER_SCRIPT)]
            .into_iter().find(|p| p.is_file())
    });
    if installed.is_some() { return installed; }
    let dev = PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("resources").join(HELPER_SCRIPT);
    dev.is_file().then_some(dev)
}
#[tauri::command]
pub fn get_password_status() -> PasswordStatus {
    let dir = config_dir().unwrap_or_default();
    PasswordStatus {
        has_permanent: std::fs::read_to_string(dir.join("RustDesk.toml"))
            .map(|t| has_permanent_password(&t)).unwrap_or(false),
        verify_method: std::fs::read_to_string(dir.join("RustDesk2.toml"))
            .map(|t| parse_verify_method(&t)).unwrap_or_else(|_| "temporary".into()),
    }
}
#[tauri::command]
pub fn set_permanent_password(password: String, verify: String, app: tauri::AppHandle) -> OpResult {
    let verification = match validate_password(&password).and_then(|()| map_verify(&verify)) {
        Ok(value) => value,
        Err(msg) => return OpResult::err(msg),
    };
    // 只有映射后的 RustDesk 值与密码一起进载荷；密码不进命令行。
    let json = serde_json::json!({ "password": password, "verification": verification }).to_string();
    #[cfg(not(windows))]
    return { let _ = (&app, &json); OpResult::err("仅支持 Windows") };
    #[cfg(windows)]
    {
        let Some(path) = write_payload_file(&json) else {
            return OpResult::err("创建临时密码文件失败");
        };
        let result = tighten_dacl(&path).and_then(|()| run_helper(&app, "set", Some(path.as_path())));
        let _ = std::fs::remove_file(&path); // 助手读后自删；这里再兜底一次。
        result.map_or_else(|e| OpResult::err(e), |()| OpResult::ok("长期密码已设置"))
    }
}
#[tauri::command]
pub fn clear_permanent_password(app: tauri::AppHandle) -> OpResult {
    run_helper(&app, "clear", None).map_or_else(|e| OpResult::err(e),
        |()| OpResult::ok("长期密码已清除，验证方式已改回临时密码"))
}
/// `%TEMP%` 下唯一文件：进程号 + 原子序号 + 纳秒，并发写不互相覆盖。
#[cfg(windows)]
fn write_payload_file(json: &str) -> Option<PathBuf> {
    use std::io::Write;
    use std::sync::atomic::{AtomicU64, Ordering};
    static SEQ: AtomicU64 = AtomicU64::new(0);
    let nanos = std::time::SystemTime::now().duration_since(std::time::UNIX_EPOCH).map(|d| d.as_nanos()).unwrap_or(0);
    let path = std::env::temp_dir().join(format!("vega-pw-{}-{}-{nanos}.json",
        std::process::id(), SEQ.fetch_add(1, Ordering::Relaxed)));
    let mut file = std::fs::OpenOptions::new().write(true).create_new(true).open(&path).ok()?;
    file.write_all(json.as_bytes()).and_then(|()| file.sync_all()).ok()?;
    Some(path)
}
#[cfg(windows)]
fn tighten_dacl(path: &Path) -> Result<(), String> {
    let user = std::env::var("USERNAME").unwrap_or_default();
    if user.is_empty() { return Err("无法确定当前用户".into()); }
    let status = std::process::Command::new("icacls")
        .args(build_icacls_args(&path.display().to_string(), &user))
        .stdin(std::process::Stdio::null()).stdout(std::process::Stdio::null())
        .stderr(std::process::Stdio::null()).status()
        .map_err(|_| "收紧临时文件权限失败".to_string())?;
    if status.success() { Ok(()) } else { Err("收紧临时文件权限失败".into()) }
}
/// `Start-Process -Verb RunAs` 拉起助手：命令行只有脚本、模式和载荷路径，绝无密码；UAC 被拒 →「已取消」，超 30 s kill。
#[cfg(windows)]
fn run_helper(app: &tauri::AppHandle, mode: &str, payload: Option<&Path>) -> Result<(), String> {
    let script = helper_script(app).ok_or_else(|| "找不到提权助手 vega-pwhelper.ps1".to_string())?;
    let inner = helper_cmdline(&script.display().to_string(), mode, payload);
    let command = format!("$ErrorActionPreference='Stop';try{{$p=Start-Process -FilePath \
        'powershell.exe' -ArgumentList '{inner}' -Verb RunAs -Wait -PassThru \
        -WindowStyle Hidden;exit $p.ExitCode}}catch{{exit {UAC_CANCELLED}}}");
    let mut child = std::process::Command::new("powershell.exe")
        .args(["-NoProfile", "-NonInteractive", "-ExecutionPolicy", "Bypass", "-WindowStyle",
            "Hidden", "-Command", command.as_str()])
        .stdin(std::process::Stdio::null()).stdout(std::process::Stdio::null())
        .stderr(std::process::Stdio::null()).spawn()
        .map_err(|_| "无法启动提权助手".to_string())?;
    let deadline = std::time::Instant::now() + HELPER_TIMEOUT;
    while std::time::Instant::now() < deadline {
        if let Ok(Some(status)) = child.try_wait() {
            return match status.code().unwrap_or(-1) {
                0 => Ok(()),
                UAC_CANCELLED => Err("已取消".into()),
                code => Err(format!("助手执行失败（退出码 {code}）")),
            };
        }
        std::thread::sleep(Duration::from_millis(100));
    }
    let _ = child.kill();
    let _ = child.wait();
    Err("提权助手超时未完成".into())
}
#[cfg(not(windows))]
fn run_helper(_app: &tauri::AppHandle, _mode: &str, _payload: Option<&Path>) -> Result<(), String> {
    Err("仅支持 Windows".into())
}
/// `-ArgumentList` 原文；单引号按 PowerShell 规则加倍转义。
#[cfg(windows)]
fn helper_cmdline(script: &str, mode: &str, payload: Option<&Path>) -> String {
    let quote = |s: &str| s.replace('\'', "''");
    let mut line = format!("-NoProfile -NonInteractive -ExecutionPolicy Bypass -File \"{}\" \
                            -Mode {mode}", quote(script));
    if let Some(file) = payload {
        line.push_str(&format!(" -Payload \"{}\"", quote(&file.display().to_string())));
    }
    line
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn password_strength() {
        assert!(validate_password("abcd1234").is_ok() && validate_password("A1b2C3d4!@#$").is_ok());
        for bad in ["abc1234", "abcdefgh", "12345678", "abcd\t1234", "abcd1234\n"] {
            assert!(validate_password(bad).is_err(), "{bad:?}");
        }
        assert!(validate_password(&"a1".repeat(33)).is_err(), "66 位太长");
        assert!(!validate_password("short1").unwrap_err().contains("short1"));
    }
    #[test]
    fn verify_mapping_and_parse() {
        for (given, want) in [("temporary", "use-temporary-password"),
            ("permanent", "use-permanent-password"), ("both", "use-both-passwords")] {
            assert_eq!(map_verify(given).unwrap(), want);
        }
        assert!(map_verify("use-both-passwords").is_err() && map_verify("").is_err());
        let m = |v: &str| parse_verify_method(&format!("[options]\nverification-method = \"{v}\"\n"));
        for (given, want) in [("use-permanent-password", "permanent"),
            ("use-both-passwords", "both"), ("use-temporary-password", "temporary"),
            ("nonsense", "temporary")] {
            assert_eq!(m(given), want);
        }
        assert_eq!(parse_verify_method(""), "temporary");
        assert_eq!(parse_verify_method("这不是 toml = = ="), "temporary");
    }
    #[test]
    fn icacls_args_and_presence() {
        let want: Vec<String> = [r"C:\Temp\vega-pw-1.json", "/inheritance:r", "/grant:r",
            "*S-1-5-32-544:R", "alice:RW"].map(String::from).into();
        assert_eq!(build_icacls_args(r"C:\Temp\vega-pw-1.json", "alice"), want);
        assert_eq!(build_icacls_args(r"C:\Users\a b\vega pw.json", "alice")[0], r"C:\Users\a b\vega pw.json");
        for empty in ["", "password = ''\n", "password = '   '\n",
            "[options]\nverification-method='both'\n"] {
            assert!(!has_permanent_password(empty));
        }
        assert!(has_permanent_password("password = 'secret-value'\n"));
    }
}
