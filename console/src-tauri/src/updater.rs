//! 控制台自动更新：检查更新、后台下载并安装。
//!
//! 端点与公钥来自 `tauri.conf.json` 的 `plugins.updater`。更新包必须通过
//! minisign 签名校验（公钥在构建时由 CI 注入），因此镜像走明文 HTTP 也不会
//! 被篡改成可安装的包。所有错误文案固定为中文短句，不回显路径或服务端原文。

use std::sync::atomic::{AtomicBool, Ordering};

use serde::Serialize;
use tauri::{AppHandle, Emitter, Manager, State};
use tauri_plugin_updater::UpdaterExt;

/// 同一时间只允许一个安装任务；失败后复位，允许用户重试。
#[derive(Default)]
pub struct Updating(AtomicBool);

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

/// 查询是否有新版本。网络或配置错误只返回通用文案，不打断界面。
#[tauri::command]
pub async fn check_update(app: AppHandle) -> UpdateView {
    let current = app.package_info().version.to_string();
    let updater = match app.updater() {
        Ok(updater) => updater,
        Err(_) => return view(&current, "更新组件未配置，暂时无法检查更新"),
    };
    match updater.check().await {
        Ok(Some(update)) => UpdateView {
            available: true,
            current: update.current_version.clone(),
            latest: update.version.clone(),
            notes: update.body.clone().unwrap_or_default(),
            error: String::new(),
        },
        Ok(None) => view(&current, ""),
        Err(_) => view(&current, "检查更新失败，请确认网络后重试"),
    }
}

/// 后台下载并安装；命令立即返回，进度通过 `vega://update-progress` 事件推送。
#[tauri::command]
pub async fn install_update(
    app: AppHandle,
    updating: State<'_, Updating>,
) -> Result<(), String> {
    if updating.0.swap(true, Ordering::SeqCst) {
        return Err("正在更新，请稍候".to_string());
    }
    let handle = app.clone();
    tauri::async_runtime::spawn(async move {
        let result = run_install(handle.clone()).await;
        if let Err(message) = result {
            let _ = handle.emit("vega://update-error", &message);
        }
        // 失败时复位锁；成功路径会在 restart 前退出，无需复位。
        if let Some(state) = handle.try_state::<Updating>() {
            state.0.store(false, Ordering::SeqCst);
        }
    });
    Ok(())
}

async fn run_install(app: AppHandle) -> Result<(), String> {
    let updater = app
        .updater()
        .map_err(|_| "更新组件未配置，暂时无法更新".to_string())?;
    let update = updater
        .check()
        .await
        .map_err(|_| "检查更新失败，请确认网络后重试".to_string())?
        .ok_or_else(|| "当前已是最新版本".to_string())?;

    let progress_app = app.clone();
    let downloaded: u64 = 0;
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

    update
        .download_and_install(emit, || {})
        .await
        .map_err(|_| "下载或安装更新失败，请稍后重试".to_string())?;

    app.restart();
}
