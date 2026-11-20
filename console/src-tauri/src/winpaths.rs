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

/// 在受信任的 `Program Files` 根下找可执行文件：逐段拼接、规范化，
/// 最后确认规范化后的路径仍在根目录内，返回的就是可以直接启动的路径。
pub(crate) fn trusted_install_exe(parts: &[&str]) -> Option<PathBuf> {
    if parts.is_empty() {
        return None;
    }
    for root in program_files_dirs() {
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
