//! rotate 模式的会话结束轮换。
//!
//! 设计上希望识别命令行含 `--cm` 的 rustdesk.exe；CreateToolhelp32Snapshot 只给
//! 进程名，读命令行需要 NtQueryInformationProcess 之类的重活。这里按设计允许的
//! 近似实现：服务启动时记录 rustdesk.exe 进程数作为基线，之后每 2 秒采样一次，
//! 数量高于基线视为「连接管理窗口在运行（会话中）」，从高于基线回落到基线时触发
//! 一次轮换。采样失败不轮换，避免把枚举错误当成会话结束。

use std::sync::Arc;
use std::time::Duration;

use crate::Agent;

/// 轮换状态机的两个相位。
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum SessionPhase {
    Idle,
    Active,
}

/// 纯逻辑：根据上一相位、基线与当前进程数算出下一相位，以及是否触发轮换。
///
/// 只在 Active → Idle 的下降沿触发；Idle 状态下的抖动不会产生重复轮换。
pub fn next_phase(phase: SessionPhase, baseline: usize, current: usize) -> (SessionPhase, bool) {
    let active = current > baseline;
    let next = if active {
        SessionPhase::Active
    } else {
        SessionPhase::Idle
    };
    let rotate = phase == SessionPhase::Active && next == SessionPhase::Idle;
    (next, rotate)
}

pub fn start(agent: Arc<Agent>) {
    std::thread::spawn(move || monitor(agent));
}

fn monitor(agent: Arc<Agent>) {
    let baseline = match count_rustdesk() {
        Some(count) => count,
        None => {
            crate::log::event("会话检测初始化失败，本次运行不自动轮换访问码");
            return;
        }
    };
    crate::log::event(&format!("会话检测已启动，rustdesk 进程基线 {baseline}"));
    let mut phase = SessionPhase::Idle;
    loop {
        std::thread::sleep(Duration::from_secs(2));
        let Some(current) = count_rustdesk() else {
            continue;
        };
        let (next, rotate) = next_phase(phase, baseline, current);
        if rotate {
            match agent.rotate_after_session() {
                Ok(Some(_)) => crate::log::event("会话结束，已轮换访问码"),
                Ok(None) => {}
                Err(err) => crate::log::event(&format!("会话结束轮换失败：{err}")),
            }
        }
        phase = next;
    }
}

#[cfg(windows)]
fn count_rustdesk() -> Option<usize> {
    use std::mem::size_of;
    use windows_sys::Win32::Foundation::{CloseHandle, INVALID_HANDLE_VALUE};
    use windows_sys::Win32::System::Diagnostics::ToolHelp::{
        CreateToolhelp32Snapshot, Process32FirstW, Process32NextW, PROCESSENTRY32W,
        TH32CS_SNAPPROCESS,
    };

    // SAFETY: 快照句柄在返回前关闭；PROCESSENTRY32W 按 API 要求填 dwSize。
    unsafe {
        let snapshot = CreateToolhelp32Snapshot(TH32CS_SNAPPROCESS, 0);
        if snapshot == INVALID_HANDLE_VALUE {
            return None;
        }
        let mut entry: PROCESSENTRY32W = std::mem::zeroed();
        entry.dwSize = size_of::<PROCESSENTRY32W>() as u32;
        let mut count = 0usize;
        let mut ok = Process32FirstW(snapshot, &mut entry);
        while ok != 0 {
            let end = entry
                .szExeFile
                .iter()
                .position(|unit| *unit == 0)
                .unwrap_or(entry.szExeFile.len());
            let name = String::from_utf16_lossy(&entry.szExeFile[..end]);
            if name.eq_ignore_ascii_case("rustdesk.exe") {
                count += 1;
            }
            ok = Process32NextW(snapshot, &mut entry);
        }
        CloseHandle(snapshot);
        Some(count)
    }
}

#[cfg(not(windows))]
fn count_rustdesk() -> Option<usize> {
    None
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn rising_edge_enters_session_without_rotation() {
        let (next, rotate) = next_phase(SessionPhase::Idle, 1, 2);
        assert_eq!(next, SessionPhase::Active);
        assert!(!rotate);
    }

    #[test]
    fn falling_edge_rotates_once() {
        let (next, rotate) = next_phase(SessionPhase::Active, 1, 1);
        assert_eq!(next, SessionPhase::Idle);
        assert!(rotate);

        let (next, rotate) = next_phase(SessionPhase::Idle, 1, 1);
        assert_eq!(next, SessionPhase::Idle);
        assert!(!rotate);
    }

    #[test]
    fn staying_active_does_not_rotate() {
        let (next, rotate) = next_phase(SessionPhase::Active, 1, 3);
        assert_eq!(next, SessionPhase::Active);
        assert!(!rotate);
    }

    #[test]
    fn baseline_zero_treats_any_rustdesk_as_session() {
        let (next, rotate) = next_phase(SessionPhase::Idle, 0, 1);
        assert_eq!(next, SessionPhase::Active);
        assert!(!rotate);
        let (next, rotate) = next_phase(SessionPhase::Active, 0, 0);
        assert_eq!(next, SessionPhase::Idle);
        assert!(rotate);
    }

    #[test]
    fn below_baseline_is_idle() {
        let (next, rotate) = next_phase(SessionPhase::Idle, 3, 2);
        assert_eq!(next, SessionPhase::Idle);
        assert!(!rotate);
    }
}
