//! 设置 → 诊断（M2c）：有界 doctor + 脱敏日志导出。
//!
//! doctor 只做本地检查：服务状态、文件是否存在、本机 TCP 连接、UDP 路由选择。
//! 所有网络探测共用 8 秒总预算；结果里不放地址、主机名、用户名或用户目录路径。
//! 导出日志再统一做一次脱敏，然后交给资源管理器打开目录。

use std::io::Write;
use std::net::{IpAddr, Ipv6Addr, SocketAddr, TcpStream, UdpSocket};
use std::path::PathBuf;
use std::sync::atomic::{AtomicBool, AtomicU64, Ordering};
use std::sync::{Arc, Mutex};
use std::time::{Duration, Instant, SystemTime, UNIX_EPOCH};

use serde::Serialize;

use crate::rustdesk::{
    explorer_exe, get_server_config, locate_rustdesk, probe_server_with_timeout, spawn_detached,
};
use crate::scm::{query_service_state, ServiceState};
use crate::streaming::{moonlight_exe, tailscale_installed};

const DOCTOR_BUDGET: Duration = Duration::from_secs(8);
const SUNSHINE_SERVICE: &str = "SunshineService";
const SUNSHINE_PORT: u16 = 47990;
const TCP_PROBE_TIMEOUT: Duration = Duration::from_secs(1);

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
enum DoctorStatus {
    Pass,
    Warn,
    Fail,
}

impl DoctorStatus {
    fn label(self) -> &'static str {
        match self {
            DoctorStatus::Pass => "通过",
            DoctorStatus::Warn => "警告",
            DoctorStatus::Fail => "失败",
        }
    }
}

#[derive(Clone, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct DoctorItem {
    pub item: String,
    pub status: String,
    pub advice: String,
}

fn item(name: &str, status: DoctorStatus, advice: &str) -> DoctorItem {
    DoctorItem {
        item: name.to_string(),
        status: status.label().to_string(),
        advice: advice.to_string(),
    }
}

fn remaining(deadline: Instant) -> Duration {
    deadline.saturating_duration_since(Instant::now())
}

/// 本次诊断是否已经过期：deadline 到点，或被 IPC 层超时置了取消标志。
///
/// worker 在开始前和每个探测前都查一次；过期就立即退出，不再占并发闸门。
fn expired(deadline: Instant, cancel: &AtomicBool) -> bool {
    cancel.load(Ordering::Acquire) || Instant::now() >= deadline
}

/* ------------------------------------------------------------------ */
/* 单项检查（纯函数带单测）                                              */
/* ------------------------------------------------------------------ */

/// 47990 可达性与 Sunshine 服务状态的关系。
///
/// 只有「Sunshine 服务在运行 **且** 47990 可连」才算通过：任何程序都能
/// 在 47990 上监听，单看端口只会把别的进程认成 Sunshine（审计 P2）。
fn port_47990_status(reachable: bool, sunshine: ServiceState) -> (DoctorStatus, &'static str) {
    if reachable && sunshine == ServiceState::Running {
        return (DoctorStatus::Pass, "Sunshine 服务运行中，本机管理页可访问");
    }
    if reachable {
        return (
            DoctorStatus::Warn,
            "47990 有进程监听，但 Sunshine 服务未运行，确认是否被其他程序占用",
        );
    }
    match sunshine {
        ServiceState::Running => (
            DoctorStatus::Fail,
            "Sunshine 正在运行但 47990 不可访问，检查防火墙或重启 Sunshine",
        ),
        ServiceState::Stopped => (
            DoctorStatus::Warn,
            "Sunshine 未运行，启动后再检查 47990",
        ),
        ServiceState::NotInstalled => (
            DoctorStatus::Warn,
            "未安装 Sunshine，串流前先安装/修复",
        ),
        ServiceState::Unknown => (
            DoctorStatus::Warn,
            "无法确认 Sunshine 服务状态，请以管理员身份检查服务",
        ),
    }
}

fn is_global_unicast(ip: &Ipv6Addr) -> bool {
    // 2000::/3：前三位是 001。
    (ip.segments()[0] & 0xE000) == 0x2000
}

/// 绑定 [::]:0 并 connect 一个全球单播地址，只看本地选中的源地址；
/// UDP connect 不发包。
fn has_global_ipv6() -> bool {
    let Ok(socket) = UdpSocket::bind("[::]:0") else {
        return false;
    };
    if socket.connect("2001:4860:4860::8888:53").is_err() {
        return false;
    }
    match socket.local_addr() {
        Ok(SocketAddr::V6(addr)) => is_global_unicast(addr.ip()),
        _ => false,
    }
}

fn probe_local_port(port: u16, timeout: Duration) -> bool {
    if timeout.is_zero() {
        return false;
    }
    let addr = SocketAddr::from(([127, 0, 0, 1], port));
    TcpStream::connect_timeout(&addr, timeout).is_ok()
}

/* ------------------------------------------------------------------ */
/* doctor 主流程                                                        */
/* ------------------------------------------------------------------ */

/// `None` 表示本次诊断已过期（deadline 到点或被取消），结果不能当快照。
fn doctor_items(deadline: Instant, cancel: &AtomicBool) -> Option<Vec<DoctorItem>> {
    let mut items = Vec::new();
    if expired(deadline, cancel) {
        return None;
    }

    let rustdesk_installed = locate_rustdesk().is_some();
    items.push(if rustdesk_installed {
        item("RustDesk", DoctorStatus::Pass, "")
    } else {
        item(
            "RustDesk",
            DoctorStatus::Fail,
            "从 RustDesk 官方发行页手动安装后重新运行 doctor",
        )
    });

    // RustDesk ID 服务器：复用现有 TCP 探测，最多 3 秒，并受总预算约束。
    if expired(deadline, cancel) {
        return None;
    }
    if !rustdesk_installed {
        items.push(item(
            "RustDesk ID 服务器",
            DoctorStatus::Warn,
            "未安装 RustDesk，跳过服务器连通性检查",
        ));
    } else {
        let config = get_server_config();
        if config.server.trim().is_empty() {
            items.push(item(
                "RustDesk ID 服务器",
                DoctorStatus::Warn,
                "在 RustDesk 的 设置 → 网络 中填写 ID 服务器",
            ));
        } else {
            let budget = remaining(deadline).min(Duration::from_secs(3));
            let result = probe_server_with_timeout(&config.server, budget);
            items.push(if result.ok {
                item("RustDesk ID 服务器", DoctorStatus::Pass, "")
            } else {
                item(
                    "RustDesk ID 服务器",
                    DoctorStatus::Fail,
                    "检查 RustDesk 设置 → 网络 中的服务器地址与本机网络",
                )
            });
        }
    }

    if expired(deadline, cancel) {
        return None;
    }
    let sunshine = query_service_state(SUNSHINE_SERVICE);
    items.push(match sunshine {
        ServiceState::Running => item("Sunshine 服务", DoctorStatus::Pass, ""),
        ServiceState::Stopped => item(
            "Sunshine 服务",
            DoctorStatus::Warn,
            "Sunshine 已停止，启动服务或打开 Sunshine 设置",
        ),
        ServiceState::NotInstalled => item(
            "Sunshine 服务",
            DoctorStatus::Fail,
            "未安装 Sunshine，使用串流页的「安装/修复 Sunshine」",
        ),
        ServiceState::Unknown => item(
            "Sunshine 服务",
            DoctorStatus::Fail,
            "无法查询 Sunshine 服务，请以管理员身份检查服务状态",
        ),
    });

    if expired(deadline, cancel) {
        return None;
    }
    let port_reachable = probe_local_port(SUNSHINE_PORT, remaining(deadline).min(TCP_PROBE_TIMEOUT));
    let (port_status, port_advice) = port_47990_status(port_reachable, sunshine);
    items.push(item("Sunshine 管理页 47990", port_status, port_advice));

    if expired(deadline, cancel) {
        return None;
    }
    items.push(if has_global_ipv6() {
        item("公网 IPv6", DoctorStatus::Pass, "")
    } else {
        item(
            "公网 IPv6",
            DoctorStatus::Warn,
            "未检测到公网 IPv6，可改用 Tailscale 组网",
        )
    });

    if expired(deadline, cancel) {
        return None;
    }
    items.push(if tailscale_installed() {
        item("Tailscale", DoctorStatus::Pass, "")
    } else {
        item(
            "Tailscale",
            DoctorStatus::Warn,
            "未安装 Tailscale；没有 IPv6 直连时建议安装",
        )
    });

    if expired(deadline, cancel) {
        return None;
    }
    items.push(match moonlight_exe() {
        Ok(Some(_)) => item("Moonlight", DoctorStatus::Pass, ""),
        Ok(None) => item(
            "Moonlight",
            DoctorStatus::Warn,
            "未安装 Moonlight，使用串流页的「安装 Moonlight」",
        ),
        Err(error) => item("Moonlight", DoctorStatus::Warn, &error),
    });

    Some(items)
}

/// doctor 并发闸门：同一时间只允许一个诊断在跑。
static DOCTOR_RUNNING: AtomicBool = AtomicBool::new(false);

/// worker 退出（正常、panic 或被丢弃）时清闸门。
struct DoctorGuard;

impl Drop for DoctorGuard {
    fn drop(&mut self) {
        DOCTOR_RUNNING.store(false, Ordering::Release);
    }
}

fn busy_items() -> Vec<DoctorItem> {
    vec![item(
        "诊断",
        DoctorStatus::Warn,
        "已有诊断在进行中，请等待本次结果",
    )]
}

fn timeout_items() -> Vec<DoctorItem> {
    vec![item(
        "诊断",
        DoctorStatus::Fail,
        "诊断超时（8 秒），请稍后重试",
    )]
}

fn worker_failed_items() -> Vec<DoctorItem> {
    vec![item("诊断", DoctorStatus::Fail, "诊断线程失败，请重试")]
}

/// 一次诊断的结局：只有 `Done` 才是「完成的快照」，其余都不进缓存。
enum DiagnoseOutcome {
    Done(Vec<DoctorItem>),
    Busy,
    Timeout,
    WorkerFailed,
}

impl DiagnoseOutcome {
    fn into_items(self) -> Vec<DoctorItem> {
        match self {
            DiagnoseOutcome::Done(items) => items,
            DiagnoseOutcome::Busy => busy_items(),
            DiagnoseOutcome::Timeout => timeout_items(),
            DiagnoseOutcome::WorkerFailed => worker_failed_items(),
        }
    }
}

/// worker 内部结局：闸门在闭包里取，只有 worker 真正退出才释放。
enum WorkerOutcome {
    Done(Vec<DoctorItem>),
    Busy,
    Cancelled,
    Panicked,
}

/// 一次完整诊断，在阻塞线程里跑。
///
/// 并发闸门放在闭包内部：IPC 层 `timeout` 提前返回时 worker 可能还在跑，
/// 这时继续拒绝第二次诊断，直到它真正退出（guard 随闭包一起 drop）。
fn diagnose_worker(deadline: Instant, cancel: Arc<AtomicBool>) -> WorkerOutcome {
    // 排队期间就已经过期/被取消：不取闸门，直接退出。
    if expired(deadline, &cancel) {
        return WorkerOutcome::Cancelled;
    }
    // 第二个并发调用直接返回，不再排队等一次完整诊断。
    if DOCTOR_RUNNING
        .compare_exchange(false, true, Ordering::AcqRel, Ordering::Acquire)
        .is_err()
    {
        return WorkerOutcome::Busy;
    }
    let _guard = DoctorGuard;
    // 取到闸门后再查一次：等闸门期间过期就立即退出，guard 随作用域释放。
    if expired(deadline, &cancel) {
        return WorkerOutcome::Cancelled;
    }
    match std::panic::catch_unwind(std::panic::AssertUnwindSafe(|| {
        doctor_items(deadline, &cancel)
    })) {
        Ok(Some(items)) => WorkerOutcome::Done(items),
        Ok(None) => WorkerOutcome::Cancelled,
        Err(_) => WorkerOutcome::Panicked,
    }
}

/// deadline 的剩余预算；调用方在命令入口就建好 deadline，不再各算一份。
fn doctor_remaining(deadline: Instant) -> Duration {
    deadline.saturating_duration_since(Instant::now())
}

/// 唯一的诊断路径：`run_doctor` 与导出的兜底都走这里。
///
/// deadline 由 IPC 命令入口传入（`Instant::now() + DOCTOR_BUDGET`），
/// `tokio::time::timeout` 只用它的剩余预算等待阻塞线程，超时不杀 worker。
async fn await_diagnosis(deadline: Instant) -> DiagnoseOutcome {
    let budget = doctor_remaining(deadline);
    if budget.is_zero() {
        return DiagnoseOutcome::Timeout;
    }
    // 取消标志交给 worker：IPC 层超时后置位，排队中的 worker 不会再启动占闸门。
    let cancel = Arc::new(AtomicBool::new(false));
    let worker_cancel = Arc::clone(&cancel);
    let join =
        tauri::async_runtime::spawn_blocking(move || diagnose_worker(deadline, worker_cancel));
    match tokio::time::timeout(budget, join).await {
        Ok(Ok(WorkerOutcome::Done(items))) => DiagnoseOutcome::Done(items),
        Ok(Ok(WorkerOutcome::Busy)) => DiagnoseOutcome::Busy,
        Ok(Ok(WorkerOutcome::Cancelled)) => DiagnoseOutcome::Timeout,
        Ok(Ok(WorkerOutcome::Panicked)) | Ok(Err(_)) => DiagnoseOutcome::WorkerFailed,
        Err(_) => {
            // 超时不是终态：通知 worker 尽快收手，它退出时才释放闸门。
            cancel.store(true, Ordering::Release);
            DiagnoseOutcome::Timeout
        }
    }
}

/// 一次诊断的快照：`id` 每次诊断递增，前端据此确认导出的是屏幕上那次结果。
struct Snapshot {
    id: u64,
    items: Vec<DoctorItem>,
}

static NEXT_SNAPSHOT_ID: AtomicU64 = AtomicU64::new(0);

/// 最近一次「完成」的诊断快照；`None` 表示「本次无快照」（超时/忙/线程失败）。
static LAST_SNAPSHOT: Mutex<Option<Snapshot>> = Mutex::new(None);

fn next_snapshot_id() -> u64 {
    NEXT_SNAPSHOT_ID.fetch_add(1, Ordering::AcqRel) + 1
}

fn store_snapshot(snapshot_id: u64, items: &[DoctorItem]) {
    if let Ok(mut guard) = LAST_SNAPSHOT.lock() {
        *guard = Some(Snapshot {
            id: snapshot_id,
            items: items.to_vec(),
        });
    }
}

/// 本次没拿到结果：旧快照一并作废，前端不能拿上一次的结果去导出。
fn clear_snapshot() {
    if let Ok(mut guard) = LAST_SNAPSHOT.lock() {
        *guard = None;
    }
}

fn matching_snapshot(snapshot_id: u64) -> Option<Vec<DoctorItem>> {
    LAST_SNAPSHOT.lock().ok().and_then(|guard| {
        guard
            .as_ref()
            .filter(|snapshot| snapshot.id == snapshot_id)
            .map(|snapshot| snapshot.items.clone())
    })
}

/// `run_doctor` 的返回值：结果 + 本次快照编号 + 本次是否真的产出了快照。
#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
pub struct DoctorReport {
    pub snapshot_id: u64,
    pub snapshot_available: bool,
    pub items: Vec<DoctorItem>,
}

#[tauri::command]
pub async fn run_doctor() -> DoctorReport {
    // 8 秒总预算从命令入口开始算：排队、spawn、调度都吃掉同一份预算。
    let deadline = Instant::now() + DOCTOR_BUDGET;
    let snapshot_id = next_snapshot_id();
    let outcome = await_diagnosis(deadline).await;
    let snapshot_available = match &outcome {
        DiagnoseOutcome::Done(items) => {
            store_snapshot(snapshot_id, items);
            true
        }
        // 超时也占一个递增 id，但登记「本次无快照」。
        _ => {
            clear_snapshot();
            false
        }
    };
    DoctorReport {
        snapshot_id,
        snapshot_available,
        items: outcome.into_items(),
    }
}

/* ------------------------------------------------------------------ */
/* 脱敏 + 导出                                                          */
/* ------------------------------------------------------------------ */

/// 在原始字符串上找 needle，只折叠 ASCII 大小写。
///
/// 命中位置一定落在 char 边界：只有单字节 ASCII 会被折叠，多字节序列必须
/// 逐字节相同，所以不会出现「用小写副本的字节偏移去切原串、切出半个字符」。
fn find_ascii_case_insensitive(haystack: &str, needle: &str, from: usize) -> Option<usize> {
    if needle.is_empty() || from >= haystack.len() {
        return None;
    }
    let hay = haystack.as_bytes();
    let pattern = needle.as_bytes();
    if pattern.len() > hay.len() {
        return None;
    }
    let mut index = from;
    while index + pattern.len() <= hay.len() {
        if haystack.is_char_boundary(index)
            && hay[index..index + pattern.len()]
                .iter()
                .zip(pattern)
                .all(|(a, b)| a.eq_ignore_ascii_case(b))
        {
            return Some(index);
        }
        index += 1;
    }
    None
}

fn replace_case_insensitive(text: &str, needle: &str, replacement: &str) -> String {
    if needle.len() < 2 {
        return text.to_string();
    }
    let mut result = String::with_capacity(text.len());
    let mut cursor = 0usize;
    // 在原串上找、在原串上切：不用小写化副本的偏移，非 ASCII 行也不会切坏。
    while let Some(start) = find_ascii_case_insensitive(text, needle, cursor) {
        result.push_str(&text[cursor..start]);
        result.push_str(replacement);
        // 命中区间与 needle 等长（ASCII 折叠不改变字节数）。
        cursor = start + needle.len();
    }
    result.push_str(&text[cursor..]);
    result
}

fn looks_like_hostname(core: &str) -> bool {
    if !core.contains('.') || core.starts_with('.') || core.ends_with('.') {
        return false;
    }
    if core.chars().all(|c| c.is_ascii_digit() || c == '.') {
        return false;
    }
    let labels: Vec<&str> = core.split('.').collect();
    if labels.len() < 2 {
        return false;
    }
    labels.iter().all(|label| {
        !label.is_empty()
            && label
                .chars()
                .all(|c| c.is_ascii_alphanumeric() || c == '-' || c == '_')
    }) && labels
        .last()
        .map(|label| {
            label.len() >= 2 && label.chars().all(|c| c.is_ascii_alphabetic())
        })
        .unwrap_or(false)
}

/// 端点两侧可能粘着标点：`(1.2.3.4)`、`[1.2.3.4]:21116,`、`"relay=…"`。
/// 这些字符先原样记下来，脱敏后再接回去。
fn is_wrapper(c: char) -> bool {
    matches!(
        c,
        '(' | ')' | '[' | ']' | '{' | '}' | '"' | '\'' | '<' | '>' | ',' | ';' | ':' | '='
    )
}

/// 冒号不是普通包裹标点：IPv6 的 `::`/`::1` 用冒号收尾（`(2001:db8::)`）。
/// 先按这一组剥一层，地址才认得出来；剥不干净再退回 `is_wrapper`。
fn is_wrapper_without_colon(c: char) -> bool {
    is_wrapper(c) && c != ':'
}

/// 剥掉首尾包裹标点，返回 (前缀, 主体, 后缀)。主体为空表示整串都是标点。
fn peel_with(token: &str, is_padding: fn(char) -> bool) -> (&str, &str, &str) {
    let leading = token
        .char_indices()
        .find(|&(_, c)| !is_padding(c))
        .map(|(index, _)| index)
        .unwrap_or(token.len());
    let rest = &token[leading..];
    let trailing_index = rest
        .char_indices()
        .rev()
        .find(|&(_, c)| !is_padding(c))
        .map(|(index, c)| index + c.len_utf8())
        .unwrap_or(0);
    (&token[..leading], &rest[..trailing_index], &rest[trailing_index..])
}

fn peel_wrapping(token: &str) -> (&str, &str, &str) {
    peel_with(token, is_wrapper)
}

/// 保留尾部冒号的剥离：`(2001:db8::)` 的主体必须是 `2001:db8::`。
fn peel_wrapping_keep_colons(token: &str) -> (&str, &str, &str) {
    peel_with(token, is_wrapper_without_colon)
}

/// 赋值前缀：`relay=`、`key:`、`server =`（token 内无空格，所以只剩前两种）。
///
/// IPv6 地址本身含冒号（`2001:db8::1`），因此这里只认「像标识符的左半段」，
/// 且调用方还要确认剥掉前缀后确实认出了地址/主机，才会保留前缀。
fn split_assignment(core: &str) -> Option<(&str, &str)> {
    let index = core.find(['=', ':'])?;
    let prefix = &core[..index];
    if prefix.is_empty() || prefix.len() > 32 {
        return None;
    }
    let mut chars = prefix.chars();
    match chars.next() {
        Some(c) if c.is_ascii_alphabetic() || c == '_' => {}
        _ => return None,
    }
    if !chars.all(|c| c.is_ascii_alphanumeric() || c == '_' || c == '-') {
        return None;
    }
    // 纯数字左半段是地址的一部分（`2001:…`），不能当键名。
    if prefix.chars().all(|c| c.is_ascii_digit()) {
        return None;
    }
    Some((&core[..index + 1], &core[index + 1..]))
}

/// 把 token 当 IP 解析：先整串 `SocketAddr`，再拆掉括号/端口后按 `IpAddr`。
///
/// 端点可能写成 `1.2.3.4:21116`、`[2001:db8::1]:21117`，也可能只剩
/// `2001:db8::1]:21117`（开头括号被剥掉）。这几种都要认出来，不能因为一个
/// 残留的 `]` 就漏掉地址。
fn ip_from_token(token: &str) -> Option<IpAddr> {
    if let Ok(addr) = token.parse::<IpAddr>() {
        return Some(addr);
    }
    if let Ok(endpoint) = token.parse::<SocketAddr>() {
        return Some(endpoint.ip());
    }
    let bare = token.trim_matches(|c| c == '[' || c == ']');
    if let Ok(addr) = bare.parse::<IpAddr>() {
        return Some(addr);
    }
    let (host, port) = token.rsplit_once(':')?;
    if host.is_empty() || !port.chars().all(|c| c.is_ascii_digit()) {
        return None;
    }
    let host = host.trim_matches(|c| matches!(c, '[' | ']' | '(' | ')'));
    host.parse::<IpAddr>().ok()
}

fn mask_core(core: &str) -> String {
    if core.is_empty() {
        return String::new();
    }
    if core.contains('@') {
        return "<email>".to_string();
    }
    if ip_from_token(core).is_some() {
        return "<ip>".to_string();
    }
    // host:port（主机名）
    if let Some((host, port)) = core.rsplit_once(':') {
        if port.chars().all(|c| c.is_ascii_digit()) && !host.is_empty() {
            let host = host.trim_matches(|c| c == '[' || c == ']');
            if looks_like_hostname(host) {
                return "<host>".to_string();
            }
        }
    }
    if core.contains('\\') || core.contains('/') {
        return "<path>".to_string();
    }
    if looks_like_hostname(core) {
        return "<host>".to_string();
    }
    core.to_string()
}

/// 对单个 token 脱敏：先整体识别；不行再剥赋值前缀；最后剥包裹标点。
/// 三层都认不出来时原样返回（普通版本号、状态文字不能被动到）。
fn redact_core(core: &str) -> String {
    if core.is_empty() {
        return String::new();
    }
    let direct = mask_core(core);
    if direct != core {
        return direct;
    }
    if let Some((prefix, rest)) = split_assignment(core) {
        if !rest.is_empty() {
            let inner = redact_core(rest);
            if inner != rest {
                return format!("{prefix}{inner}");
            }
        }
    }
    // 先按「保留冒号」剥：`(2001:db8::)` 的 `::` 是地址本体，不是包裹标点。
    let (leading, middle, trailing) = peel_wrapping_keep_colons(core);
    if middle.len() != core.len() && !middle.is_empty() {
        let inner = redact_core(middle);
        if inner != middle {
            return format!("{leading}{inner}{trailing}");
        }
    }
    // 再按通用标点剥：`[1.2.3.4]:21116,` 这类残留冒号的情况。
    let (leading, middle, trailing) = peel_wrapping(core);
    if middle.len() != core.len() && !middle.is_empty() {
        let inner = redact_core(middle);
        if inner != middle {
            return format!("{leading}{inner}{trailing}");
        }
    }
    core.to_string()
}

fn redact_token(token: &str) -> String {
    redact_core(token)
}

/// 脱敏要用的身份字段：由调用方显式传入，测试用固定夹具。
///
/// 生产入口只在 `export_blocking` 里读一次环境变量（`from_env`），
/// 脱敏函数本身不再碰环境，测试结果不随运行者的 USERNAME 变化。
#[derive(Default)]
struct RedactionIdentity {
    profile: Option<String>,
    user: Option<String>,
    computer: Option<String>,
    domain: Option<String>,
}

impl RedactionIdentity {
    /// 生产入口：唯一读环境变量的地方。
    fn from_env() -> Self {
        fn var(key: &str) -> Option<String> {
            std::env::var(key)
                .ok()
                .filter(|value| !value.trim().is_empty())
        }
        Self {
            profile: var("USERPROFILE"),
            user: var("USERNAME"),
            computer: var("COMPUTERNAME"),
            domain: var("USERDOMAIN"),
        }
    }

    #[cfg(test)]
    fn fixture(profile: Option<&str>) -> Self {
        Self {
            profile: profile.map(str::to_string),
            user: Some("alice".to_string()),
            computer: Some("DESKTOP-7Q2".to_string()),
            domain: Some("WORKGROUP".to_string()),
        }
    }
}

fn redact_with(input: &str, identity: &RedactionIdentity) -> String {
    let mut text = input.to_string();
    if let Some(profile) = identity.profile.as_deref() {
        if profile.len() >= 3 {
            text = replace_case_insensitive(&text, profile, "<profile>");
        }
    }
    for value in [&identity.user, &identity.computer, &identity.domain]
        .into_iter()
        .flatten()
    {
        if value.len() >= 2 {
            text = replace_case_insensitive(&text, value, "<已隐藏>");
        }
    }
    text.split_whitespace()
        .map(redact_token)
        .collect::<Vec<_>>()
        .join(" ")
}

fn redact_text(input: &str, identity: &RedactionIdentity) -> String {
    redact_with(input, identity)
}

#[cfg(windows)]
fn windows_build() -> String {
    use windows_sys::Win32::System::Registry::{RegGetValueW, HKEY_LOCAL_MACHINE, RRF_RT_REG_SZ};

    let subkey: Vec<u16> = "SOFTWARE\\Microsoft\\Windows NT\\CurrentVersion"
        .encode_utf16()
        .chain(std::iter::once(0))
        .collect();
    let value: Vec<u16> = "CurrentBuild"
        .encode_utf16()
        .chain(std::iter::once(0))
        .collect();
    let mut buffer = [0u16; 64];
    let mut size = (buffer.len() * std::mem::size_of::<u16>()) as u32;
    // SAFETY: 缓冲区长度按字节传入，API 只写入该范围内。
    let status = unsafe {
        RegGetValueW(
            HKEY_LOCAL_MACHINE,
            subkey.as_ptr(),
            value.as_ptr(),
            RRF_RT_REG_SZ,
            std::ptr::null_mut(),
            buffer.as_mut_ptr() as *mut std::ffi::c_void,
            &mut size,
        )
    };
    if status != 0 {
        return "unknown".to_string();
    }
    let length = buffer.iter().position(|c| *c == 0).unwrap_or(buffer.len());
    String::from_utf16_lossy(&buffer[..length])
}

#[cfg(not(windows))]
fn windows_build() -> String {
    "unknown".to_string()
}

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
struct DoctorLog {
    app_version: String,
    windows_build: String,
    generated_at: u64,
    items: Vec<DoctorItem>,
}

fn log_directory() -> PathBuf {
    let root = std::env::var_os("LOCALAPPDATA")
        .map(PathBuf::from)
        .unwrap_or_else(std::env::temp_dir);
    root.join("Vega").join("logs")
}

/// 导出没有匹配快照时的通用错误：不区分「id 不匹配」和「本次无快照」。
const SNAPSHOT_MISMATCH: &str = "没有与当前诊断结果匹配的快照，请重新诊断后再导出";

/// 只取与前端当前显示一致的快照。
///
/// - id 匹配：直接返回（导出不再重跑任何探测）。
/// - 诊断还在跑（前端按钮此时是禁用的）：最多等到命令入口那个 deadline。
/// - 不匹配 / 本次无快照：立刻返回 `None`，由调用方转成通用错误。
fn snapshot_for(snapshot_id: u64, deadline: Instant) -> Option<Vec<DoctorItem>> {
    loop {
        if let Some(items) = matching_snapshot(snapshot_id) {
            return Some(items);
        }
        let budget = doctor_remaining(deadline);
        if !DOCTOR_RUNNING.load(Ordering::Acquire) || budget.is_zero() {
            return None;
        }
        std::thread::sleep(budget.min(Duration::from_millis(25)));
    }
}

fn export_blocking(deadline: Instant, snapshot_id: u64) -> Result<(), String> {
    let Some(items) = snapshot_for(snapshot_id, deadline) else {
        return Err(SNAPSHOT_MISMATCH.to_string());
    };
    // 身份只在生产入口读一次，随后整份日志共用同一份夹具。
    let identity = RedactionIdentity::from_env();
    let redacted: Vec<DoctorItem> = items
        .into_iter()
        .map(|entry| DoctorItem {
            item: redact_text(&entry.item, &identity),
            status: redact_text(&entry.status, &identity),
            advice: redact_text(&entry.advice, &identity),
        })
        .collect();
    let now = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|duration| duration.as_secs())
        .unwrap_or(0);
    let log = DoctorLog {
        app_version: env!("CARGO_PKG_VERSION").to_string(),
        windows_build: windows_build(),
        generated_at: now,
        items: redacted,
    };
    let json = serde_json::to_string_pretty(&log)
        .map_err(|_| "生成脱敏日志失败".to_string())?;

    let directory = log_directory();
    std::fs::create_dir_all(&directory)
        .map_err(|_| "创建日志目录失败".to_string())?;
    let path = directory.join(format!("doctor-{now}.json"));
    let mut file = std::fs::File::create(&path)
        .map_err(|_| "写入脱敏日志失败".to_string())?;
    file.write_all(json.as_bytes())
        .map_err(|_| "写入脱敏日志失败".to_string())?;
    file.write_all(b"\n")
        .map_err(|_| "写入脱敏日志失败".to_string())?;

    if cfg!(windows) {
        let directory_text = directory.display().to_string();
        let Some(explorer) = explorer_exe() else {
            return Err("日志已导出，但打开目录失败".to_string());
        };
        spawn_detached(&explorer, &[directory_text.as_str()])
            .map_err(|_| "日志已导出，但打开目录失败".to_string())?;
    }
    Ok(())
}

#[tauri::command]
pub async fn export_doctor_log(snapshot_id: u64) -> crate::rustdesk::OpResult {
    // 与 `run_doctor` 一样，8 秒预算从命令入口开始算；导出本身最多等到同一
    // 个 deadline，不会因为等快照而挂住前端。
    let deadline = Instant::now() + DOCTOR_BUDGET;
    let budget = doctor_remaining(deadline);
    if budget.is_zero() {
        return crate::rustdesk::OpResult {
            ok: false,
            message: SNAPSHOT_MISMATCH.to_string(),
        };
    }
    let join = tauri::async_runtime::spawn_blocking(move || export_blocking(deadline, snapshot_id));
    let result = match tokio::time::timeout(budget, join).await {
        Ok(Ok(result)) => result,
        Ok(Err(_)) | Err(_) => Err("导出脱敏日志失败".to_string()),
    };
    match result {
        Ok(()) => crate::rustdesk::OpResult {
            ok: true,
            message: "脱敏日志已导出并打开所在目录".to_string(),
        },
        Err(message) => crate::rustdesk::OpResult { ok: false, message },
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn doctor_status_labels_are_chinese() {
        assert_eq!(DoctorStatus::Pass.label(), "通过");
        assert_eq!(DoctorStatus::Warn.label(), "警告");
        assert_eq!(DoctorStatus::Fail.label(), "失败");
    }

    #[test]
    fn port_47990_mapping_depends_on_sunshine_state() {
        // 只有「服务运行中 + 端口可连」才算通过；端口被别人监听只给警告。
        assert_eq!(
            port_47990_status(true, ServiceState::Running).0,
            DoctorStatus::Pass
        );
        assert_eq!(
            port_47990_status(true, ServiceState::NotInstalled).0,
            DoctorStatus::Warn
        );
        assert_eq!(
            port_47990_status(true, ServiceState::Stopped).0,
            DoctorStatus::Warn
        );
        assert_eq!(
            port_47990_status(false, ServiceState::Running).0,
            DoctorStatus::Fail
        );
        assert_eq!(
            port_47990_status(false, ServiceState::Stopped).0,
            DoctorStatus::Warn
        );
        assert_eq!(
            port_47990_status(false, ServiceState::Unknown).0,
            DoctorStatus::Warn
        );
    }

    #[test]
    fn ipv6_global_unicast_check_only_accepts_2000_slash_3() {
        assert!(is_global_unicast(&"2001:4860:4860::8888".parse().unwrap()));
        assert!(is_global_unicast(&"2a00:1450::1".parse().unwrap()));
        assert!(!is_global_unicast(&"fe80::1".parse().unwrap()));
        assert!(!is_global_unicast(&"fd00::1".parse().unwrap()));
        assert!(!is_global_unicast(&"::1".parse().unwrap()));
    }

    #[test]
    fn redaction_masks_addresses_hostnames_and_paths() {
        let input = "IPv4 192.168.1.20 IPv6 2001:4860:4860::8888 host pc.example.com profile C:\\Users\\alice file C:\\Users\\alice\\AppData\\x.log";
        let output = redact_with(input, &RedactionIdentity::fixture(Some("C:\\Users\\alice")));
        assert!(!output.contains("192.168.1.20"));
        assert!(!output.contains("2001:4860"));
        assert!(!output.contains("pc.example.com"));
        assert!(!output.contains("alice"));
        assert!(output.contains("<ip>"));
        assert!(output.contains("<host>"));
        assert!(output.contains("<profile>"));
        assert!(output.contains("<path>"));
    }

    #[test]
    fn ip_detection_accepts_socket_addrs_and_bracket_leftovers() {
        assert_eq!(ip_from_token("192.0.2.1:21116"), Some("192.0.2.1".parse().unwrap()));
        assert_eq!(
            ip_from_token("[2001:db8::1]:21117"),
            Some("2001:db8::1".parse().unwrap())
        );
        // 剥掉开头的 `[` 后只剩 "…]:port"，残留的 `]` 不能挡住识别。
        assert_eq!(
            ip_from_token("2001:db8::1]:21117"),
            Some("2001:db8::1".parse().unwrap())
        );
        assert_eq!(ip_from_token("2001:db8::1"), Some("2001:db8::1".parse().unwrap()));
        assert_eq!(ip_from_token("pc.example.com:21116"), None);
    }

    #[test]
    fn redaction_masks_endpoint_after_punctuation_split() {
        // 审计复现场景：方括号 IPv6 端点在任何标点组合下都不能原样留下。
        for input in [
            "[2001:db8::1]:21117",
            "relay=[2001:db8::1]:21117",
            "2001:db8::1]:21117",
            "(2001:db8::1)",
        ] {
            let output = redact_with(input, &RedactionIdentity::default());
            assert!(!output.contains("2001:db8"), "{input} -> {output}");
            assert!(output.contains("<ip>"), "{input} -> {output}");
        }
        // 赋值前缀与包裹标点要原样保留，只换掉地址本体。
        let comma = redact_with("relay=[2001:db8::1]:21117,", &RedactionIdentity::default());
        assert!(!comma.contains("2001:db8"), "{comma}");
        assert!(comma.starts_with("relay="), "{comma}");
        assert!(comma.ends_with(','), "{comma}");
        assert_eq!(redact_with("(2001:db8::1)", &RedactionIdentity::default()), "(<ip>)");
        assert_eq!(redact_with("key:1.2.3.4", &RedactionIdentity::default()), "key:<ip>");
    }

    #[test]
    fn redaction_keeps_key_name_but_masks_host_value() {
        // `key:` 是键名不是地址；冒号不能被当成 IPv6 分隔符。
        assert_eq!(redact_with("key:pc.example.com", &RedactionIdentity::default()), "key:<host>");
        assert_eq!(redact_with("fe80::1", &RedactionIdentity::default()), "<ip>");
    }

    #[test]
    fn redaction_masks_ipv6_ending_with_double_colon() {
        // `::` 是 IPv6 本体，不能当包裹标点剥掉：`(2001:db8::)` 必须认成地址。
        assert_eq!(redact_with("(2001:db8::)", &RedactionIdentity::default()), "(<ip>)");
        assert_eq!(redact_with("(2001:db8::),", &RedactionIdentity::default()), "(<ip>),");
        assert_eq!(
            redact_with("(2001:db8::) 🚀 192.168.1.5", &RedactionIdentity::default()),
            "(<ip>) 🚀 <ip>"
        );
    }

    #[test]
    fn non_ascii_lines_redact_without_panicking() {
        // 中文 + emoji：大小写替换和标点剥离都不能按字节切坏原串。
        let output = redact_with(
            "用户目录 C:\\Users\\ALICE 🚀 192.168.1.5",
            &RedactionIdentity::fixture(Some("c:\\users\\alice")),
        );
        assert!(output.contains("<profile>"), "{output}");
        assert!(!output.contains("ALICE"), "{output}");
        assert!(output.contains("🚀"), "{output}");
        assert!(output.contains("<ip>"), "{output}");

        let mixed = redact_with("状态 🚀 (2001:db8::) 完成 ✓", &RedactionIdentity::default());
        assert!(mixed.contains("🚀"), "{mixed}");
        assert!(mixed.contains("✓"), "{mixed}");
        assert!(!mixed.contains("2001:db8"), "{mixed}");
        assert!(mixed.contains("<ip>"), "{mixed}");
    }

    #[test]
    fn redaction_uses_explicit_identity_not_environment() {
        // 夹具固定：结果与运行者的 USERNAME / COMPUTERNAME 无关。
        let identity = RedactionIdentity::fixture(Some("D:\\Home\\alice"));
        let output = redact_with(
            "user alice host DESKTOP-7Q2 domain WORKGROUP profile D:\\Home\\alice\\x.log",
            &identity,
        );
        assert!(!output.contains("alice"), "{output}");
        assert!(!output.contains("DESKTOP-7Q2"), "{output}");
        assert!(!output.contains("WORKGROUP"), "{output}");
        assert!(output.contains("<已隐藏>"), "{output}");
        assert!(output.contains("<profile>"), "{output}");

        // 换一份夹具就换一套替换：证明没有偷偷回读环境变量。
        let other = RedactionIdentity {
            user: Some("bob".to_string()),
            ..RedactionIdentity::default()
        };
        assert!(redact_with("user alice", &other).contains("alice"));
    }

    #[test]
    fn expired_checks_deadline_and_cancel_flag() {
        // cancel 一旦置位，即使 deadline 未到也算过期。
        let cancel = AtomicBool::new(false);
        let future = Instant::now() + Duration::from_secs(60);
        assert!(!expired(future, &cancel));
        cancel.store(true, Ordering::Release);
        assert!(expired(future, &cancel));
        // 没有 cancel 时 deadline 到点也算过期（用已过去的时间点）。
        let past = Instant::now() - Duration::from_secs(1);
        assert!(expired(past, &AtomicBool::new(false)));
    }

    #[test]
    fn redaction_keeps_plain_versions_and_status_text() {
        let output = redact_with("版本 0.5.0 状态 通过", &RedactionIdentity::default());
        assert_eq!(output, "版本 0.5.0 状态 通过");
    }

    #[test]
    fn redaction_masks_host_port_and_bracketed_ipv6() {
        let output = redact_with("server 192.0.2.1:21116 relay [2001:db8::1]:21117", &RedactionIdentity::default());
        assert!(!output.contains("192.0.2.1"));
        assert!(!output.contains("2001:db8"));
        assert_eq!(output.matches("<ip>").count(), 2);
    }
}
