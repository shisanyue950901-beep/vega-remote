/// Tauri 构建：把全部自定义命令登记进 AppManifest，构建期生成
/// `allow-*` 权限，供 `capabilities/default.json` 授权（修复 M2a 审计 r2 P3：
/// 命令声明在代码里、权限却不在 capability 里）。
fn main() {
    tauri_build::try_build(
        tauri_build::Attributes::new().app_manifest(tauri_build::AppManifest::new().commands(&[
            "set_close_to_tray",
            "rustdesk::get_device_id",
            "rustdesk::get_server_config",
            "rustdesk::set_server_config",
            "rustdesk::connect_peer",
            "rustdesk::get_recent_peers",
            "rustdesk::open_rustdesk_window",
            "rustdesk::get_rustdesk_status",
            "rustdesk::install_rustdesk",
            "rustdesk::test_server_connection",
        ])),
    )
    .expect("tauri-build 失败");
}
