use anyhow::{bail, Context, Result};
use clap::ValueEnum;
use rusqlite::{params, Connection, OptionalExtension};
use serde::{Deserialize, Serialize};
use sha2::{Digest, Sha256};
use std::fs::{self, OpenOptions};
use std::io::Write;
use std::os::fd::AsRawFd;
use std::path::Path;
use std::time::{Duration, SystemTime, UNIX_EPOCH};
extern "C" {
    fn flock(fd: i32, operation: i32) -> i32;
}
const PROTOCOL_VERSION: u8 = 1;

#[derive(Clone, Copy, Debug, Deserialize, Eq, PartialEq, Serialize, ValueEnum)]
#[serde(rename_all = "snake_case")]
pub enum QueuePhase {
    Discovered,
    Exporting,
    Prepared,
    Transferred,
    BackupSeen,
    MotionVerified,
    Failed,
}

#[derive(Clone, Debug, Deserialize, Serialize)]
struct QueueEvent {
    protocol: u8,
    timestamp_ms: u128,
    asset_id: String,
    filename: String,
    phase: QueuePhase,
    #[serde(skip_serializing_if = "Option::is_none")]
    sha256: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    remote: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    message: Option<String>,
}

#[derive(Debug, PartialEq, Serialize)]
struct QueueItem {
    asset_id: String,
    filename: String,
    phase: QueuePhase,
    timestamp_ms: u128,
    #[serde(skip_serializing_if = "Option::is_none")]
    sha256: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    remote: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    message: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    bytes: Option<i64>,
}

const LEGACY_BLOCKER: &[u8] = br#"{"protocol":2,"timestamp_ms":0,"asset_id":"sqlite-migration","filename":"queue.sqlite3","phase":"discovered","message":"State migrated to SQLite. Use PixelBridge 0.3.4 or newer."}
"#;

impl QueuePhase {
    fn key(self) -> &'static str {
        match self {
            Self::Discovered => "discovered",
            Self::Exporting => "exporting",
            Self::Prepared => "prepared",
            Self::Transferred => "transferred",
            Self::BackupSeen => "backup_seen",
            Self::MotionVerified => "motion_verified",
            Self::Failed => "failed",
        }
    }
}
pub struct Queue {
    db: Connection,
    _lock: fs::File,
}
impl Queue {
    pub fn open(state_dir: &Path) -> Result<Self> {
        fs::create_dir_all(state_dir)?;
        let lock = OpenOptions::new()
            .create(true)
            .truncate(false)
            .read(true)
            .write(true)
            .open(state_dir.join("queue.lock"))?;
        // Hold across migration, transactions and cache deletion. Old cores use this same lock.
        if unsafe { flock(lock.as_raw_fd(), 2) } != 0 {
            bail!("cannot lock queue");
        }
        let db = Connection::open(state_dir.join("queue.sqlite3"))
            .context("open backup database; progress was not reset")?;
        db.busy_timeout(Duration::from_secs(30))?;
        db.pragma_update(None, "journal_mode", "WAL")?;
        db.pragma_update(None, "synchronous", "FULL")?;
        let version: i64 = db.pragma_query_value(None, "user_version", |row| row.get(0))?;
        match version {
            0 => Self::migrate(&db, state_dir)?,
            1 => {}
            _ => bail!("unsupported backup database version: {version}; use a newer PixelBridge"),
        }
        Self::seal_legacy(&db, state_dir)?;
        // Additive optional metadata keeps existing progress and older readers intact.
        db.execute_batch(
            "CREATE TABLE IF NOT EXISTS job_details (
            asset_id TEXT PRIMARY KEY NOT NULL, bytes INTEGER NOT NULL CHECK(bytes >= 0));",
        )?;
        Ok(Self { db, _lock: lock })
    }
    fn migrate(db: &Connection, state_dir: &Path) -> Result<()> {
        let journal = state_dir.join("queue.jsonl");
        let raw = read_optional(&journal)?;
        if raw == LEGACY_BLOCKER {
            bail!("SQLite progress database is missing or incomplete; restore State instead of starting over");
        }
        let complete = raw.iter().rposition(|b| *b == b'\n').map_or(0, |i| i + 1);
        let tx = db.unchecked_transaction()?;
        tx.execute_batch("CREATE TABLE jobs (
            asset_id TEXT PRIMARY KEY NOT NULL, filename TEXT NOT NULL, phase TEXT NOT NULL,
            timestamp_ms INTEGER NOT NULL CHECK(timestamp_ms >= 0), sha256 TEXT, remote TEXT, message TEXT);
            CREATE INDEX jobs_phase ON jobs(phase);
            CREATE TABLE events (sequence INTEGER PRIMARY KEY, asset_id TEXT NOT NULL, event_json TEXT NOT NULL);
            CREATE INDEX events_asset ON events(asset_id);
            CREATE TABLE metadata (key TEXT PRIMARY KEY NOT NULL, value TEXT NOT NULL);")?;
        for (index, line) in raw[..complete].split(|b| *b == b'\n').enumerate() {
            if line.iter().all(u8::is_ascii_whitespace) {
                continue;
            }
            let event: QueueEvent = serde_json::from_slice(line).with_context(|| {
                format!(
                    "legacy queue line {} is invalid; migration stopped, original retained",
                    index + 1
                )
            })?;
            if event.protocol != PROTOCOL_VERSION {
                bail!("unsupported queue protocol version: {}", event.protocol);
            }
            Self::write_event(&tx, &event)?;
        }
        if journal.exists() {
            // Exact backup includes any interrupted trailing record. Never overwrite a different backup.
            let backup = state_dir.join("queue.legacy.jsonl");
            if backup.exists() {
                if fs::read(&backup)? != raw {
                    bail!("legacy backup differs; migration stopped without overwriting it");
                }
            } else {
                let temporary = state_dir.join("queue-legacy-backup.tmp");
                let mut file = fs::File::create(&temporary)?;
                file.write_all(&raw)?;
                file.sync_all()?;
                fs::rename(temporary, &backup)?;
                fs::File::open(state_dir)?.sync_all()?;
            }
        }
        tx.execute(
            "INSERT INTO metadata(key,value) VALUES('legacy_sha256',?1)",
            [format!("{:x}", Sha256::digest(&raw))],
        )?;
        tx.execute(
            "INSERT INTO metadata(key,value) VALUES('legacy_trailing_bytes',?1)",
            [(raw.len() - complete).to_string()],
        )?;
        tx.pragma_update(None, "user_version", 1)?;
        tx.commit()?;
        Ok(())
    }
    fn seal_legacy(db: &Connection, state_dir: &Path) -> Result<()> {
        let journal = state_dir.join("queue.jsonl");
        let raw = read_optional(&journal)?;
        if raw == LEGACY_BLOCKER {
            return Ok(());
        }
        let expected: String = db.query_row(
            "SELECT value FROM metadata WHERE key='legacy_sha256'",
            [],
            |row| row.get(0),
        )?;
        if format!("{:x}", Sha256::digest(&raw)) != expected {
            bail!("legacy queue changed after migration; stop the old app and reconcile progress before continuing");
        }
        // Database commits first; interrupted sealing resumes without importing twice.
        let temporary = state_dir.join("queue-migration-marker.tmp");
        let mut file = fs::File::create(&temporary)?;
        file.write_all(LEGACY_BLOCKER)?;
        file.sync_all()?;
        fs::rename(temporary, journal)?;
        fs::File::open(state_dir)?.sync_all()?;
        Ok(())
    }
    pub fn add(&self, asset_id: &str, filename: &str) -> Result<()> {
        if let Some(item) = self.item(asset_id)? {
            println!("{}", serde_json::to_string(&item)?);
            return Ok(());
        }
        let event = QueueEvent::new(asset_id, filename, QueuePhase::Discovered);
        self.append(&event)?;
        println!("{}", serde_json::to_string(&event)?);
        Ok(())
    }
    pub fn transition(
        &self,
        asset_id: &str,
        phase: QueuePhase,
        sha256: Option<&str>,
        remote: Option<&str>,
        message: Option<&str>,
    ) -> Result<()> {
        let current = self
            .item(asset_id)?
            .with_context(|| format!("asset is not in queue: {asset_id}"))?;
        if current.phase == phase {
            println!("{}", serde_json::to_string(&current)?);
            return Ok(());
        }
        if !valid_transition(current.phase, phase) {
            bail!(
                "invalid queue transition for {asset_id}: {:?} -> {:?}",
                current.phase,
                phase
            );
        }
        let event = QueueEvent {
            protocol: PROTOCOL_VERSION,
            timestamp_ms: now_ms()?,
            asset_id: asset_id.to_owned(),
            filename: current.filename,
            phase,
            sha256: sha256.map(str::to_owned).or(current.sha256),
            remote: remote.map(str::to_owned).or(current.remote),
            message: message.map(str::to_owned),
        };
        self.append(&event)?;
        println!(
            "{}",
            serde_json::to_string(&self.item(asset_id)?.context("queue item disappeared")?)?
        );
        Ok(())
    }
    pub fn set_size(&self, asset_id: &str, bytes: i64) -> Result<()> {
        if bytes < 0 {
            bail!("file size must not be negative");
        }
        self.item(asset_id)?.context("asset is not in queue")?;
        self.db.execute(
            "INSERT INTO job_details(asset_id,bytes) VALUES(?1,?2)
            ON CONFLICT(asset_id) DO UPDATE SET bytes=excluded.bytes",
            params![asset_id, bytes],
        )?;
        println!(
            "{}",
            serde_json::to_string(&self.item(asset_id)?.context("queue item disappeared")?)?
        );
        Ok(())
    }
    pub fn print_json(&self) -> Result<()> {
        let mut statement = self.db.prepare("SELECT asset_id, filename, phase, timestamp_ms, sha256, remote, message, (SELECT bytes FROM job_details WHERE job_details.asset_id=jobs.asset_id) FROM jobs ORDER BY asset_id")?;
        let items = statement
            .query_map([], Self::read_item)?
            .collect::<rusqlite::Result<Vec<_>>>()?;
        println!("{}", serde_json::to_string_pretty(&items)?);
        Ok(())
    }
    pub fn delivered_copy(&self, asset_id: &str) -> Result<(String, String)> {
        let item = self
            .item(asset_id)?
            .context("cache asset is not in queue")?;
        if !matches!(
            item.phase,
            QueuePhase::Transferred | QueuePhase::BackupSeen | QueuePhase::MotionVerified
        ) {
            bail!("cache asset has no completed delivery record");
        }
        let hash = item.sha256.context("delivery hash is missing")?;
        if hash.len() != 64 || !hash.bytes().all(|c| c.is_ascii_hexdigit()) {
            bail!("delivery hash is invalid");
        }
        Ok((hash, item.remote.context("delivery path is missing")?))
    }
    fn item(&self, asset_id: &str) -> Result<Option<QueueItem>> {
        Ok(self.db.query_row("SELECT asset_id, filename, phase, timestamp_ms, sha256, remote, message, (SELECT bytes FROM job_details WHERE job_details.asset_id=jobs.asset_id) FROM jobs WHERE asset_id=?1", [asset_id], Self::read_item).optional()?)
    }
    fn read_item(row: &rusqlite::Row<'_>) -> rusqlite::Result<QueueItem> {
        let key: String = row.get(2)?;
        let phase = serde_json::from_value(serde_json::Value::String(key)).map_err(|e| {
            rusqlite::Error::FromSqlConversionFailure(2, rusqlite::types::Type::Text, Box::new(e))
        })?;
        Ok(QueueItem {
            asset_id: row.get(0)?,
            filename: row.get(1)?,
            phase,
            timestamp_ms: row.get::<_, i64>(3)? as u128,
            sha256: row.get(4)?,
            remote: row.get(5)?,
            message: row.get(6)?,
            bytes: row.get(7)?,
        })
    }
    fn write_event(db: &Connection, event: &QueueEvent) -> Result<()> {
        let timestamp =
            i64::try_from(event.timestamp_ms).context("queue timestamp exceeds SQLite range")?;
        db.execute(
            "INSERT INTO events(asset_id,event_json) VALUES(?1,?2)",
            params![event.asset_id, serde_json::to_string(event)?],
        )?;
        db.execute("INSERT INTO jobs(asset_id,filename,phase,timestamp_ms,sha256,remote,message) VALUES(?1,?2,?3,?4,?5,?6,?7)
            ON CONFLICT(asset_id) DO UPDATE SET filename=excluded.filename,phase=excluded.phase,timestamp_ms=excluded.timestamp_ms,sha256=excluded.sha256,remote=excluded.remote,message=excluded.message",
            params![event.asset_id, event.filename, event.phase.key(), timestamp, event.sha256, event.remote, event.message])?;
        Ok(())
    }
    fn append(&self, event: &QueueEvent) -> Result<()> {
        let tx = self.db.unchecked_transaction()?;
        Self::write_event(&tx, event)?;
        tx.commit()?;
        Ok(())
    }
}
fn read_optional(path: &Path) -> Result<Vec<u8>> {
    match fs::read(path) {
        Ok(b) => Ok(b),
        Err(e) if e.kind() == std::io::ErrorKind::NotFound => Ok(Vec::new()),
        Err(e) => Err(e.into()),
    }
}
impl QueueEvent {
    fn new(asset_id: &str, filename: &str, phase: QueuePhase) -> Self {
        Self {
            protocol: PROTOCOL_VERSION,
            timestamp_ms: now_ms().unwrap_or_default(),
            asset_id: asset_id.to_owned(),
            filename: filename.to_owned(),
            phase,
            sha256: None,
            remote: None,
            message: None,
        }
    }
}

fn now_ms() -> Result<u128> {
    Ok(SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .context("system clock is before Unix epoch")?
        .as_millis())
}

fn valid_transition(from: QueuePhase, to: QueuePhase) -> bool {
    use QueuePhase::*;
    matches!(
        (from, to),
        (Discovered, Exporting)
            | (Exporting, Prepared)
            | (Prepared, Transferred)
            | (Transferred, BackupSeen)
            | (BackupSeen, MotionVerified)
            | (
                Discovered | Exporting | Prepared | Transferred | BackupSeen,
                Failed
            )
            | (Failed, Exporting)
    )
}

#[cfg(test)]
#[path = "queue_tests.rs"]
mod tests;
