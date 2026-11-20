#![cfg_attr(not(debug_assertions), windows_subsystem = "windows")]

use tauri::menu::{Menu, MenuItem, PredefinedMenuItem};
use tauri::tray::TrayIconBuilder;
use tauri::Manager;

fn main() {
    tauri::Builder::default()
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
                    "quit" => app.exit(0),
                    _ => {}
                });

            if let Some(icon) = app.default_window_icon() {
                tray = tray.icon(icon.clone());
            }
            tray.build(app)?;

            Ok(())
        })
        .run(tauri::generate_context!())
        .expect("启动 Vega 控制台失败");
}
