//! 控制台自动更新：检查更新、后台下载并安装。
//!
//! 端点与公钥来自 `tauri.conf.json` 的 `plugins.updater`：公钥直接提交在仓库里
//! （源码可见，不靠 CI 注入）；更新包必须通过 minisign 签名校验，因此镜像走明文
//! HTTP 也不会被篡改成可安装的包。
//!
//! 通道不是固定回退，而是「同时查询、取更高版本」：
//! 1. 镜像端点与 GitHub 固定 tag 端点用 `tokio::join!` 并发检查，各自 15 秒超时
//!    （两端并行，最坏等待约 15 秒，不是 30 秒）；
//! 2. 任一端点没有更新或报错，另一端点仍会给出结果；两边都有时用 `semver` 比较，
//!    取较高者，版本相同时选镜像（国内更快）；预发布版不推给正式版——只有当前
//!    版本本身是预发布版时，预发布候选才参与比较；
//! 3. 安装走同一套选择规则；从报告该版本的一端下载，失败再换另一端重试一次
//!    （可能装到较低版本，但至少不会因为单端故障完全装不上）。
//!
//! 「已是最新」只在两个端点都答复时才算数；一端不可达而另一端没有更新时返回
//! 独立文案（如「镜像已是最新，GitHub 暂不可达」），设置页照原样显示。
//!
//! 镜像清单滞后（仍指向旧版）时，GitHub 上已发布的更高版本不会被隐藏。
//!
//! 下载单独设 10 分钟超时：插件的 builder 超时只作用于请求，`Update.timeout`
//! 默认是 `None`，所以下载前显式补上，再用 `tokio::time::timeout` 兜一层。
//! 所有错误文案固定为中文短句，不回显路径或服务端原文。

use std::sync::{
    atomic::{AtomicBool, Ordering},
    Arc,
};
use std::time::Duration;

use serde::Serialize;
use tauri::{AppHandle, Emitter, Manager, State};
use tauri_plugin_updater::{Update, Updater, UpdaterExt};

/// 镜像端点（明文 HTTP，信任由 minisign 签名承担）。
const MIRROR_ENDPOINT: &str = "http://60.205.95.98/vega/updates/latest.json";
/// GitHub 固定发布 tag 上的清单：不跟随 latest release，也不依赖 CI 产出 latest.json。
const GITHUB_ENDPOINT: &str =
    "https://github.com/shisanyue950901-beep/vega-remote/releases/download/vega-updates/latest.json";

/// 检查更新（清单请求）超时。
const CHECK_TIMEOUT: Duration = Duration::from_secs(15);
/// 下载安装包超时。
const DOWNLOAD_TIMEOUT: Duration = Duration::from_secs(10 * 60);

/// 同一时间只允许一个安装任务；失败后复位，允许用户重试。
#[derive(Default)]
pub struct Updating(Arc<AtomicBool>);

/// 安装任务的锁守卫：成功、失败、提前返回都会释放锁，不会把界面卡在「更新中」。
struct InstallGuard(Arc<AtomicBool>);

impl Drop for InstallGuard {
    fn drop(&mut self) {
        self.0.store(false, Ordering::SeqCst);
    }
}

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
pub struct UpdateView {
    pub available: bool,
    pub current: String,
    pub latest: String,
    pub notes: String,
    pub error: String,
    /// 只有一端答复且没有更新时的说明（例如「镜像已是最新，GitHub 暂不可达」）。
    pub notice: String,
}

#[derive(Clone, Serialize)]
struct Progress {
    downloaded: u64,
    total: Option<u64>,
}

fn view(current: &str, error: &str) -> UpdateView {
    UpdateView {
        available: false,
        current: current.to_string(),
        latest: String::new(),
        notes: String::new(),
        error: error.to_string(),
        notice: String::new(),
    }
}

fn found(update: &Update) -> UpdateView {
    UpdateView {
        available: true,
        current: update.current_version.clone(),
        latest: update.version.clone(),
        notes: update.body.clone().unwrap_or_default(),
        error: String::new(),
        notice: String::new(),
    }
}

/// 只针对单个端点构建 updater；不传端点就不依赖配置里的顺序。
fn build_updater(app: &AppHandle, endpoint: &str, timeout: Duration) -> Result<Updater, String> {
    let url = endpoint
        .parse::<tauri::Url>()
        .map_err(|_| "更新端点配置无效".to_string())?;
    let builder = app.updater_builder().timeout(timeout);
    // 镜像在国内，必须直连：开着 VPN/Clash 时系统代理会把对镜像的请求吞掉，
    // 镜像日志里连一条请求都看不到。这里只对镜像端点关闭代理，检查与随后的
    // 下载都走同一个 updater，因此下载同样直连；GitHub 端点仍走系统代理。
    let builder = if endpoint == MIRROR_ENDPOINT {
        builder.no_proxy()
    } else {
        builder
    };
    builder
        .endpoints(vec![url])
        .map_err(|_| "更新端点配置无效".to_string())?
        .build()
        .map_err(|_| "更新组件未配置，暂时无法检查更新".to_string())
}

/// 单端点检查：builder 超时 15 秒，再包一层 tokio 超时防止请求悬挂。
async fn check_via(app: &AppHandle, endpoint: &str) -> Result<Option<Update>, String> {
    let updater = build_updater(app, endpoint, CHECK_TIMEOUT)?;
    tokio::time::timeout(CHECK_TIMEOUT, updater.check())
        .await
        .map_err(|_| "检查更新超时，请确认网络后重试".to_string())?
        .map_err(|_| "检查更新失败，请确认网络后重试".to_string())
}

fn parse_version(version: &str) -> Option<semver::Version> {
    semver::Version::parse(version.trim().trim_start_matches(|c| c == 'v' || c == 'V')).ok()
}

/// 正式版不接收预发布候选；当前本身是预发布时才接受。解析失败的候选一律丢弃。
/// 另外要求候选的 SemVer 优先级严格高于当前版本（忽略 +build），仅构建元数据不同不算更新。
fn acceptable(update: &Update, current_is_pre: bool) -> bool {
    let current = parse_version(&update.current_version);
    match parse_version(&update.version) {
        Some(version) => {
            (current_is_pre || version.pre.is_empty())
                && current
                    .map(|c| version.cmp_precedence(&c) == std::cmp::Ordering::Greater)
                    .unwrap_or(true)
        }
        None => false,
    }
}

/// 两个候选里取 semver 优先级更高者（忽略 +build 元数据）；同优先级取镜像。
fn github_wins(github: &Update, mirror: &Update) -> bool {
    match (parse_version(&github.version), parse_version(&mirror.version)) {
        (Some(g), Some(m)) => g.cmp_precedence(&m) == std::cmp::Ordering::Greater,
        _ => false,
    }
}

enum Outcome {
    Found(&'static str, Update),
    /// 两端都答复且都没有可用更新。
    UpToDate,
    /// 只有一端答复且没有更新；参数是说明文字。
    Partial(&'static str),
    Failed,
}

/// 并发查询两个端点（各 15 秒超时）并按规则选出结果。
async fn resolve(app: &AppHandle) -> Outcome {
    let current_is_pre = parse_version(&app.package_info().version.to_string())
        .map(|v| !v.pre.is_empty())
        .unwrap_or(false);
    let (mirror, github) = tokio::join!(
        check_via(app, MIRROR_ENDPOINT),
        check_via(app, GITHUB_ENDPOINT)
    );
    let mirror_ok = mirror.is_ok();
    let github_ok = github.is_ok();
    let pick = |r: Result<Option<Update>, String>| {
        r.ok().flatten().filter(|u| acceptable(u, current_is_pre))
    };
    match (pick(mirror), pick(github)) {
        (Some(m), Some(g)) => {
            if github_wins(&g, &m) {
                Outcome::Found(GITHUB_ENDPOINT, g)
            } else {
                Outcome::Found(MIRROR_ENDPOINT, m)
            }
        }
        (Some(m), None) => Outcome::Found(MIRROR_ENDPOINT, m),
        (None, Some(g)) => Outcome::Found(GITHUB_ENDPOINT, g),
        (None, None) => match (mirror_ok, github_ok) {
            (true, true) => Outcome::UpToDate,
            (true, false) => Outcome::Partial("镜像已是最新，GitHub 暂不可达"),
            (false, true) => Outcome::Partial("GitHub 已是最新，国内镜像暂不可达"),
            (false, false) => Outcome::Failed,
        },
    }
}

/// 查询是否有新版本：两个端点同时查，都有结果时返回版本号更高的那个。
#[tauri::command]
pub async fn check_update(app: AppHandle) -> UpdateView {
    let current = app.package_info().version.to_string();
    match resolve(&app).await {
        Outcome::Found(_, update) => found(&update),
        Outcome::UpToDate => view(&current, ""),
        Outcome::Partial(notice) => {
            let mut v = view(&current, "");
            v.notice = notice.to_string();
            v
        }
        Outcome::Failed => view(&current, "检查更新失败，请确认网络后重试"),
    }
}

/// 后台下载并安装；命令立即返回，进度通过 `vega://update-progress` 事件推送。
#[tauri::command]
pub async fn install_update(
    app: AppHandle,
    updating: State<'_, Updating>,
) -> Result<(), String> {
    let running = updating.0.clone();
    if running.swap(true, Ordering::SeqCst) {
        return Err("正在更新，请稍候".to_string());
    }
    let handle = app.clone();
    tauri::async_runtime::spawn(async move {
        // 守卫放进任务里：任何退出路径都会释放 AtomicBool。
        let _guard = InstallGuard(running);
        if let Err(message) = run_install(handle.clone()).await {
            let _ = handle.emit("vega://update-error", &message);
        }
    });
    Ok(())
}

/// 选择要安装的端点与更新：规则与 `check_update` 相同。
async fn select_update(app: &AppHandle) -> Result<(&'static str, Update), String> {
    match resolve(app).await {
        Outcome::Found(endpoint, update) => Ok((endpoint, update)),
        Outcome::UpToDate => Err("当前已是最新版本".to_string()),
        Outcome::Partial(notice) => Err(notice.to_string()),
        Outcome::Failed => Err("检查更新失败，请确认网络后重试".to_string()),
    }
}

/// 从报告更高版本的端点安装；下载或验签失败时换另一个端点重试一次。
async fn run_install(app: AppHandle) -> Result<(), String> {
    let (endpoint, update) = select_update(&app).await?;
    match download_and_install(&app, update).await {
        Ok(()) => Ok(()),
        Err(_) => {
            let fallback = if endpoint == MIRROR_ENDPOINT {
                GITHUB_ENDPOINT
            } else {
                MIRROR_ENDPOINT
            };
            install_via(&app, fallback).await
        }
    }
}

async fn install_via(app: &AppHandle, endpoint: &str) -> Result<(), String> {
    let current_is_pre = parse_version(&app.package_info().version.to_string())
        .map(|v| !v.pre.is_empty())
        .unwrap_or(false);
    let update = check_via(app, endpoint)
        .await?
        .filter(|u| acceptable(u, current_is_pre))
        .ok_or_else(|| "备用端点没有可用的更新".to_string())?;
    download_and_install(app, update).await
}

async fn download_and_install(app: &AppHandle, mut update: Update) -> Result<(), String> {
    // builder 的超时不会带进下载请求（`Update.timeout` 默认 None），这里单独补 10 分钟。
    update.timeout = Some(DOWNLOAD_TIMEOUT);

    let progress_app = app.clone();
    let mut downloaded: u64 = 0;
    let emit = move |chunk: usize, total: Option<u64>| {
        downloaded = downloaded.saturating_add(chunk as u64);
        let _ = progress_app.emit(
            "vega://update-progress",
            Progress {
                downloaded,
                total,
            },
        );
    };

    tokio::time::timeout(DOWNLOAD_TIMEOUT, update.download_and_install(emit, || {}))
        .await
        .map_err(|_| "下载更新超时，请稍后重试".to_string())?
        .map_err(|_| "下载或安装更新失败，请稍后重试".to_string())?;

    // Windows 上被动安装器会自己用 /R 拉起新版本，进程已被安装器接管；
    // 这里的 restart 只是非 Windows / 安装器未接管的兜底。
    app.restart();
}
