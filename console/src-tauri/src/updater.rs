//! 控制台自动更新：检查更新、后台下载并安装。
//!
//! 端点与公钥来自 `tauri.conf.json` 的 `plugins.updater`：公钥直接提交在仓库里
//! （源码可见，不靠 CI 注入）；更新包必须通过 minisign 签名校验，因此镜像走明文
//! HTTP 也不会被篡改成可安装的包。
//!
//! 通道顺序不是固定回退，而是「两个都问，取更高版本」：
//! 1. 镜像端点与 GitHub 固定 tag 端点各自检查（检查超时 15 秒）；
//! 2. 任一端点没有更新或报错，另一端点仍会检查；两边都有时按版本号取较高者；
//! 3. 安装时从报告该版本的一端下载；失败再换另一端重试一次（可能装到较低版本，
//!    但至少不会因为单端故障完全装不上）。
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
    }
}

fn found(update: &Update) -> UpdateView {
    UpdateView {
        available: true,
        current: update.current_version.clone(),
        latest: update.version.clone(),
        notes: update.body.clone().unwrap_or_default(),
        error: String::new(),
    }
}

/// 只针对单个端点构建 updater；不传端点就不依赖配置里的顺序。
fn build_updater(app: &AppHandle, endpoint: &str, timeout: Duration) -> Result<Updater, String> {
    let url = endpoint
        .parse::<tauri::Url>()
        .map_err(|_| "更新端点配置无效".to_string())?;
    app.updater_builder()
        .timeout(timeout)
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

/// 版本号比较键：只比较 `x.y.z` 数字段，预发布/构建后缀忽略。
/// 插件只返回「比当前新」的版本，所以这里只需在两个候选之间排序。
fn version_key(version: &str) -> (u64, u64, u64) {
    let core = version.trim().trim_start_matches(|c| c == 'v' || c == 'V');
    let core = core.split(|c| c == '-' || c == '+').next().unwrap_or("");
    let mut parts = core.split('.').map(|part| part.parse::<u64>().unwrap_or(0));
    (
        parts.next().unwrap_or(0),
        parts.next().unwrap_or(0),
        parts.next().unwrap_or(0),
    )
}

fn is_newer(candidate: &str, other: &str) -> bool {
    version_key(candidate) > version_key(other)
}

/// 查询是否有新版本。两个端点都检查（镜像报错或没有更新也要问 GitHub），
/// 都有结果时返回版本号更高的那个。
#[tauri::command]
pub async fn check_update(app: AppHandle) -> UpdateView {
    let current = app.package_info().version.to_string();
    let mirror = check_via(&app, MIRROR_ENDPOINT).await;
    let github = check_via(&app, GITHUB_ENDPOINT).await;
    let both_failed = mirror.is_err() && github.is_err();

    let mirror_update = mirror.as_ref().ok().and_then(|update| update.as_ref());
    let github_update = github.as_ref().ok().and_then(|update| update.as_ref());

    match (mirror_update, github_update) {
        (Some(mirror_update), Some(github_update)) => {
            if is_newer(&github_update.version, &mirror_update.version) {
                found(github_update)
            } else {
                found(mirror_update)
            }
        }
        (Some(update), None) | (None, Some(update)) => found(update),
        (None, None) => {
            if both_failed {
                view(&current, "检查更新失败，请确认网络后重试")
            } else {
                view(&current, "")
            }
        }
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

/// 选择要安装的端点与更新：两个端点都检查，取更高版本；失败一端不阻塞另一端。
async fn select_update(app: &AppHandle) -> Result<(&'static str, Update), String> {
    let mirror = check_via(app, MIRROR_ENDPOINT).await;
    let github = check_via(app, GITHUB_ENDPOINT).await;
    match (mirror, github) {
        (Ok(Some(mirror_update)), Ok(Some(github_update))) => {
            if is_newer(&github_update.version, &mirror_update.version) {
                Ok((GITHUB_ENDPOINT, github_update))
            } else {
                Ok((MIRROR_ENDPOINT, mirror_update))
            }
        }
        (Ok(Some(update)), _) => Ok((MIRROR_ENDPOINT, update)),
        (_, Ok(Some(update))) => Ok((GITHUB_ENDPOINT, update)),
        (Err(_), Err(_)) => Err("检查更新失败，请确认网络后重试".to_string()),
        _ => Err("当前已是最新版本".to_string()),
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
    let update = check_via(app, endpoint)
        .await?
        .ok_or_else(|| "当前已是最新版本".to_string())?;
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
