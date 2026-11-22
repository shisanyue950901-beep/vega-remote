//! 设备别名与「删除本地记录」。
//!
//! 纯文件操作：别名存在 `recent-ids.json` 同目录的 `aliases.json`，键是规范化
//! 后的设备码。删除设备只动本地记录，不联系对方、不调用 RustDesk，非 Windows 也能跑。

use std::collections::BTreeMap;
use std::path::{Path, PathBuf};

use crate::rustdesk::{self, OpResult};

const ALIAS_FILE: &str = "aliases.json";
const ALIAS_MAX_CHARS: usize = 32;
const PEER_MIN_DIGITS: usize = 6;
const PEER_MAX_DIGITS: usize = 16;
const PEER_ID_ERROR: &str = "设备码需为 6-16 位数字";

pub(crate) fn aliases_path(recent: &Path) -> PathBuf {
    match recent.parent() {
        Some(dir) => dir.join(ALIAS_FILE),
        None => PathBuf::from(ALIAS_FILE),
    }
}

/// 设备码：纯数字 6-16 位；带分组写法（9/10 位）复用 rustdesk 的校验。
pub(crate) fn normalize_peer_id(raw: &str) -> Result<String, String> {
    let value = raw.trim();
    if value.chars().all(|c| c.is_ascii_digit()) {
        return if (PEER_MIN_DIGITS..=PEER_MAX_DIGITS).contains(&value.len()) {
            Ok(value.to_string())
        } else {
            Err(PEER_ID_ERROR.into())
        };
    }
    rustdesk::parse_peer_id(value).map_err(|_| PEER_ID_ERROR.to_string())
}

pub(crate) fn normalize_alias(raw: &str) -> Result<String, String> {
    let cleaned: String = raw.chars().filter(|c| !c.is_control()).collect();
    let value = cleaned.trim();
    let len = value.chars().count();
    if len == 0 || len > ALIAS_MAX_CHARS {
        return Err(format!("别名需为 1-{ALIAS_MAX_CHARS} 个字符"));
    }
    Ok(value.to_string())
}

pub(crate) fn read_aliases_at(path: &Path) -> BTreeMap<String, String> {
    let Ok(text) = std::fs::read_to_string(path) else {
        return BTreeMap::new();
    };
    let Ok(raw) = serde_json::from_str::<BTreeMap<String, String>>(&text) else {
        return BTreeMap::new();
    };
    raw.into_iter()
        .filter_map(|(id, alias)| Some((normalize_peer_id(&id).ok()?, normalize_alias(&alias).ok()?)))
        .collect()
}

pub(crate) fn write_aliases_at(path: &Path, aliases: &BTreeMap<String, String>) -> Result<(), String> {
    let text = serde_json::to_string_pretty(aliases).map_err(|e| format!("序列化别名失败：{e}"))?;
    rustdesk::write_atomic(path, &text)
}

pub(crate) fn set_alias_at(path: &Path, peer_id: &str, alias: &str) -> Result<bool, String> {
    let id = normalize_peer_id(peer_id)?;
    let mut aliases = read_aliases_at(path);
    let stripped: String = alias.chars().filter(|c| !c.is_control()).collect();
    if stripped.trim().is_empty() {
        if aliases.remove(&id).is_some() {
            write_aliases_at(path, &aliases)?;
        }
        return Ok(false);
    }
    aliases.insert(id, normalize_alias(alias)?);
    write_aliases_at(path, &aliases)?;
    Ok(true)
}

pub(crate) fn write_recent_at(path: &Path, list: &[String]) -> Result<(), String> {
    let payload = serde_json::json!({ "ids": list });
    let text =
        serde_json::to_string_pretty(&payload).map_err(|e| format!("序列化最近设备码失败：{e}"))?;
    rustdesk::write_atomic(path, &text)
}
/// 删除本地记录：先删别名，再写 recent。
///
/// 别名残留是无害的（下次改名会覆盖、列表里也不会再出现），recent 残留则会让
/// 设备在「最近连接」里再次显示，所以把易失败的那一步放前面：别名写失败直接
/// 返回、recent 保持原样；recent 写失败则明确告知别名已移除、需要重试。
/// 不做跨实例锁（见 ROADMAP「T4 加固」）。
pub(crate) fn remove_peer_at(recent: &Path, aliases: &Path, peer_id: &str) -> Result<bool, String> {
    let id = normalize_peer_id(peer_id)?;
    let mut map = read_aliases_at(aliases);
    let alias_removed = map.remove(&id).is_some();
    if alias_removed {
        write_aliases_at(aliases, &map)
            .map_err(|e| format!("移除本地别名失败，最近记录未改动：{e}"))?;
    }
    let mut list = rustdesk::read_recent_peers_at(recent);
    let before = list.len();
    list.retain(|entry| entry != &id);
    let recent_removed = list.len() != before;
    if recent_removed {
        write_recent_at(recent, &list)
            .map_err(|e| format!("写入最近设备记录失败（别名已移除，请重试）：{e}"))?;
    }
    Ok(alias_removed || recent_removed)
}
fn aliases_for_app(app: &tauri::AppHandle) -> Result<PathBuf, String> {
    Ok(aliases_path(&rustdesk::recent_path(app)?))
}

#[tauri::command]
pub fn get_peer_aliases(app: tauri::AppHandle) -> BTreeMap<String, String> {
    match aliases_for_app(&app) {
        Ok(aliases) => read_aliases_at(&aliases),
        Err(_) => BTreeMap::new(),
    }
}

#[tauri::command]
pub fn set_peer_alias(peer_id: String, alias: String, app: tauri::AppHandle) -> OpResult {
    let aliases = match aliases_for_app(&app) {
        Ok(path) => path,
        Err(e) => return OpResult::err(e),
    };
    match set_alias_at(&aliases, &peer_id, &alias) {
        Ok(true) => OpResult::ok("别名已保存"),
        Ok(false) => OpResult::ok("别名已删除"),
        Err(e) => OpResult::err(e),
    }
}

#[tauri::command]
pub fn remove_peer(peer_id: String, app: tauri::AppHandle) -> OpResult {
    let recent = match rustdesk::recent_path(&app) {
        Ok(path) => path,
        Err(e) => return OpResult::err(e),
    };
    match remove_peer_at(&recent, &aliases_path(&recent), &peer_id) {
        Ok(true) => OpResult::ok("已从本地记录中移除该设备"),
        Ok(false) => OpResult::err("本地记录里没有这个设备码"),
        Err(e) => OpResult::err(e),
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::sync::atomic::{AtomicU16, Ordering};
    static SEQ: AtomicU16 = AtomicU16::new(0);
    fn temp_dir(tag: &str) -> PathBuf {
        let n = SEQ.fetch_add(1, Ordering::Relaxed);
        let dir = std::env::temp_dir()
            .join(format!("vega-peers-{tag}-{}-{n}", std::process::id()));
        std::fs::create_dir_all(&dir).unwrap();
        dir
    }
    #[test]
    fn peer_id_accepts_6_to_16_digits() {
        assert_eq!(normalize_peer_id("123456").unwrap(), "123456");
        assert_eq!(normalize_peer_id("1234567890").unwrap(), "1234567890");
        assert_eq!(normalize_peer_id("123 456 789").unwrap(), "123456789");
        assert_eq!(normalize_peer_id("1234567890123456").unwrap(), "1234567890123456");
        for bad in ["12345", "12345678901234567", "12a456", "", "123-45"] {
            assert!(normalize_peer_id(bad).is_err(), "{bad} 应被拒绝");
        }
    }
    #[test]
    fn alias_is_trimmed_and_control_free() {
        assert_eq!(normalize_alias("  客厅\t电脑 ").unwrap(), "客厅电脑");
        assert!(normalize_alias("   ").is_err());
        assert!(normalize_alias(&"a".repeat(ALIAS_MAX_CHARS)).is_ok());
        assert!(normalize_alias(&"a".repeat(ALIAS_MAX_CHARS + 1)).is_err());
    }
    #[test]
    fn corrupted_json_reads_as_empty() {
        let dir = temp_dir("corrupt");
        let path = dir.join(ALIAS_FILE);
        std::fs::write(&path, "{not json").unwrap();
        assert!(read_aliases_at(&path).is_empty());
        assert!(read_aliases_at(&dir.join("missing.json")).is_empty());
        let _ = std::fs::remove_dir_all(&dir);
    }
    #[test]
    fn atomic_write_round_trip() {
        let dir = temp_dir("roundtrip");
        let aliases = dir.join(ALIAS_FILE);
        assert!(set_alias_at(&aliases, "123456789", "书房").unwrap());
        assert_eq!(read_aliases_at(&aliases).get("123456789").map(String::as_str), Some("书房"));
        assert_eq!(std::fs::read_dir(&dir).unwrap().count(), 1, "不应留下临时文件");
        assert!(!set_alias_at(&aliases, "123456789", "   ").unwrap());
        assert!(read_aliases_at(&aliases).is_empty());
        let _ = std::fs::remove_dir_all(&dir);
    }
    #[test]
    fn remove_peer_with_only_alias_succeeds() {
        let dir = temp_dir("alias-only");
        let recent = dir.join("recent-ids.json");
        let aliases = dir.join(ALIAS_FILE);
        set_alias_at(&aliases, "123456789", "只剩别名").unwrap();
        assert!(remove_peer_at(&recent, &aliases, "123456789").unwrap());
        assert!(read_aliases_at(&aliases).is_empty());
        let _ = std::fs::remove_dir_all(&dir);
    }
    #[test]
    fn remove_peer_drops_recent_and_alias() {
        let dir = temp_dir("remove");
        let recent = dir.join("recent-ids.json");
        let aliases = dir.join(ALIAS_FILE);
        write_recent_at(&recent, &["123456789".to_string(), "987654321".to_string()]).unwrap();
        set_alias_at(&aliases, "123456789", "旧机器").unwrap();
        assert!(remove_peer_at(&recent, &aliases, "123456789").unwrap());
        assert_eq!(rustdesk::read_recent_peers_at(&recent), vec!["987654321".to_string()]);
        assert!(read_aliases_at(&aliases).is_empty());
        assert!(!remove_peer_at(&recent, &aliases, "123456789").unwrap());
        let _ = std::fs::remove_dir_all(&dir);
    }
}
