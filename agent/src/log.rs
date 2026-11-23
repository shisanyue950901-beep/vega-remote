//! `%ProgramData%\Vega\logs\agent.log`：只记事件，不记访问码。
//!
//! 日志永远是非关键路径：目录建不出来或写失败都只影响可观测性，不会让服务退出。

use std::io::Write;
use std::path::PathBuf;
use std::sync::atomic::{AtomicBool, Ordering};
use std::time::{SystemTime, UNIX_EPOCH};

const LOG_FILE: &str = "agent.log";

static CONSOLE: AtomicBool = AtomicBool::new(false);

pub fn set_console(enabled: bool) {
    CONSOLE.store(enabled, Ordering::Relaxed);
}

fn log_path() -> PathBuf {
    crate::state::logs_dir().join(LOG_FILE)
}

/// 建日志目录并套用与状态目录相同的 DACL。
pub fn init() {
    let dir = crate::state::logs_dir();
    if std::fs::create_dir_all(&dir).is_err() {
        return;
    }
    #[cfg(windows)]
    {
        let _ = crate::winutil::set_path_dacl(&dir, crate::state::DIR_SDDL);
        let file = log_path();
        if file.is_file() {
            let _ = crate::winutil::set_path_dacl(&file, crate::state::DIR_SDDL);
        }
    }
}

/// 追加一条事件。消息由调用方拼好；调用方必须保证其中不含访问码。
pub fn event(message: &str) {
    let line = format!("[{}] {}\n", timestamp(), message);
    if CONSOLE.load(Ordering::Relaxed) {
        eprint!("{line}");
    }
    let path = log_path();
    if let Some(parent) = path.parent() {
        if std::fs::create_dir_all(parent).is_err() {
            return;
        }
    }
    match std::fs::OpenOptions::new()
        .create(true)
        .append(true)
        .open(&path)
    {
        Ok(mut file) => {
            let _ = file.write_all(line.as_bytes());
        }
        Err(_) => {}
    }
}

fn timestamp() -> String {
    let secs = match SystemTime::now().duration_since(UNIX_EPOCH) {
        Ok(duration) => duration.as_secs() as i64,
        Err(_) => 0,
    };
    let days = secs.div_euclid(86_400);
    let rest = secs.rem_euclid(86_400);
    let (year, month, day) = civil_from_days(days);
    format!(
        "{year:04}-{month:02}-{day:02} {:02}:{:02}:{:02}",
        rest / 3600,
        (rest % 3600) / 60,
        rest % 60
    )
}

/// Howard Hinnant 的 civil_from_days，避免引入 chrono 只为一行时间戳。
fn civil_from_days(days: i64) -> (i64, u32, u32) {
    let z = days + 719_468;
    let era = if z >= 0 { z } else { z - 146_096 } / 146_097;
    let doe = z - era * 146_097;
    let yoe = (doe - doe / 1_460 + doe / 36_524 - doe / 146_096) / 365;
    let y = yoe + era * 400;
    let doy = doe - (365 * yoe + yoe / 4 - yoe / 100);
    let mp = (5 * doy + 2) / 153;
    let d = doy - (153 * mp + 2) / 5 + 1;
    let m = mp + if mp < 10 { 3 } else { -9 };
    let year = if m <= 2 { y + 1 } else { y };
    (year, m as u32, d as u32)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn epoch_formats_as_utc() {
        assert_eq!(timestamp_for(0), "1970-01-01 00:00:00");
        assert_eq!(timestamp_for(1_700_000_000), "2023-11-14 22:13:20");
    }

    fn timestamp_for(secs: i64) -> String {
        let days = secs.div_euclid(86_400);
        let rest = secs.rem_euclid(86_400);
        let (year, month, day) = civil_from_days(days);
        format!(
            "{year:04}-{month:02}-{day:02} {:02}:{:02}:{:02}",
            rest / 3600,
            (rest % 3600) / 60,
            rest % 60
        )
    }
}
