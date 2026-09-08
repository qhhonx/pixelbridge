use anyhow::{bail, Context, Result};
use sha2::{Digest, Sha256};
use std::{collections::HashSet, fs, os::unix::fs::MetadataExt, path::Path};

use crate::{queue::Queue, verify_remote_hash};

fn real_directory(path: &Path) -> Result<()> {
    let metadata = fs::symlink_metadata(path)?;
    if !metadata.is_dir() || metadata.file_type().is_symlink() {
        bail!(
            "cache cleanup refuses non-directory or symbolic link: {}",
            path.display()
        );
    }
    Ok(())
}

fn inspect_tree(path: &Path, seen: &mut HashSet<(u64, u64)>) -> Result<u64> {
    let mut bytes = 0;
    for entry in fs::read_dir(path)? {
        let entry = entry?;
        let metadata = fs::symlink_metadata(entry.path())?;
        if metadata.file_type().is_symlink() {
            bail!("cache cleanup refuses symbolic links");
        } else if metadata.is_dir() {
            bytes += inspect_tree(&entry.path(), seen)?;
        } else if metadata.is_file() {
            if seen.insert((metadata.dev(), metadata.ino())) {
                bytes += metadata.len();
            }
        } else {
            bail!("cache cleanup refuses special files");
        }
    }
    Ok(bytes)
}

pub fn reclaim(root: &Path, asset_id: &str, device: &str, adb: &Path) -> Result<()> {
    // Derive the only removable directory internally. Never accept an arbitrary deletion path.
    real_directory(root)?;
    let root = fs::canonicalize(root)?;
    let state = root.join("State");
    let staging = root.join("Staging");
    real_directory(&state)?;
    real_directory(&staging)?;
    let id = format!("{:x}", Sha256::digest(asset_id.as_bytes()));
    let job = staging.join(&id);
    // Keep the queue lock until deletion finishes, so its proof cannot change underneath us.
    let queue = Queue::open(&state)?;
    let (hash, remote) = queue.delivered_copy(asset_id)?;
    let prefix = format!("/sdcard/DCIM/Camera/PB_{id}");
    let extension = remote
        .strip_prefix(&format!("{prefix}."))
        .or_else(|| remote.strip_prefix(&format!("{prefix}_MP.")))
        .context("delivery path does not belong to this cache asset")?;
    if extension.is_empty() || !extension.bytes().all(|b| b.is_ascii_alphanumeric()) {
        bail!("invalid delivery filename");
    }
    match fs::symlink_metadata(&job) {
        Err(e) if e.kind() == std::io::ErrorKind::NotFound => {
            println!("reclaimed_bytes: 0");
            return Ok(());
        }
        Err(e) => return Err(e.into()),
        Ok(_) => real_directory(&job)?,
    }
    let bytes = inspect_tree(&job, &mut HashSet::new())?;
    verify_remote_hash(adb, Some(device), &remote, &hash)
        .context("Pixel copy could not be verified; Mac cache retained")?;
    fs::remove_dir_all(&job).context("remove verified Mac staging cache")?;
    println!("reclaimed_bytes: {bytes}");
    Ok(())
}
