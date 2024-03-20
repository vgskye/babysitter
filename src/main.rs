use std::{
    env::{var, var_os},
    ffi::CString,
    fs::File,
    io::copy,
    os::unix::ffi::OsStrExt,
    path::{Path, PathBuf},
    process::Command,
    sync::OnceLock,
};

use color_eyre::eyre;
use eyre::{eyre, Result};
use libc::{atexit, c_uint, close_range, CLOSE_RANGE_CLOEXEC};
use nix::unistd::execvp;
use rpackwiz::model::Pack;

fn maybe_download_fabric(loader_version: &str, minecraft_version: &str) -> Result<PathBuf> {
    let filename = PathBuf::from(format!(
        "mc-{minecraft_version}-fabric-{loader_version}-server.jar"
    ));
    if filename.try_exists().unwrap_or_default() {
        return Ok(filename);
    }
    let url = format!("https://meta.fabricmc.net/v2/versions/loader/{minecraft_version}/{loader_version}/1.0.0/server/jar");
    let resp = ureq::get(&url).call()?;
    if resp.status() != 200 {
        return Err(eyre!(
            "Response status code was not 200, but {}",
            resp.status()
        ));
    }
    if resp.content_type() != "application/java-archive" {
        return Err(eyre!(
            "Response content type was not application/java-archive, but {}",
            resp.content_type()
        ));
    }
    let mut file = File::create(&filename)?;
    copy(&mut resp.into_reader(), &mut file)?;
    Ok(filename)
}

fn maybe_download_packwiz() -> Result<&'static Path> {
    let filename = Path::new("packwiz-installer-bootstrap.jar");
    if filename.try_exists().unwrap_or_default() {
        return Ok(filename);
    }
    let url = "https://github.com/packwiz/packwiz-installer-bootstrap/releases/download/v0.0.3/packwiz-installer-bootstrap.jar";
    let resp = ureq::get(url).call()?;
    if resp.status() != 200 {
        return Err(eyre!(
            "Response status code was not 200, but {}",
            resp.status()
        ));
    }
    let mut file = File::create(filename)?;
    copy(&mut resp.into_reader(), &mut file)?;
    Ok(filename)
}

static EXIT_HOOK_DATA: OnceLock<(CString, Vec<CString>)> = OnceLock::new();

fn main() -> Result<()> {
    color_eyre::install()?;
    let pack_url = var("BABYSITTER_PACKWIZ_URL")?;
    let java_path =
        var_os("BABYSITTER_JAVA_PATH").ok_or(eyre!("BABYSITTER_JAVA_PATH not found!"))?;
    let flags = var("BABYSITTER_JVM_FLAGS")?;
    let resp = ureq::get(&pack_url).call()?.into_string()?;
    let resp: Pack = toml::from_str(&resp)?;
    let minecraft_version = resp
        .versions
        .get("minecraft")
        .ok_or(eyre!("Pack index doesn't specify Minecraft version?"))?;
    let fabric_version = resp.versions.get("fabric").ok_or(eyre!(
        "Pack index doesn't specify fabric version? Is this not a fabric pack?"
    ))?;
    let minecraft_path = maybe_download_fabric(fabric_version, minecraft_version)?;
    let packwiz_path = maybe_download_packwiz()?;
    Command::new(&java_path)
        .arg("-jar")
        .arg(packwiz_path)
        .args(["-g", "-s", "server"])
        .arg(pack_url)
        .spawn()?
        .wait()?;
    _ = EXIT_HOOK_DATA.set((
        CString::new(java_path.as_bytes())?,
        [CString::new(java_path.as_bytes())?]
            .into_iter()
            .chain(flags.split(' ').filter_map(|e| CString::new(e).ok()))
            .chain([
                CString::new("-jar")?,
                CString::new(minecraft_path.as_os_str().as_bytes())?,
                CString::new("--nogui")?,
            ])
            .collect(),
    ));
    unsafe {
        atexit(exit_scam);
    }
    Ok(())
}

extern "C" fn exit_scam() {
    if let Some((java_path, args)) = EXIT_HOOK_DATA.get() {
        unsafe {
            close_range(3, c_uint::MAX, CLOSE_RANGE_CLOEXEC as _);
        }
        _ = execvp(java_path, args);
    }
}
