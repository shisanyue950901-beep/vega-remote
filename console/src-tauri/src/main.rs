#![cfg_attr(not(debug_assertions), windows_subsystem = "windows")]

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
        .manage(CloseToTray::default())
        .invoke_handler(tauri::generate_handler![set_close_to_tray])
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
                    // M2b：读取 RustDesk 设备码后写入手剪贴板（需 clipboard-manager 插件）
                    "copy-code" => {}
                    // M2b：结束当前 RustDesk 会话
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
