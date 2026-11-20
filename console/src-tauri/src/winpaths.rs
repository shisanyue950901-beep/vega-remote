//! Windows 已知文件夹与受信任可执行文件解析（M2c 审计修复）。
//!
//! 审计 P1/P2 的根因是拿环境变量拼路径：`PathBuf::from("C:").join("Program Files")`
//! 得到的是盘符相对路径 `C:Program Files`，`%ProgramFiles%`、`%SystemRoot%`、`PATH`
//! 又都能被启动环境改写。这里统一改成：
//!
//! - 目录一律由 `SHGetKnownFolderPath` 取（`FOLDERID_ProgramFiles`、
//!   `FOLDERID_ProgramFilesX86`、`FOLDERID_System`、`FOLDERID_Windows`）；
//! - `Program Files` 根不接受「canonicalize 过就信」：必须正好等于
//!   `<系统盘根>\Program Files` / `<系统盘根>\Program Files (x86)`，根自身不能
//!   是重解析点（junction），且其卷根必须就是系统卷（`GetSystemDirectoryW` 所在卷）；
//! - 目录与可执行文件都先 `canonicalize`，再确认最终路径仍在对应根目录下；
//! - 调用方拿到的就是校验通过的那条路径，启动时不再二次解析；
//! - 非 Windows 一律返回 `None`，不加载任何系统 API。
//!
//! 不读环境变量、不做 `C:\` 拼接、不搜索 `PATH`。

use std::path::{Path, PathBuf};

/// 候选文件是否仍在根目录内（软链接已由 `canonicalize` 展开后比较）。
///
/// 两侧都先走 [`normalize`]：调用方可能拿到 `\\?\` verbatim 路径、正斜杠或
/// 尾部反斜杠，不能因为写法不同就把同一个目录判成不同根。
fn is_inside(root: &Path, candidate: &Path) -> bool {
    let (Some(root), Some(candidate)) = (root.to_str(), candidate.to_str()) else {
        return false;
    };
    let root = normalize(root).to_ascii_lowercase();
    let candidate = normalize(candidate).to_ascii_lowercase();
    candidate.len() > root.len()
        && candidate.starts_with(&root)
        && candidate.as_bytes()[root.len()] == b'\\'
}

/// 已知文件夹的原始路径（不规范化、不跟随重解析点）；拿不到就返回 `None`。
#[cfg(windows)]
fn known_folder_raw(id: &windows::core::GUID) -> Option<PathBuf> {
    use core::ffi::c_void;
    use windows::Win32::Foundation::HANDLE;
    use windows::Win32::System::Com::CoTaskMemFree;
    use windows::Win32::UI::Shell::{SHGetKnownFolderPath, KNOWN_FOLDER_FLAG};

    // SAFETY: `SHGetKnownFolderPath` 分配的是以 NUL 结尾的 UTF-16 字符串，
    // 由 COM 任务分配器释放。这里读出长度、立刻复制成 String，再用
    // CoTaskMemFree 释放一次；没有跨语句保存的裸指针。
    unsafe {
        let raw = SHGetKnownFolderPath(id, KNOWN_FOLDER_FLAG(0), None::<&HANDLE>).ok()?;
        let mut len = 0usize;
        while *raw.0.add(len) != 0 {
            len += 1;
        }
        let text = String::from_utf16_lossy(core::slice::from_raw_parts(raw.0, len));
        CoTaskMemFree(Some(raw.0 as *const c_void));
        if text.is_empty() {
            return None;
        }
        Some(PathBuf::from(text))
    }
}

/// 把已知文件夹解析成规范化目录；目录不存在或拿不到就返回 `None`。
#[cfg(windows)]
fn known_folder(id: &windows::core::GUID) -> Option<PathBuf> {
    let raw = known_folder_raw(id)?;
    let dir = std::fs::canonicalize(raw).ok()?;
    dir.is_dir().then_some(dir)
}

/// 系统 `Program Files` 与 `Program Files (x86)`（先验根、再规范化、去重、顺序固定）。
///
/// 每个候选都按顺序过四关：根自身不是重解析点 → 规范化 → 等于
/// `<系统卷根>\Program Files[(x86)]` → 卷根与系统卷一致。任何一关不过就跳过，
/// 不做「canonicalize 过就信任」。
#[cfg(windows)]
pub(crate) fn program_files_dirs() -> Vec<PathBuf> {
    use windows::Win32::UI::Shell::{FOLDERID_ProgramFiles, FOLDERID_ProgramFilesX86};

    // 系统盘根取自 GetSystemDirectoryW 所在卷；拿不到就没有可信任的根。
    let Some(system_volume) = system_volume_root() else {
        return Vec::new();
    };
    let mut roots: Vec<PathBuf> = Vec::new();
    for id in [&FOLDERID_ProgramFiles, &FOLDERID_ProgramFilesX86] {
        let Some(raw) = known_folder_raw(id) else {
            continue;
        };
        // 先验根自身：junction / 挂载点会把后续 canonicalize 引到别处。
        if is_reparse_point(&raw) {
            continue;
        }
        let Ok(dir) = std::fs::canonicalize(&raw) else {
            continue;
        };
        if !dir.is_dir() || !is_system_program_files_root(&dir, &system_volume) {
            continue;
        }
        if !same_volume_root(volume_root(&dir), Some(system_volume.clone())) {
            continue;
        }
        if !roots.contains(&dir) {
            roots.push(dir);
        }
    }
    roots
}

#[cfg(not(windows))]
pub(crate) fn program_files_dirs() -> Vec<PathBuf> {
    Vec::new()
}

/// 主 `Program Files` 目录（没有 x86 目录的机器上就是唯一一个）。
pub(crate) fn program_files_dir() -> Option<PathBuf> {
    program_files_dirs().into_iter().next()
}

/// 本地 AppData 目录（`FOLDERID_LocalAppData`），日志目录的根。
///
/// 不用 `%LOCALAPPDATA%`：环境变量可被启动环境改写，日志会写到别处。
#[cfg(windows)]
pub(crate) fn local_app_data_dir() -> Option<PathBuf> {
    use windows::Win32::UI::Shell::FOLDERID_LocalAppData;

    known_folder(&FOLDERID_LocalAppData)
}

#[cfg(not(windows))]
pub(crate) fn local_app_data_dir() -> Option<PathBuf> {
    None
}

/// 用 `ShellExecuteW` 打开一个目录（verb `open`，`lpFile` 直接给路径）。
///
/// 不走 `explorer.exe` 命令行：路径里的空格/引号不需要拼 shell 参数，
/// 也不会把用户目录当成命令行文本解释。返回 `HINSTANCE > 32` 才算成功。
#[cfg(windows)]
fn shell_execute_open(path: &Path) -> Result<(), ()> {
    use std::ffi::c_void;
    use std::os::windows::ffi::OsStrExt;

    #[link(name = "shell32")]
    extern "system" {
        fn ShellExecuteW(
            hwnd: *mut c_void,
            lp_operation: *const u16,
            lp_file: *const u16,
            lp_parameters: *const u16,
            lp_directory: *const u16,
            n_show_cmd: i32,
        ) -> *mut c_void;
    }

    let file: Vec<u16> = path
        .as_os_str()
        .encode_wide()
        .chain(std::iter::once(0))
        .collect();
    let verb: Vec<u16> = "open".encode_utf16().chain(std::iter::once(0)).collect();
    // SAFETY: 两个字符串都以 NUL 结尾并在调用期间存活；其余句柄/参数传空，
    // 返回值只是 HINSTANCE，不解引用。
    let result = unsafe {
        ShellExecuteW(
            std::ptr::null_mut(),
            verb.as_ptr(),
            file.as_ptr(),
            std::ptr::null(),
            std::ptr::null(),
            1, // SW_SHOWNORMAL
        )
    };
    if result as isize > 32 {
        Ok(())
    } else {
        Err(())
    }
}

/// 在专用 STA 线程里打开目录：线程内先 `CoInitializeEx`（APARTMENTTHREADED，
/// 关闭 OLE1DDE），`ShellExecuteW` 返回后 `CoUninitialize`。
///
/// 不借用调用方（阻塞 worker）的 COM 状态：worker 可能根本没初始化 COM，
/// 或已处于 MTA。专用线程结束即释放，调用方同步等结果。
#[cfg(windows)]
pub(crate) fn open_directory(path: &Path) -> Result<(), ()> {
    use std::ffi::c_void;

    // 直接用 ole32 的 ABI，不依赖 windows crate 里可选参数的类型细节。
    // `COINIT_APARTMENTTHREADED` = 0x2，`COINIT_DISABLE_OLE1DDE` = 0x4。
    #[link(name = "ole32")]
    extern "system" {
        fn CoInitializeEx(pv_reserved: *mut c_void, co_init: u32) -> i32;
        fn CoUninitialize();
    }
    const COINIT_APARTMENTTHREADED: u32 = 0x2;
    const COINIT_DISABLE_OLE1DDE: u32 = 0x4;

    let path = path.to_path_buf();
    let handle = std::thread::Builder::new()
        .name("vega-open-directory".to_string())
        .spawn(move || {
            // SAFETY: 新建线程尚未初始化 COM；保留参数必须为空。
            let initialized = unsafe {
                CoInitializeEx(
                    std::ptr::null_mut(),
                    COINIT_APARTMENTTHREADED | COINIT_DISABLE_OLE1DDE,
                )
            } >= 0;
            let result = shell_execute_open(&path);
            if initialized {
                // SAFETY: 只与上面成功的 CoInitializeEx 配对调用一次。
                unsafe { CoUninitialize() };
            }
            result
        })
        .map_err(|_| ())?;
    handle.join().unwrap_or(Err(()))
}

#[cfg(not(windows))]
pub(crate) fn open_directory(_path: &Path) -> Result<(), ()> {
    Err(())
}

/// `System32` 目录（`FOLDERID_System`）。
#[cfg(windows)]
pub(crate) fn system32_dir() -> Option<PathBuf> {
    use windows::Win32::UI::Shell::FOLDERID_System;

    known_folder(&FOLDERID_System)
}

#[cfg(not(windows))]
pub(crate) fn system32_dir() -> Option<PathBuf> {
    None
}

/// Windows 目录（`FOLDERID_Windows`），`explorer.exe` 在这里。
#[cfg(windows)]
pub(crate) fn windows_dir() -> Option<PathBuf> {
    use windows::Win32::UI::Shell::FOLDERID_Windows;

    known_folder(&FOLDERID_Windows)
}

#[cfg(not(windows))]
pub(crate) fn windows_dir() -> Option<PathBuf> {
    None
}

/// 去掉末尾的路径分隔符（卷根 `C:\` 归一成 `C:` 便于拼接比较）。
fn trim_separators(path: &str) -> &str {
    path.trim_end_matches(['\\', '/'])
}

/// 前缀匹配（Windows 路径前缀大小写不敏感；不在字符边界上就返回 `None`）。
fn strip_prefix_ignore_case<'a>(text: &'a str, prefix: &str) -> Option<&'a str> {
    let head = text.get(..prefix.len())?;
    head.eq_ignore_ascii_case(prefix)
        .then(|| &text[prefix.len()..])
}

/// 统一路径写法，只用于比较：
///
/// - 剥掉 `canonicalize` 加的 verbatim 前缀（`\\?\`）；
/// - `\\?\UNC\server\share` 还原成 `\\server\share`；
/// - 正斜杠统一成反斜杠；
/// - 去掉尾部反斜杠（卷根 `C:\` 归一成 `C:`）。
///
/// 大小写不敏感由比较方按需处理。`Program Files` 根校验与最终可执行文件
/// 校验都走这一个函数，不能各写一套。
fn normalize(path: &str) -> String {
    let stripped = if let Some(rest) = strip_prefix_ignore_case(path, r"\\?\UNC\") {
        format!(r"\\{rest}")
    } else if let Some(rest) = strip_prefix_ignore_case(path, r"\\?\") {
        rest.to_string()
    } else {
        path.to_string()
    };
    let unified = stripped.replace('/', "\\");
    trim_separators(&unified).to_string()
}

/// `Program Files` 根是否正好是 `<系统卷根>\Program Files` 或 `(x86)`。
///
/// 纯字符串比较：Windows 路径大小写不敏感；不做前缀匹配，`Program Files Evil`
/// 或更深一层的目录都不算根。
fn is_system_program_files_root(root: &Path, system_volume: &Path) -> bool {
    let (Some(root), Some(volume)) = (root.to_str(), system_volume.to_str()) else {
        return false;
    };
    // 两侧都走同一个 normalize：verbatim 前缀 / 正斜杠 / 尾部分隔符都不影响比较。
    let volume = normalize(volume);
    if volume.is_empty() {
        return false;
    }
    let root = normalize(root);
    ["Program Files", "Program Files (x86)"]
        .iter()
        .any(|name| root.eq_ignore_ascii_case(&format!("{volume}\\{name}")))
}

/// 两个卷根是否一致。Windows 路径不区分大小写；任一侧拿不到都算不一致。
fn same_volume_root(a: Option<PathBuf>, b: Option<PathBuf>) -> bool {
    match (a, b) {
        (Some(a), Some(b)) => {
            let (Some(a), Some(b)) = (a.to_str(), b.to_str()) else {
                return false;
            };
            // 最终可执行文件的卷根同样走 normalize：`\\?\C:\` 与 `C:\` 视为同一卷。
            normalize(a).eq_ignore_ascii_case(&normalize(b))
        }
        _ => false,
    }
}

/// 规范化目录所在的卷根（`GetVolumePathNameW`，形如 `C:\`）。
///
/// 拿不到就返回 `None`：调用方把「拿不到」当成「不在同一卷」，宁可不信任。
#[cfg(windows)]
fn volume_root(path: &Path) -> Option<PathBuf> {
    use std::os::windows::ffi::OsStrExt;
    use windows_sys::Win32::Storage::FileSystem::GetVolumePathNameW;

    let wide: Vec<u16> = path
        .as_os_str()
        .encode_wide()
        .chain(std::iter::once(0))
        .collect();
    let mut buffer = [0u16; 260];
    // SAFETY: `wide` 以 NUL 结尾，缓冲区长度按元素个数传入；返回非 0 才读缓冲。
    let ok = unsafe {
        GetVolumePathNameW(wide.as_ptr(), buffer.as_mut_ptr(), buffer.len() as u32)
    };
    if ok == 0 {
        return None;
    }
    let len = buffer.iter().position(|&c| c == 0).unwrap_or(buffer.len());
    if len == 0 {
        return None;
    }
    Some(PathBuf::from(String::from_utf16_lossy(&buffer[..len])))
}

#[cfg(not(windows))]
fn volume_root(_path: &Path) -> Option<PathBuf> {
    None
}

/// 系统盘根：`GetSystemDirectoryW`（`C:\Windows\System32`）所在卷的根（`C:\`）。
///
/// 拿不到就返回 `None`：调用方把「拿不到」当成「没有可信任的 Program Files」。
#[cfg(windows)]
fn system_volume_root() -> Option<PathBuf> {
    use windows_sys::Win32::System::SystemInformation::GetSystemDirectoryW;

    let mut buffer = [0u16; 260];
    // SAFETY: 缓冲区长度按元素个数传入；返回实际长度（不含结尾 NUL），
    // 只有落在这个范围内才读缓冲。
    let len = unsafe { GetSystemDirectoryW(buffer.as_mut_ptr(), buffer.len() as u32) };
    if len == 0 || len as usize >= buffer.len() {
        return None;
    }
    let dir = PathBuf::from(String::from_utf16_lossy(&buffer[..len as usize]));
    volume_root(&dir)
}

#[cfg(not(windows))]
fn system_volume_root() -> Option<PathBuf> {
    None
}

/// 路径自身是否带重解析点属性（junction / 符号链接 / 挂载点）。
///
/// 先验根再 canonicalize：否则 junction 在规范化后已经「看起来正常」。
/// 拿不到属性一律当重解析点，宁可不信任。
#[cfg(windows)]
fn is_reparse_point(path: &Path) -> bool {
    use std::os::windows::ffi::OsStrExt;
    use windows_sys::Win32::Storage::FileSystem::{
        GetFileAttributesW, FILE_ATTRIBUTE_REPARSE_POINT, INVALID_FILE_ATTRIBUTES,
    };

    let wide: Vec<u16> = path
        .as_os_str()
        .encode_wide()
        .chain(std::iter::once(0))
        .collect();
    // SAFETY: `wide` 以 NUL 结尾，API 只读该字符串。
    let attributes = unsafe { GetFileAttributesW(wide.as_ptr()) };
    if attributes == INVALID_FILE_ATTRIBUTES {
        return true;
    }
    attributes & FILE_ATTRIBUTE_REPARSE_POINT != 0
}

#[cfg(not(windows))]
fn is_reparse_point(_path: &Path) -> bool {
    // 非 Windows 上不做任何信任判断。
    true
}

/// 在受信任的 `Program Files` 根下找可执行文件：根由 `program_files_dirs`
/// 逐条验过（非重解析点、等于系统盘下的标准目录、同卷），这里再逐段拼接、
/// 规范化，确认最终文件仍在根内且仍在系统卷上，返回可直接启动的路径。
pub(crate) fn trusted_install_exe(parts: &[&str]) -> Option<PathBuf> {
    if parts.is_empty() {
        return None;
    }
    let system_volume = system_volume_root()?;
    for root in program_files_dirs() {
        let mut candidate = root.clone();
        for part in parts {
            candidate.push(part);
        }
        let Ok(full) = std::fs::canonicalize(&candidate) else {
            continue;
        };
        if is_inside(&root, &full)
            && full.is_file()
            && same_volume_root(volume_root(&full), Some(system_volume.clone()))
        {
            return Some(full);
        }
    }
    None
}

/// `System32` 下的固定系统工具（`tasklist.exe` 等）。
pub(crate) fn system32_exe(name: &str) -> Option<PathBuf> {
    let root = system32_dir()?;
    let full = std::fs::canonicalize(root.join(name)).ok()?;
    if is_inside(&root, &full) && full.is_file() {
        Some(full)
    } else {
        None
    }
}

/// 默认浏览器/资源管理器入口：`%WINDIR%\explorer.exe`，路径由 API 解析。
pub(crate) fn explorer_exe() -> Option<PathBuf> {
    let root = windows_dir()?;
    let full = std::fs::canonicalize(root.join("explorer.exe")).ok()?;
    if is_inside(&root, &full) && full.is_file() {
        Some(full)
    } else {
        None
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn containment_rejects_root_itself_and_siblings() {
        let root = Path::new("C:\\Program Files");
        assert!(is_inside(root, Path::new("C:\\Program Files\\RustDesk\\rustdesk.exe")));
        assert!(!is_inside(root, root));
        // 前缀相同但不是子目录，不能算包含。
        assert!(!is_inside(
            root,
            Path::new("C:\\Program Files Evil\\rustdesk.exe")
        ));
    }

    #[test]
    fn trusted_lookup_without_parts_returns_none() {
        assert!(trusted_install_exe(&[]).is_none());
    }

    #[test]
    fn volume_root_comparison_is_case_insensitive_and_strict() {
        let c = || Some(PathBuf::from("C:\\"));
        let d = || Some(PathBuf::from("D:\\"));
        assert!(same_volume_root(c(), c()));
        assert!(same_volume_root(
            Some(PathBuf::from("c:\\")),
            Some(PathBuf::from("C:\\"))
        ));
        assert!(!same_volume_root(c(), d()));
        // 拿不到卷根一律当不同卷：宁可不信任。
        assert!(!same_volume_root(None, c()));
        assert!(!same_volume_root(c(), None));
        assert!(!same_volume_root(None, None));
    }

    #[test]
    fn normalize_strips_verbatim_and_unifies_separators() {
        // 卷根、正斜杠、尾部反斜杠：都归一成同一种写法。
        assert_eq!(normalize(r"\\?\C:\"), "C:");
        assert_eq!(normalize(r"C:\"), "C:");
        assert_eq!(normalize("C:/"), "C:");
        assert_eq!(normalize(r"C:\Program Files\\"), r"C:\Program Files");
        // verbatim UNC 还原成普通 UNC，不留下 `UNC` 这一段。
        assert_eq!(normalize(r"\\?\UNC\server\share\"), r"\\server\share");
        // 大小写保留，比较时再忽略。
        assert_eq!(
            normalize(r"\\?\c:\program files\x\a.exe"),
            r"c:\program files\x\a.exe"
        );
    }

    #[test]
    fn verbatim_paths_compare_as_same_volume_and_inside_root() {
        // `\\?\C:\` 与 `C:\` 是同一个卷根。
        assert!(same_volume_root(
            Some(PathBuf::from(r"\\?\C:\")),
            Some(PathBuf::from(r"C:\"))
        ));
        assert!(same_volume_root(
            Some(PathBuf::from(r"\\?\c:\")),
            Some(PathBuf::from("C:/"))
        ));
        // 可执行文件带 verbatim 前缀、小写、正斜杠，仍判定在 `C:\Program Files` 下。
        assert!(is_inside(
            Path::new(r"C:\Program Files"),
            Path::new(r"\\?\c:\program files\x\a.exe")
        ));
        assert!(is_inside(
            Path::new(r"\\?\C:\Program Files\"),
            Path::new("C:/Program Files/x/a.exe")
        ));
        // 前缀相近的兄弟目录不能算在里面。
        assert!(!is_inside(
            Path::new(r"C:\Program Files"),
            Path::new(r"\\?\c:\program files evil\a.exe")
        ));
    }

    #[test]
    fn program_files_root_must_equal_system_drive_standard_dirs() {
        let system = Path::new("C:\\");
        assert!(is_system_program_files_root(
            Path::new("C:\\Program Files"),
            system
        ));
        // 大小写不敏感，末尾分隔符不影响。
        assert!(is_system_program_files_root(
            Path::new("c:\\program files (x86)\\"),
            system
        ));
        // 系统卷根写成不带反斜杠也要能拼出同样的根。
        assert!(is_system_program_files_root(
            Path::new("C:\\Program Files"),
            Path::new("C:")
        ));
        // canonicalize 返回的 verbatim 前缀不影响比较。
        assert!(is_system_program_files_root(
            Path::new("\\\\?\\C:\\Program Files"),
            system
        ));
        // 别的卷、前缀相近、更深一层、伪造的 (x64) 都不算根。
        assert!(!is_system_program_files_root(
            Path::new("D:\\Program Files"),
            system
        ));
        assert!(!is_system_program_files_root(
            Path::new("C:\\Program Files Evil"),
            system
        ));
        assert!(!is_system_program_files_root(
            Path::new("C:\\Program Files\\RustDesk"),
            system
        ));
        assert!(!is_system_program_files_root(
            Path::new("C:\\Program Files (x86) (x64)"),
            system
        ));
        // 卷根为空 / 非 UTF-8 可用路径：一律不信任。
        assert!(!is_system_program_files_root(
            Path::new("C:\\Program Files"),
            Path::new("")
        ));
        assert!(!is_system_program_files_root(
            Path::new("Program Files"),
            system
        ));
    }

    #[cfg(not(windows))]
    #[test]
    fn reparse_points_are_untrusted_off_windows() {
        // 非 Windows 没有卷/属性 API：一律不认为根可信。
        assert!(is_reparse_point(Path::new("C:\\Program Files")));
        assert!(system_volume_root().is_none());
    }

    #[cfg(not(windows))]
    #[test]
    fn non_windows_resolves_nothing() {
        assert!(program_files_dirs().is_empty());
        assert!(program_files_dir().is_none());
        assert!(system32_dir().is_none());
        assert!(windows_dir().is_none());
        assert!(system32_exe("tasklist.exe").is_none());
        assert!(explorer_exe().is_none());
        assert!(trusted_install_exe(&["RustDesk", "rustdesk.exe"]).is_none());
    }

    #[cfg(not(windows))]
    #[test]
    fn opening_a_directory_fails_off_windows() {
        // 非 Windows 不加载 shell32/COM：直接返回错误，不 pretend 成功。
        assert!(open_directory(Path::new("C:\\Vega\\logs")).is_err());
    }
}
