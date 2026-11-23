//! 定位 rustdesk.exe，并把访问码写成 RustDesk 的永久密码。
//!
//! 只经命令行参数把访问码交给 rustdesk 子进程，不写日志、不落状态文件之外的
//! 任何位置。子进程用 CREATE_NO_WINDOW 启动，单个命令最多等 15 秒，超时就
//! TerminateProcess。

use std::path::{Path, PathBuf};

pub const RUSTDESK_EXE: &str = "rustdesk.exe";
pub const PERMANENT_METHOD: &str = "use-permanent-password";

/// 找 rustdesk.exe：Program Files 系列环境变量 + 卸载注册表项，不做 PATH 搜索。
pub fn locate() -> Option<PathBuf> {
    #[cfg(windows)]
    {
        windows_impl::locate()
    }
    #[cfg(not(windows))]
    {
        None
    }
}

/// 应用访问码：先 `--password <code>`，再 `--option verification-method use-permanent-password`。
pub fn apply_code(code: &str) -> Result<(), String> {
    #[cfg(windows)]
    {
        windows_impl::apply_code(code)
    }
    #[cfg(not(windows))]
    {
        let _ = code;
        Err("当前平台不支持 RustDesk 集成".to_string())
    }
}

#[cfg(windows)]
mod windows_impl {
    use super::{Path, PathBuf, PERMANENT_METHOD, RUSTDESK_EXE};
    use std::mem::size_of;
    use std::ptr;

    const CREATE_NO_WINDOW: u32 = 0x0800_0000;
    const WAIT_TIMEOUT_MS: u32 = 15_000;

    pub fn locate() -> Option<PathBuf> {
        let mut roots: Vec<PathBuf> = Vec::new();
        for key in ["ProgramW6432", "ProgramFiles", "ProgramFiles(x86)"] {
            if let Some(value) = std::env::var_os(key) {
                if !value.is_empty() {
                    roots.push(PathBuf::from(value));
                }
            }
        }
        for root in roots {
            let candidate = root.join("RustDesk").join(RUSTDESK_EXE);
            if candidate.is_file() {
                return Some(candidate);
            }
        }
        for location in registry_locations() {
            if let Some(candidate) = normalize_location(&location) {
                if candidate.is_file() {
                    return Some(candidate);
                }
            }
        }
        None
    }

    pub fn apply_code(code: &str) -> Result<(), String> {
        let exe = locate().ok_or_else(|| "找不到 RustDesk".to_string())?;
        run_cli(&exe, &["--password", code])?;
        run_cli(
            &exe,
            &["--option", "verification-method", PERMANENT_METHOD],
        )?;
        Ok(())
    }

    fn normalize_location(value: &str) -> Option<PathBuf> {
        let mut text = value.trim().trim_matches('"').to_string();
        if let Some((_, suffix)) = text.rsplit_once(',') {
            if suffix.trim().parse::<u32>().is_ok() {
                text = text[..text.len() - suffix.len() - 1]
                    .trim()
                    .trim_matches('"')
                    .to_string();
            }
        }
        if text.is_empty() {
            return None;
        }
        let path = PathBuf::from(text);
        if path
            .file_name()
            .map(|name| name.eq_ignore_ascii_case(RUSTDESK_EXE))
            .unwrap_or(false)
        {
            Some(path)
        } else {
            Some(path.join(RUSTDESK_EXE))
        }
    }

    fn run_cli(exe: &Path, args: &[&str]) -> Result<(), String> {
        use std::os::windows::ffi::OsStrExt;
        use windows_sys::Win32::Foundation::{CloseHandle, GetLastError, WAIT_OBJECT_0, WAIT_TIMEOUT};
        use windows_sys::Win32::System::Threading::{
            CreateProcessW, GetExitCodeProcess, TerminateProcess, WaitForSingleObject,
            PROCESS_INFORMATION, STARTUPINFOW,
        };

        let exe_wide: Vec<u16> = exe
            .as_os_str()
            .encode_wide()
            .chain(std::iter::once(0))
            .collect();
        let mut command = Vec::<u16>::new();
        command.push(b'"' as u16);
        command.extend(exe.as_os_str().encode_wide());
        command.push(b'"' as u16);
        for arg in args {
            command.push(b' ' as u16);
            command.extend(arg.encode_utf16());
        }
        command.push(0);

        let mut startup: STARTUPINFOW = unsafe { std::mem::zeroed() };
        startup.cb = size_of::<STARTUPINFOW>() as u32;
        let mut process: PROCESS_INFORMATION = unsafe { std::mem::zeroed() };

        // SAFETY: 两个宽字符串都以 NUL 结尾；startup/process 是有效输出结构体。
        let ok = unsafe {
            CreateProcessW(
                exe_wide.as_ptr(),
                command.as_mut_ptr(),
                ptr::null(),
                ptr::null(),
                0,
                CREATE_NO_WINDOW,
                ptr::null(),
                ptr::null(),
                &startup,
                &mut process,
            )
        };
        if ok == 0 {
            let code = unsafe { GetLastError() };
            return Err(format!("启动 RustDesk 失败（错误码 {code}）"));
        }

        // SAFETY: process.hProcess 由 CreateProcessW 返回，等待/查询后统一关闭。
        let wait = unsafe { WaitForSingleObject(process.hProcess, WAIT_TIMEOUT_MS) };
        if wait == WAIT_TIMEOUT {
            unsafe {
                TerminateProcess(process.hProcess, 1);
                WaitForSingleObject(process.hProcess, 5_000);
                CloseHandle(process.hThread);
                CloseHandle(process.hProcess);
            }
            return Err("RustDesk 命令超时".to_string());
        }
        if wait != WAIT_OBJECT_0 {
            unsafe {
                CloseHandle(process.hThread);
                CloseHandle(process.hProcess);
            }
            return Err("等待 RustDesk 命令结束失败".to_string());
        }

        let mut exit_code = 0u32;
        let got = unsafe { GetExitCodeProcess(process.hProcess, &mut exit_code) };
        unsafe {
            CloseHandle(process.hThread);
            CloseHandle(process.hProcess);
        }
        if got == 0 {
            return Err("读取 RustDesk 退出码失败".to_string());
        }
        if exit_code != 0 {
            return Err(format!("RustDesk 命令退出码 {exit_code}"));
        }
        Ok(())
    }

    /* ---------------- 注册表定位（无 windows-sys Registry 依赖） ---------------- */

    type Hkey = isize;
    const HKEY_LOCAL_MACHINE: Hkey = 0x8000_0002u32 as i32 as isize;
    const KEY_READ: u32 = 0x0002_0019;
    const KEY_WOW64_64KEY: u32 = 0x0000_0100;
    const KEY_WOW64_32KEY: u32 = 0x0000_0200;
    const REG_SZ: u32 = 1;

    #[link(name = "advapi32")]
    extern "system" {
        fn RegOpenKeyExW(
            hkey: Hkey,
            sub_key: *const u16,
            options: u32,
            sam_desired: u32,
            result: *mut Hkey,
        ) -> i32;
        fn RegQueryValueExW(
            hkey: Hkey,
            value_name: *const u16,
            reserved: *mut u32,
            value_type: *mut u32,
            data: *mut u8,
            data_size: *mut u32,
        ) -> i32;
        fn RegCloseKey(hkey: Hkey) -> i32;
    }

    fn wide(value: &str) -> Vec<u16> {
        value.encode_utf16().chain(std::iter::once(0)).collect()
    }

    fn registry_locations() -> Vec<String> {
        let keys = [
            r"SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\RustDesk",
            r"SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\RustDesk",
        ];
        let mut result = Vec::new();
        for key in keys {
            for view in [KEY_WOW64_64KEY, KEY_WOW64_32KEY] {
                let key_wide = wide(key);
                let mut handle: Hkey = 0;
                // SAFETY: key_wide 以 NUL 结尾；handle 是有效输出。
                let open = unsafe {
                    RegOpenKeyExW(
                        HKEY_LOCAL_MACHINE,
                        key_wide.as_ptr(),
                        0,
                        KEY_READ | view,
                        &mut handle,
                    )
                };
                if open != 0 {
                    continue;
                }
                for value_name in ["InstallLocation", "DisplayIcon"] {
                    if let Some(value) = query_string(handle, value_name) {
                        if !value.is_empty() {
                            result.push(value);
                        }
                    }
                }
                // SAFETY: handle 来自 RegOpenKeyExW 且只关闭一次。
                unsafe {
                    RegCloseKey(handle);
                }
            }
        }
        result
    }

    fn query_string(handle: Hkey, value_name: &str) -> Option<String> {
        let name = wide(value_name);
        let mut value_type = 0u32;
        let mut size = 0u32;
        // SAFETY: 先查长度，data 传空、size 是有效输出。
        let first = unsafe {
            RegQueryValueExW(
                handle,
                name.as_ptr(),
                ptr::null_mut(),
                &mut value_type,
                ptr::null_mut(),
                &mut size,
            )
        };
        if first != 0 || value_type != REG_SZ || size == 0 || size > 16_384 {
            return None;
        }
        let mut buffer = vec![0u8; size as usize];
        // SAFETY: buffer 长度等于查询返回的 size。
        let second = unsafe {
            RegQueryValueExW(
                handle,
                name.as_ptr(),
                ptr::null_mut(),
                &mut value_type,
                buffer.as_mut_ptr(),
                &mut size,
            )
        };
        if second != 0 || value_type != REG_SZ {
            return None;
        }
        let units: Vec<u16> = buffer
            .chunks_exact(2)
            .map(|pair| u16::from_le_bytes([pair[0], pair[1]]))
            .take_while(|unit| *unit != 0)
            .collect();
        String::from_utf16(&units).ok()
    }
}
