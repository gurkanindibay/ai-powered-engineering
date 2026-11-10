//! CLI tool to export the OpenAPI 3.1 specification to JSON.
use std::env;
use std::fs;
use std::path::Path;

fn main() -> Result<(), Box<dyn std::error::Error>> {
    let spec = sitepulse_backend::openapi::get_openapi_spec_json();
    let args: Vec<String> = env::args().collect();
    let target_path = if args.len() > 1 {
        args[1].clone()
    } else if Path::new("../docs").exists() {
        "../docs/openapi.json".to_string()
    } else {
        "docs/openapi.json".to_string()
    };

    let target = Path::new(&target_path);
    if let Some(parent) = target.parent() {
        if !parent.as_os_str().is_empty() {
            fs::create_dir_all(parent)?;
        }
    }

    fs::write(target, spec)?;
    println!(
        "Successfully exported SitePulse OpenAPI 3.1 specification ({} bytes) to {}",
        spec.len(),
        target.display()
    );
    Ok(())
}
