use anyhow::{bail, Context, Result};
use clap::{Parser, Subcommand};
use serde_json::Value;
use sha2::{Digest, Sha256};
use std::ffi::OsStr;
use std::fs;
use std::io::{Read, Write};
use std::path::{Path, PathBuf};
use std::process::{Command, Output};

mod cache;
mod queue;
use queue::{Queue, QueuePhase};

const MPVD_BOX_SIZE: usize = 8;
const SEFD_BOX_SIZE: usize = 8;
const SAMSUNG_SEFH_VERSION: i32 = 107;

#[derive(Parser)]
#[command(version, about)]
struct Cli {
    #[command(subcommand)]
    command: Commands,
}

#[derive(Subcommand)]
enum Commands {
    /// Reclaim one completed Mac staging directory after rechecking its Pixel copy.
    ReclaimCache {
        #[arg(long)]
        bridge_root: PathBuf,
        #[arg(long)]
        asset_id: String,
        #[arg(long)]
        device: String,
        #[arg(long, default_value = "adb")]
        adb: PathBuf,
    },
    /// Stream a hash without loading large videos into RAM.
    Hash {
        #[arg(long)]
        file: PathBuf,
    },
    /// Convert and mux one Apple Live Photo pair.
    Prepare {
        #[arg(long)]
        image: PathBuf,
        #[arg(long)]
        video: PathBuf,
        #[arg(long)]
        output: PathBuf,
        #[arg(long, default_value = "exiftool")]
        exiftool: PathBuf,
        #[arg(long, default_value = "/usr/bin/avconvert")]
        avconvert: PathBuf,
        /// Rebuild an existing output file.
        #[arg(long)]
        force: bool,
    },
    /// Copy a prepared Motion Photo into Pixel's Camera folder.
    Push {
        #[arg(long)]
        file: PathBuf,
        #[arg(long)]
        device: Option<String>,
        #[arg(long, default_value = "adb")]
        adb: PathBuf,
        #[arg(long, default_value = "/sdcard/DCIM/Camera")]
        destination: String,
    },
    /// Compare a local prepared file with an existing file on Pixel.
    VerifyDevice {
        #[arg(long)]
        file: PathBuf,
        #[arg(long)]
        remote: String,
        #[arg(long)]
        device: Option<String>,
        #[arg(long, default_value = "adb")]
        adb: PathBuf,
    },
    /// Check Pixel connection, battery temperature, and free storage.
    DeviceStatus {
        #[arg(long)]
        device: Option<String>,
        #[arg(long, default_value = "adb")]
        adb: PathBuf,
        #[arg(long, default_value_t = 40.0)]
        max_temperature_c: f64,
        #[arg(long, default_value_t = 4.0)]
        min_free_gb: f64,
    },
    /// Add one Photos asset to the append-only work queue.
    QueueAdd {
        #[arg(long)]
        state_dir: PathBuf,
        #[arg(long)]
        asset_id: String,
        #[arg(long)]
        filename: String,
    },
    /// Record a validated queue phase transition.
    QueueTransition {
        #[arg(long)]
        state_dir: PathBuf,
        #[arg(long)]
        asset_id: String,
        #[arg(long, value_enum)]
        phase: QueuePhase,
        #[arg(long)]
        sha256: Option<String>,
        #[arg(long)]
        remote: Option<String>,
        #[arg(long)]
        message: Option<String>,
    },
    /// Persist the measured size of one prepared delivery.
    QueueSetSize {
        #[arg(long)]
        state_dir: PathBuf,
        #[arg(long)]
        asset_id: String,
        #[arg(long)]
        bytes: i64,
    },
    /// Print the reconstructed queue as JSON.
    QueueList {
        #[arg(long)]
        state_dir: PathBuf,
    },
}

fn main() -> Result<()> {
    match Cli::parse().command {
        Commands::ReclaimCache {
            bridge_root,
            asset_id,
            device,
            adb,
        } => cache::reclaim(&bridge_root, &asset_id, &device, &adb),
        Commands::Hash { file } => {
            println!("sha256: {}", sha256_file(&file)?);
            Ok(())
        }
        Commands::Prepare {
            image,
            video,
            output,
            exiftool,
            avconvert,
            force,
        } => prepare(&image, &video, &output, &exiftool, &avconvert, force),
        Commands::Push {
            file,
            device,
            adb,
            destination,
        } => push(&file, device.as_deref(), &adb, &destination),
        Commands::VerifyDevice {
            file,
            remote,
            device,
            adb,
        } => verify_device(&file, &remote, device.as_deref(), &adb),
        Commands::DeviceStatus {
            device,
            adb,
            max_temperature_c,
            min_free_gb,
        } => device_status(device.as_deref(), &adb, max_temperature_c, min_free_gb),
        Commands::QueueAdd {
            state_dir,
            asset_id,
            filename,
        } => Queue::open(&state_dir)?.add(&asset_id, &filename),
        Commands::QueueTransition {
            state_dir,
            asset_id,
            phase,
            sha256,
            remote,
            message,
        } => Queue::open(&state_dir)?.transition(
            &asset_id,
            phase,
            sha256.as_deref(),
            remote.as_deref(),
            message.as_deref(),
        ),
        Commands::QueueSetSize {
            state_dir,
            asset_id,
            bytes,
        } => Queue::open(&state_dir)?.set_size(&asset_id, bytes),
        Commands::QueueList { state_dir } => Queue::open(&state_dir)?.print_json(),
    }
}

fn prepare(
    image: &Path,
    video: &Path,
    output: &Path,
    exiftool: &Path,
    avconvert: &Path,
    force: bool,
) -> Result<()> {
    ensure_file(image, "image")?;
    ensure_file(video, "video")?;
    if output.exists() && !force {
        bail!(
            "output already exists: {} (use --force to rebuild)",
            output.display()
        );
    }
    if let Some(parent) = output.parent() {
        fs::create_dir_all(parent)
            .with_context(|| format!("create output directory {}", parent.display()))?;
    }

    let image_ext = image
        .extension()
        .and_then(OsStr::to_str)
        .unwrap_or("")
        .to_ascii_lowercase();
    if !matches!(image_ext.as_str(), "heic" | "heif" | "jpg" | "jpeg") {
        bail!("Live Photo still must be HEIC, HEIF or JPEG");
    }

    let image_meta = exif_json(exiftool, image, false)?;
    let video_meta = exif_json(exiftool, video, true)?;
    validate_live_pair(&image_meta, &video_meta)?;

    let codec = find_string(&video_meta, "CompressorID").unwrap_or("unknown");
    let temp_dir = output
        .parent()
        .unwrap_or_else(|| Path::new("."))
        .join(format!(".pixelbridge-{}", std::process::id()));
    if temp_dir.exists() {
        fs::remove_dir_all(&temp_dir).context("clear stale temporary directory")?;
    }
    fs::create_dir_all(&temp_dir).context("create temporary directory")?;

    let result = (|| -> Result<()> {
        let prepared_video = temp_dir.join("motion-h264.mov");
        if matches!(codec, "avc1" | "avc3") {
            fs::copy(video, &prepared_video).context("copy existing H.264 motion track")?;
            println!("video: H.264 already; preserving without transcoding");
        } else {
            println!("video: {codec}; transcoding motion track to H.264");
            run_checked(
                Command::new(avconvert)
                    .arg("--source")
                    .arg(video)
                    .arg("--preset")
                    .arg("PresetHighestQuality")
                    .arg("--output")
                    .arg(&prepared_video)
                    .arg("--replace")
                    .arg("--disableMetadataFilter"),
                "avconvert",
            )?;
        }

        let converted_meta = exif_json(exiftool, &prepared_video, true)?;
        let converted_codec = find_string(&converted_meta, "CompressorID").unwrap_or("unknown");
        if !matches!(converted_codec, "avc1" | "avc3") {
            bail!("converted motion track is not H.264 (codec={converted_codec})");
        }
        validate_live_pair(&image_meta, &converted_meta)?;
        let timestamp_us = live_photo_timestamp_us(&converted_meta)?;
        let video_bytes = fs::read(&prepared_video).context("read prepared motion track")?;

        let source_xmp = command_stdout_bytes(
            Command::new(exiftool).arg("-XMP").arg("-b").arg(image),
            "read source XMP",
        )?;
        let source_xmp = String::from_utf8(source_xmp).context("source XMP is not UTF-8")?;
        let jpeg = matches!(image_ext.as_str(), "jpg" | "jpeg");
        let xmp = inject_motion_xmp(
            &source_xmp,
            if jpeg {
                video_bytes.len()
            } else {
                video_footer_size(video_bytes.len())
            },
            timestamp_us,
        )?;
        let xmp = if jpeg {
            xmp.replace("image/heic", "image/jpeg")
                .replace("Item:Padding=\"8\"", "Item:Padding=\"0\"")
        } else {
            xmp
        };
        let xmp_path = temp_dir.join("motion.xmp");
        fs::write(&xmp_path, xmp).context("write temporary XMP")?;

        let xmp_image = temp_dir.join(format!("still-with-motion-xmp.{image_ext}"));
        fs::copy(image, &xmp_image).context("copy still image")?;
        run_checked(
            Command::new(exiftool)
                .arg("-overwrite_original")
                .arg("-tagsfromfile")
                .arg(&xmp_path)
                .arg("-xmp")
                .arg(&xmp_image),
            "write Motion Photo XMP",
        )?;

        let mut merged = fs::read(&xmp_image).context("read XMP-enriched image")?;
        if jpeg {
            merged.extend_from_slice(&video_bytes);
        } else {
            let footer = samsung_footer(&video_bytes, merged.len());
            merged.extend_from_slice(&footer);
        }
        let partial = output.with_extension(format!("{}.partial", image_ext));
        {
            let mut file = fs::File::create(&partial).context("create partial output")?;
            file.write_all(&merged).context("write partial output")?;
            file.sync_all().context("sync partial output")?;
        }
        validate_output(exiftool, &partial, &video_bytes)?;
        fs::rename(&partial, output).context("commit completed output")?;
        let digest = sha256_file(output)?;
        println!("output: {}", output.display());
        println!("sha256: {digest}");
        println!("motion timestamp: {timestamp_us} us");
        println!("validation: H.264 video embedded; Motion Photo metadata present");
        Ok(())
    })();

    let _ = fs::remove_dir_all(&temp_dir);
    result
}

fn ensure_file(path: &Path, label: &str) -> Result<()> {
    if !path.is_file() {
        bail!("{label} file does not exist: {}", path.display());
    }
    Ok(())
}

fn exif_json(exiftool: &Path, path: &Path, embedded_tracks: bool) -> Result<Value> {
    let mut command = Command::new(exiftool);
    command.args(["-json", "-G1", "-a", "-s", "-n"]);
    if embedded_tracks {
        command.arg("-ee");
    }
    command.args([
        "-ContentIdentifier",
        "-CompressorID",
        "-StillImageTime",
        "-TrackDuration",
        "-MotionPhoto",
        "-MotionPhotoVersion",
        "-MotionPhotoPresentationTimestampUs",
    ]);
    command.arg(path);
    let bytes = command_stdout_bytes(&mut command, "read metadata")?;
    let value: Value = serde_json::from_slice(&bytes).context("parse ExifTool JSON")?;
    value
        .as_array()
        .and_then(|array| array.first())
        .cloned()
        .context("ExifTool returned no metadata")
}

fn find_string<'a>(metadata: &'a Value, suffix: &str) -> Option<&'a str> {
    metadata.as_object()?.iter().find_map(|(key, value)| {
        (key.ends_with(suffix) && value.is_string())
            .then(|| value.as_str())
            .flatten()
    })
}

fn content_identifier(metadata: &Value) -> Option<&str> {
    find_string(metadata, "ContentIdentifier")
}

fn validate_live_pair(image: &Value, video: &Value) -> Result<()> {
    let image_id =
        content_identifier(image).context("still image has no Apple content identifier")?;
    let video_id =
        content_identifier(video).context("motion video has no Apple content identifier")?;
    if image_id != video_id {
        bail!("Live Photo identifiers do not match: image={image_id}, video={video_id}");
    }
    Ok(())
}

fn live_photo_timestamp_us(metadata: &Value) -> Result<i64> {
    let object = metadata.as_object().context("invalid video metadata")?;
    for (key, value) in object {
        if key.ends_with(":StillImageTime") && value.as_i64() == Some(-1) {
            let prefix = key.trim_end_matches("StillImageTime");
            let duration_key = format!("{prefix}TrackDuration");
            let duration = object
                .get(&duration_key)
                .and_then(Value::as_f64)
                .with_context(|| format!("missing {duration_key}"))?;
            return Ok((duration * 1_000_000.0).round() as i64);
        }
    }
    bail!("could not find the Apple Live Photo still-image-time track")
}

fn inject_motion_xmp(source: &str, video_length: usize, timestamp_us: i64) -> Result<String> {
    let empty = r#"<x:xmpmeta xmlns:x="adobe:ns:meta/"><rdf:RDF xmlns:rdf="http://www.w3.org/1999/02/22-rdf-syntax-ns#"><rdf:Description rdf:about=""></rdf:Description></rdf:RDF></x:xmpmeta>"#;
    let source = if source.trim().is_empty() {
        empty
    } else {
        source
    };
    if let Some(start) = source.find("<rdf:Description") {
        if let Some(end) = source[start..].find('>') {
            let end = start + end;
            if source[..end].ends_with('/') {
                let expanded = format!(
                    "{}></rdf:Description>{}",
                    &source[..end - 1],
                    &source[end + 1..]
                );
                return inject_motion_xmp(&expanded, video_length, timestamp_us);
            }
        }
    }
    if source.contains("GCamera:MotionPhoto=") || source.contains("Container:Directory") {
        bail!("source already contains Motion Photo metadata");
    }
    let description = source
        .find("<rdf:Description")
        .context("source XMP has no rdf:Description")?;
    let tag_end = description
        + source[description..]
            .find('>')
            .context("source XMP has an unterminated rdf:Description tag")?;
    let close = source[tag_end..]
        .find("</rdf:Description>")
        .map(|offset| tag_end + offset)
        .context("source XMP has no closing rdf:Description tag")?;

    let attributes = format!(
        "\n            xmlns:GCamera=\"http://ns.google.com/photos/1.0/camera/\"\n            xmlns:Container=\"http://ns.google.com/photos/1.0/container/\"\n            xmlns:Item=\"http://ns.google.com/photos/1.0/container/item/\"\n            GCamera:MotionPhoto=\"1\"\n            GCamera:MotionPhotoVersion=\"1\"\n            GCamera:MotionPhotoPresentationTimestampUs=\"{timestamp_us}\""
    );
    let directory = format!(
        r#"
      <Container:Directory>
        <rdf:Seq>
          <rdf:li rdf:parseType="Resource">
            <Container:Item Item:Mime="image/heic" Item:Semantic="Primary" Item:Length="0" Item:Padding="8"/>
          </rdf:li>
          <rdf:li rdf:parseType="Resource">
            <Container:Item Item:Mime="video/quicktime" Item:Semantic="MotionPhoto" Item:Length="{video_length}" Item:Padding="0"/>
          </rdf:li>
        </rdf:Seq>
      </Container:Directory>
    "#
    );

    let mut result = String::with_capacity(source.len() + attributes.len() + directory.len());
    result.push_str(&source[..tag_end]);
    result.push_str(&attributes);
    result.push_str(&source[tag_end..close]);
    result.push_str(&directory);
    result.push_str(&source[close..]);
    Ok(result)
}

fn video_footer_size(video_size: usize) -> usize {
    samsung_footer(&vec![0; video_size], 0).len() - MPVD_BOX_SIZE
}

fn samsung_footer(video: &[u8], image_size: usize) -> Vec<u8> {
    let mut motion_data = b"mpv2".to_vec();
    motion_data.extend_from_slice(&((image_size + MPVD_BOX_SIZE) as i32).to_be_bytes());
    motion_data.extend_from_slice(&(video.len() as i32).to_be_bytes());
    let tags: [([u8; 4], &str, &[u8]); 2] = [
        ([0x00, 0x00, 0x30, 0x0a], "MotionPhoto_Data", &motion_data),
        ([0x00, 0x00, 0x31, 0x0a], "MotionPhoto_Version", b"mpv3"),
    ];

    let mut tag_data = Vec::new();
    let mut lengths = Vec::new();
    for (id, name, data) in &tags {
        let start = tag_data.len();
        tag_data.extend_from_slice(id);
        tag_data.extend_from_slice(&(name.len() as i32).to_le_bytes());
        tag_data.extend_from_slice(name.as_bytes());
        tag_data.extend_from_slice(data);
        lengths.push(tag_data.len() - start);
    }

    let mut sefh = Vec::new();
    sefh.extend_from_slice(b"SEFH");
    sefh.extend_from_slice(&SAMSUNG_SEFH_VERSION.to_le_bytes());
    sefh.extend_from_slice(&(tags.len() as i32).to_le_bytes());
    for index in 0..tags.len() {
        let offset: usize = lengths[index..].iter().sum();
        sefh.extend_from_slice(&tags[index].0);
        sefh.extend_from_slice(&(offset as i32).to_le_bytes());
        sefh.extend_from_slice(&(lengths[index] as i32).to_le_bytes());
    }
    let sefh_len = sefh.len();
    sefh.extend_from_slice(&(sefh_len as i32).to_le_bytes());
    sefh.extend_from_slice(b"SEFT");

    let sefd_size = tag_data.len() + sefh.len() + SEFD_BOX_SIZE;
    let mut body = Vec::with_capacity(MPVD_BOX_SIZE + video.len() + sefd_size);
    body.extend_from_slice(video);
    body.extend_from_slice(&(sefd_size as i32).to_be_bytes());
    body.extend_from_slice(b"sefd");
    body.extend_from_slice(&tag_data);
    body.extend_from_slice(&sefh);

    let mpvd_size = body.len() + MPVD_BOX_SIZE;
    let mut result = Vec::with_capacity(mpvd_size);
    result.extend_from_slice(&(mpvd_size as i32).to_be_bytes());
    result.extend_from_slice(b"mpvd");
    result.extend_from_slice(&body);
    result
}

fn validate_output(exiftool: &Path, output: &Path, video: &[u8]) -> Result<()> {
    let bytes = fs::read(output).context("read completed Motion Photo")?;
    if !bytes.windows(video.len()).any(|window| window == video) {
        bail!("validation failed: prepared video is not embedded byte-for-byte");
    }
    let metadata = exif_json(exiftool, output, false)?;
    let motion = metadata
        .as_object()
        .and_then(|map| map.iter().find(|(key, _)| key.ends_with("MotionPhoto")))
        .and_then(|(_, value)| value.as_i64());
    if motion != Some(1) {
        bail!("validation failed: MotionPhoto metadata is missing");
    }
    Ok(())
}

fn adb_command(adb: &Path, device: Option<&str>) -> Command {
    let mut command = Command::new(adb);
    if let Some(serial) = device {
        command.args(["-s", serial]);
    }
    command
}

fn push(file: &Path, device: Option<&str>, adb: &Path, destination: &str) -> Result<()> {
    ensure_file(file, "prepared Motion Photo")?;
    let filename = file
        .file_name()
        .and_then(OsStr::to_str)
        .context("invalid filename")?;
    let remote = format!("{}/{}", destination.trim_end_matches('/'), filename);
    println!("progress: checking");
    let local_hash = sha256_file(file)?;
    // Retry is idempotent, and incomplete copies never appear in the photo feed.
    if verify_remote_hash(adb, device, &remote, &local_hash).is_err() {
        let destination_id = format!("{:x}", Sha256::digest(remote.as_bytes()));
        let staging =
            format!("/sdcard/Download/.pixelbridge-{local_hash}-{destination_id}.partial");
        let mut mkdir = adb_command(adb, device);
        run_checked(
            mkdir.args(["shell", &format!("mkdir -p {}", shell_quote(destination))]),
            "create destination",
        )?;
        let mut command = adb_command(adb, device);
        println!("progress: transferring");
        run_checked(command.arg("push").arg(file).arg(&staging), "ADB push")?;
        println!("progress: verifying");
        verify_remote_hash(adb, device, &staging, &local_hash)?;
        let mut commit = adb_command(adb, device);
        run_checked(
            commit.args([
                "shell",
                &format!("mv {} {}", shell_quote(&staging), shell_quote(&remote)),
            ]),
            "commit Pixel file",
        )?;
    }
    println!("progress: verifying");
    let mut scan = adb_command(adb, device);
    run_checked(
        scan.args([
            "shell",
            "am",
            "broadcast",
            "-a",
            "android.intent.action.MEDIA_SCANNER_SCAN_FILE",
            "-d",
            &shell_quote(&format!("file://{remote}")),
        ]),
        "Pixel media scan",
    )?;
    verify_remote_hash(adb, device, &remote, &local_hash)?;
    println!("remote: {remote}");
    println!("sha256: {local_hash}");
    println!("delivery: verified and submitted to Android media scanner");
    Ok(())
}

fn verify_device(file: &Path, remote: &str, device: Option<&str>, adb: &Path) -> Result<()> {
    ensure_file(file, "local Motion Photo")?;
    let local_hash = sha256_file(file)?;
    verify_remote_hash(adb, device, remote, &local_hash)?;
    println!("local and Pixel copies match: {local_hash}");
    Ok(())
}

fn device_status(
    device: Option<&str>,
    adb: &Path,
    max_temperature_c: f64,
    min_free_gb: f64,
) -> Result<()> {
    let mut state_command = adb_command(adb, device);
    let state = String::from_utf8(command_stdout_bytes(
        state_command.arg("get-state"),
        "check Pixel connection",
    )?)?;
    if state.trim() != "device" {
        bail!("Pixel is not ready (ADB state={})", state.trim());
    }

    let mut battery_command = adb_command(adb, device);
    let battery = String::from_utf8(command_stdout_bytes(
        battery_command.args(["shell", "dumpsys", "battery"]),
        "read Pixel battery",
    )?)?;
    let level = parse_colon_number(&battery, "level").context("battery level is missing")?;
    let temperature_c = parse_colon_number(&battery, "temperature")
        .context("battery temperature is missing")?
        / 10.0;

    let mut storage_command = adb_command(adb, device);
    let storage = String::from_utf8(command_stdout_bytes(
        storage_command.args(["shell", "df", "-k", "/sdcard"]),
        "read Pixel storage",
    )?)?;
    let available_kb = storage
        .lines()
        .filter(|line| !line.trim().is_empty())
        .next_back()
        .and_then(|line| line.split_whitespace().nth(3))
        .and_then(|value| value.parse::<f64>().ok())
        .context("could not parse Pixel free storage")?;
    let free_gb = available_kb / 1_000_000.0;
    let safe = temperature_c <= max_temperature_c && free_gb >= min_free_gb;
    println!(
        "{}",
        serde_json::json!({
            "connected": true,
            "battery_percent": level,
            "temperature_c": temperature_c,
            "free_gb": free_gb,
            "safe_to_transfer": safe
        })
    );
    if temperature_c > max_temperature_c {
        bail!("Pixel is too warm for a batch ({temperature_c:.1} C > {max_temperature_c:.1} C)");
    }
    if free_gb < min_free_gb {
        bail!(
            "Pixel free space is below the batch reserve ({free_gb:.1} GB < {min_free_gb:.1} GB)"
        );
    }
    Ok(())
}

fn parse_colon_number(input: &str, name: &str) -> Option<f64> {
    input.lines().find_map(|line| {
        let (key, value) = line.trim().split_once(':')?;
        (key == name).then(|| value.trim().parse().ok()).flatten()
    })
}

fn verify_remote_hash(
    adb: &Path,
    device: Option<&str>,
    remote: &str,
    local_hash: &str,
) -> Result<()> {
    let mut command = adb_command(adb, device);
    let output = command_stdout_bytes(
        command.args(["shell", &format!("sha256sum {}", shell_quote(remote))]),
        "hash Pixel file",
    )?;
    let remote_hash = String::from_utf8(output)
        .context("Pixel hash output is not UTF-8")?
        .split_whitespace()
        .next()
        .context("Pixel returned no SHA-256")?
        .to_string();
    if remote_hash != local_hash {
        bail!("Pixel copy hash mismatch: local={local_hash}, remote={remote_hash}");
    }
    Ok(())
}

fn sha256_file(path: &Path) -> Result<String> {
    let mut file = fs::File::open(path).with_context(|| format!("read {}", path.display()))?;
    let mut hash = Sha256::new();
    let mut buffer = [0u8; 64 * 1024];
    loop {
        let n = file.read(&mut buffer)?;
        if n == 0 {
            break;
        }
        hash.update(&buffer[..n]);
    }
    Ok(format!("{:x}", hash.finalize()))
}

fn shell_quote(value: &str) -> String {
    format!("'{}'", value.replace('\'', "'\\''"))
}

fn command_stdout_bytes(command: &mut Command, label: &str) -> Result<Vec<u8>> {
    let output = command.output().with_context(|| format!("start {label}"))?;
    check_output(output, label).map(|output| output.stdout)
}

fn run_checked(command: &mut Command, label: &str) -> Result<()> {
    let output = command.output().with_context(|| format!("start {label}"))?;
    check_output(output, label).map(|_| ())
}

fn check_output(output: Output, label: &str) -> Result<Output> {
    if !output.status.success() {
        bail!(
            "{label} failed ({}): {}",
            output.status,
            String::from_utf8_lossy(&output.stderr).trim()
        );
    }
    Ok(output)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn xmp_missing_and_self_closing_packets_are_supported() {
        assert!(inject_motion_xmp("", 15, 0)
            .unwrap()
            .contains("Item:Length=\"15\""));
        let source = "<rdf:Description rdf:about=\"\" xmp:CreatorTool=\"Apple\"/>";
        let result = inject_motion_xmp(source, 15, 0).unwrap();
        assert!(result.contains("xmp:CreatorTool=\"Apple\""));
        assert!(result.contains("</rdf:Description>"));
    }

    #[test]
    fn remote_paths_are_shell_quoted() {
        assert_eq!(shell_quote("a'b $(id)"), "'a'\\''b $(id)'");
    }

    #[test]
    fn samsung_footer_contains_video_and_boxes() {
        let video = b"test-video";
        let footer = samsung_footer(video, 1234);
        assert_eq!(&footer[4..8], b"mpvd");
        assert!(footer.windows(video.len()).any(|window| window == video));
        assert!(footer.windows(4).any(|window| window == b"sefd"));
        assert!(footer.ends_with(b"SEFT"));
    }

    #[test]
    fn xmp_injection_preserves_source_metadata() {
        let source = r#"<x:xmpmeta><rdf:RDF><rdf:Description rdf:about=""><xmp:CreateDate>now</xmp:CreateDate></rdf:Description></rdf:RDF></x:xmpmeta>"#;
        let result = inject_motion_xmp(source, 99, 1_335_000).unwrap();
        assert!(result.contains("<xmp:CreateDate>now</xmp:CreateDate>"));
        assert!(result.contains("GCamera:MotionPhoto=\"1\""));
        assert!(result.contains("Item:Length=\"99\""));
        assert!(result.contains("1335000"));
    }
}
