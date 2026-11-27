fn main() {
    if let Err(e) = tauri_build::try_build(tauri_build::Attributes::new().app_manifest(
        tauri_build::AppManifest::new().commands(&[
            "begin_quit",
            "set_custom_titlebar",
            "check_update",
            "download_update",
            "begin_update",
        ]),
    )) {
        panic!("{e}")
    }
}
