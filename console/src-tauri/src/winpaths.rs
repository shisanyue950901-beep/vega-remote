//! Windows 已知文件夹与受信任可执行文件解析（M2c 审计修复）。
//!
//! 审计 P1/P2 的根因是拿环境变量拼路径：`PathBuf::from("C:").join("Program Files")`
//! 得到的是盘符相对路径 `C:Program Files`，`%ProgramFiles%`、`%SystemRoot%`、`PATH`
//! 又都能被启动环境改写。这里统一改成：
//!
//! - 目录一律由 `SHGetKnownFolderPath` 取（`FOLDERID_ProgramFiles`、
//!   `FOLDERID_ProgramFilesX86`、`FOLDERID_System`、`FOLDERID_Windows`）；
//! - 目录与可执行文件都先 `canonicalize`，再确认最终路径仍在对应根目录下；
//! - 调用方拿到的就是校验通过的那条路径，启动时不再二次解析；
//! - 非 Windows 一律返回 `None`，不加载任何系统 API。
//!
//! 不读环境变量、不做 `C:\` 拼接、不搜索 `PATH`。

use std::path::{Path, PathBuf};

/// 候选文件是否仍在根目录内（软链接已由 `canonicalize` 展开后比较）。
fn is_inside(root: &Path, candidate: &Path) -> bool {
    candidate != root && candidate.starts_with(root)
}

/// 把已知文件夹解析成规范化目录；目录不存在或拿不到就返回 `None`。
#[cfg(windows)]
fn known_folder(id: &windows::core::GUID) -> Option<PathBuf> {
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
        let dir = std::fs::canonicalize(PathBuf::from(text)).ok()?;
        dir.is_dir().then_some(dir)
    }
}

/// 系统 `Program Files` 与 `Program Files (x86)`（规范化、去重、顺序固定）。
#[cfg(windows)]
pub(crate) fn program_files_dirs() -> Vec<PathBuf> {
    use windows::Win32::UI::Shell::{FOLDERID_ProgramFiles, FOLDERID_ProgramFilesX86};

    let mut roots: Vec<PathBuf> = Vec::new();
    for id in [&FOLDERID_ProgramFiles, &FOLDERID_ProgramFilesX86] {
        if let Some(dir) = known_folder(id) {
            if !roots.contains(&dir) {
                roots.push(dir);
            }
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

/// 两个卷根是否一致。Windows 路径不区分大小写；任一侧拿不到都算不一致。
fn same_volume_root(a: Option<PathBuf>, b: Option<PathBuf>) -> bool {
    match (a, b) {
        (Some(a), Some(b)) => a
            .as_os_str()
            .to_string_lossy()
            .eq_ignore_ascii_case(&b.as_os_str().to_string_lossy()),
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

/// `Program Files` 根是否和系统目录在同一个卷（比较卷根，不比较整条路径）。
///
/// 只靠 `starts_with` 不够：Program Files 可以被重定向到别的卷/挂载点，
/// 那时「在 Program Files 下」就不再等于「系统自己装的程序」。
fn program_files_on_system_volume(root: &Path) -> bool {
    same_volume_root(volume_root(root), system32_dir().as_deref().and_then(volume_root))
}

/// 在受信任的 `Program Files` 根下找可执行文件：逐个根独立校验
/// （根与系统目录同卷）、逐段拼接、规范化，最后确认规范化后的路径仍在
/// 根目录内，返回的就是可以直接启动的路径。
pub(crate) fn trusted_install_exe(parts: &[&str]) -> Option<PathBuf> {
    if parts.is_empty() {
        return None;
    }
    for root in program_files_dirs() {
        // 不同卷的「Program Files」不是受信任根：直接跳过这个根。
        if !program_files_on_system_volume(&root) {
            continue;
        }
        let mut candidate = root.clone();
        for part in parts {
            candidate.push(part);
        }
        let Ok(full) = std::fs::canonicalize(&candidate) else {
            continue;
        };
        if is_inside(&root, &full) && full.is_file() {
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

    #[cfg(not(windows))]
    #[test]
    fn program_files_volume_check_rejects_everything_off_windows() {
        assert!(!program_files_on_system_volume(Path::new(
            "C:\\Program Files"
        )));
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
}
