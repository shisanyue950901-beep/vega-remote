//! `%ProgramData%\Vega\agent\state.json` 的读写与目录 ACL。
//!
//! 状态文件是访问码的唯一权威来源：`{code, mode, updated}`。写入走
//! 「临时文件 + MoveFileExW(REPLACE_EXISTING | WRITE_THROUGH)」，避免断电或
//! 崩溃留下半截 JSON。目录 DACL 只给 SYSTEM 与 Administrators，并带 OICI
//! 继承，后续新建的状态文件自动继承同一权限。

use serde::{Deserialize, Serialize};
use std::path::PathBuf;
use std::time::{SystemTime, UNIX_EPOCH};

/// 目录 SDDL：受保护 DACL，SYSTEM / Administrators 完全控制，子项继承。
pub const DIR_SDDL: &str = "D:PAI(A;OICI;FA;;;SY)(A;OICI;FA;;;BA)";

const STATE_FILE: &str = "state.json";

#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum Mode {
    Rotate,
    Fixed,
}

#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub struct State {
    pub code: String,
    pub mode: Mode,
    pub updated: i64,
}

impl State {
    pub fn new_rotate() -> Result<Self, String> {
        Ok(Self {
            code: crate::code::generate_rotate()?,
            mode: Mode::Rotate,
            updated: now(),
        })
    }

    pub fn new_fixed(code: &str) -> Result<Self, String> {
        crate::code::validate_fixed(code)?;
        Ok(Self {
            code: code.to_string(),
            mode: Mode::Fixed,
            updated: now(),
        })
    }

    pub fn mode_name(&self) -> &'static str {
        match self.mode {
            Mode::Rotate => "rotate",
            Mode::Fixed => "fixed",
        }
    }

    pub fn is_valid(&self) -> bool {
        match self.mode {
            Mode::Rotate => crate::code::is_rotate_code(&self.code),
            Mode::Fixed => crate::code::validate_fixed(&self.code).is_ok(),
        }
    }
}

pub fn now() -> i64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|d| d.as_secs() as i64)
        .unwrap_or(0)
}

/// `%ProgramData%`；SYSTEM 服务一定有该变量，拿不到时退回系统盘默认路径。
pub fn program_data() -> PathBuf {
    match std::env::var_os("ProgramData") {
        Some(value) if !value.is_empty() => PathBuf::from(value),
        _ => PathBuf::from(r"C:\ProgramData"),
    }
}

pub fn agent_dir() -> PathBuf {
    program_data().join("Vega").join("agent")
}

pub fn logs_dir() -> PathBuf {
    program_data().join("Vega").join("logs")
}

pub fn state_path() -> PathBuf {
    agent_dir().join(STATE_FILE)
}

/// 建目录并收紧 DACL；已存在的 state.json 也补一次 DACL。
pub fn ensure_agent_dir() -> Result<(), String> {
    let dir = agent_dir();
    std::fs::create_dir_all(&dir).map_err(|e| format!("创建状态目录失败：{e}"))?;
    #[cfg(windows)]
    {
        crate::winutil::set_path_dacl(&dir, DIR_SDDL)?;
        let file = state_path();
        if file.is_file() {
            crate::winutil::set_path_dacl(&file, DIR_SDDL)?;
        }
    }
    Ok(())
}

/// 读状态；文件不存在返回 `Ok(None)`，JSON 损坏或字段非法返回中文错误。
pub fn load() -> Result<Option<State>, String> {
    let path = state_path();
    let text = match std::fs::read_to_string(&path) {
        Ok(text) => text,
        Err(err) if err.kind() == std::io::ErrorKind::NotFound => return Ok(None),
        Err(err) => return Err(format!("读取状态文件失败：{err}")),
    };
    let state: State = serde_json::from_str(&text).map_err(|_| "状态文件格式无效".to_string())?;
    Ok(Some(state))
}

/// 原子写状态文件。
pub fn save(state: &State) -> Result<(), String> {
    ensure_agent_dir()?;
    let path = state_path();
    let temp = agent_dir().join(format!("state.json.tmp-{}", std::process::id()));
    let text = serde_json::to_string(state).map_err(|_| "状态序列化失败".to_string())?;
    std::fs::write(&temp, text.as_bytes()).map_err(|e| format!("写入状态文件失败：{e}"))?;
    #[cfg(windows)]
    {
        if let Err(err) = replace_file(&temp, &path) {
            let _ = std::fs::remove_file(&temp);
            return Err(err);
        }
    }
    #[cfg(not(windows))]
    {
        if let Err(err) = std::fs::rename(&temp, &path) {
            let _ = std::fs::remove_file(&temp);
            return Err(format!("替换状态文件失败：{err}"));
        }
    }
    Ok(())
}

#[cfg(windows)]
fn replace_file(from: &std::path::Path, to: &std::path::Path) -> Result<(), String> {
    use windows_sys::Win32::Storage::FileSystem::{MoveFileExW, MOVEFILE_REPLACE_EXISTING, MOVEFILE_WRITE_THROUGH};
    let from = crate::winutil::wide_path(from);
    let to = crate::winutil::wide_path(to);
    // SAFETY: 两个路径都以 NUL 结尾且在调用期间存活。
    let ok = unsafe {
        MoveFileExW(
            from.as_ptr(),
            to.as_ptr(),
            MOVEFILE_REPLACE_EXISTING | MOVEFILE_WRITE_THROUGH,
        )
    };
    if ok == 0 {
        return Err("替换状态文件失败".to_string());
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn rotate_state_is_valid() {
        let state = match State::new_rotate() {
            Ok(state) => state,
            Err(err) => panic!("生成失败：{err}"),
        };
        assert!(state.is_valid());
        assert_eq!(state.mode_name(), "rotate");
    }

    #[test]
    fn fixed_state_validates_input() {
        let state = match State::new_fixed("Abc123") {
            Ok(state) => state,
            Err(err) => panic!("校验失败：{err}"),
        };
        assert_eq!(state.code, "Abc123");
        assert_eq!(state.mode_name(), "fixed");
        assert!(State::new_fixed("123").is_err());
        assert!(State::new_fixed("有中文").is_err());
    }

    #[test]
    fn state_json_shape_matches_contract() {
        let state = State {
            code: "482916".to_string(),
            mode: Mode::Rotate,
            updated: 1_700_000_000,
        };
        let text = match serde_json::to_string(&state) {
            Ok(text) => text,
            Err(err) => panic!("序列化失败：{err}"),
        };
        assert_eq!(
            text,
            r#"{"code":"482916","mode":"rotate","updated":1700000000}"#
        );
        let back: State = match serde_json::from_str(&text) {
            Ok(back) => back,
            Err(err) => panic!("反序列化失败：{err}"),
        };
        assert_eq!(back, state);
    }

    #[test]
    fn invalid_rotate_code_is_rejected() {
        let state = State {
            code: "12a456".to_string(),
            mode: Mode::Rotate,
            updated: 0,
        };
        assert!(!state.is_valid());
    }
}
