// Prevents additional console window on Windows in release, DO NOT REMOVE!!
#![cfg_attr(not(debug_assertions), windows_subsystem = "windows")]

fn main() {
    if let Some(code) = desktop_lib::workbench_cli::run_if_requested() { std::process::exit(code); }
    desktop_lib::run()
}
