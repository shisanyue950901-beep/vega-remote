#![cfg_attr(not(debug_assertions), windows_subsystem = "windows")]

mod access;
mod doctor;
mod peers;
mod rustdesk;
mod scm;
mod streaming;
mod updater;
mod winpaths;

use std::sync::atomic::{AtomicBool, Ordering};

use tauri::menu::{Menu, MenuItem, PredefinedMenuItem};
use tauri::tray::TrayIconBuilder;
use tauri::{Manager, State, WindowEvent};

/// 「关闭窗口时最小化到托盘」开关。默认开启，由前端通过
/// `set_close_to_tray` 命令同步（设置页勾选状态）。
struct CloseToTray(AtomicBool);

impl Default for CloseToTray {
    fn default() -> Self {
        Self(AtomicBool::new(true))
    }
}

/// 前端在启动与勾选变更时调用；不涉及任何文件或网络访问。
#[tauri::command]
fn set_close_to_tray(enabled: bool, state: State<'_, CloseToTray>) {
    state.0.store(enabled, Ordering::Relaxed);
}

fn main() {
    tauri::Builder::default()
        .plugin(tauri_plugin_updater::Builder::new().build())
        .manage(CloseToTray::default())
        .manage(updater::Updating::default())
        .invoke_handler(tauri::generate_handler![
            set_close_to_tray,
            rustdesk::get_device_id,
            rustdesk::get_server_config,
            rustdesk::get_relay_defaults,
            rustdesk::get_mobile_config_qr,
            rustdesk::connect_peer,
            rustdesk::get_recent_peers,
            peers::get_peer_aliases,
            peers::set_peer_alias,
            peers::remove_peer,
            rustdesk::open_rustdesk_window,
            rustdesk::open_rustdesk_download_page,
            rustdesk::get_rustdesk_status,
            rustdesk::test_server_connection,
            streaming::get_streaming_status,
            streaming::open_sunshine_pairing,
            streaming::open_sunshine_settings,
            streaming::start_moonlight_stream,
            doctor::run_doctor,
            doctor::export_doctor_log,
            access::get_access_code,
            access::refresh_access_code,
            access::set_fixed_access_code,
            access::set_rotate_access_code,
            updater::check_update,
            updater::install_update,
        ])
        .setup(|app| {
            // 托盘菜单：显示主窗口 / 复制设备码 / 断开当前会话 / 退出
            let show = MenuItem::with_id(app, "show", "显示主窗口", true, None::<&str>)?;
            let copy_code = MenuItem::with_id(app, "copy-code", "复制设备码", true, None::<&str>)?;
            let disconnect = MenuItem::with_id(app, "disconnect", "断开当前会话", false, None::<&str>)?;
            let separator = PredefinedMenuItem::separator(app)?;
            let quit = MenuItem::with_id(app, "quit", "退出", true, None::<&str>)?;
            let menu = Menu::with_items(app, &[&show, &copy_code, &disconnect, &separator, &quit])?;

            let mut tray = TrayIconBuilder::with_id("main")
                .menu(&menu)
                .show_menu_on_left_click(false)
                .tooltip("Vega 控制台")
                .on_menu_event(|app, event| match event.id.as_ref() {
                    "show" => {
                        if let Some(window) = app.get_webview_window("main") {
                            let _ = window.show();
                            let _ = window.unminimize();
                            let _ = window.set_focus();
                        }
                    }
                    // 复制设备码要跑子进程（--get-id）并写系统剪贴板，绝不能占用
                    // 托盘事件线程：子进程等待丢到独立 worker，剪贴板写入由
                    // worker 通过 run_on_main_thread 切回主线程（主窗口 HWND）。
                    "copy-code" => {
                        let handle = app.clone();
                        std::thread::spawn(move || {
                            let _ = rustdesk::copy_device_id_to_clipboard(&handle);
                        });
                    }
                    // 「断开」当前仍是 RustDesk 窗口自己的挂断按钮；M2c 接入会话事件后
                    // 才能在这里自动化，先保持禁用。
                    "disconnect" => {}
                    // 托盘「退出」是唯一真正退出的入口（关闭窗口只隐藏）。
                    "quit" => app.exit(0),
                    _ => {}
                });

            if let Some(icon) = app.default_window_icon() {
                tray = tray.icon(icon.clone());
            }
            tray.build(app)?;

            Ok(())
        })
        .on_window_event(|window, event| {
            if let WindowEvent::CloseRequested { api, .. } = event {
                if window.state::<CloseToTray>().0.load(Ordering::Relaxed) {
                    api.prevent_close();
                    let _ = window.hide();
                }
            }
        })
        .run(tauri::generate_context!())
        .expect("启动 Vega 控制台失败");
}
