/// Tauri 构建：把全部自定义命令登记进 AppManifest，构建期生成
/// `allow-*` 权限，供 `capabilities/default.json` 授权（修复 M2a 审计 r2 P3：
/// 命令声明在代码里、权限却不在 capability 里）。
fn main() {
    tauri_build::try_build(
        tauri_build::Attributes::new().app_manifest(tauri_build::AppManifest::new().commands(&[
            "set_close_to_tray",
            "get_device_id",
            "get_server_config",
            "connect_peer",
            "get_recent_peers",
            "open_rustdesk_window",
            "open_rustdesk_download_page",
            "get_rustdesk_status",
            "test_server_connection",
            "get_streaming_status",
            "open_sunshine_pairing",
            "open_sunshine_settings",
            "start_moonlight_stream",
            "run_doctor",
            "export_doctor_log",
        ])),
    )
    .expect("tauri-build 失败");
}
