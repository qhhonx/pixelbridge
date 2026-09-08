use super::*;
use std::{
    path::PathBuf,
    sync::atomic::{AtomicUsize, Ordering},
};

static NEXT: AtomicUsize = AtomicUsize::new(0);
struct Fixture(PathBuf);
impl Fixture {
    fn new() -> Self {
        let path = std::env::temp_dir().join(format!(
            "pixelbridge-sqlite-{}-{}",
            std::process::id(),
            NEXT.fetch_add(1, Ordering::Relaxed)
        ));
        fs::create_dir(&path).unwrap();
        Self(path)
    }
    fn legacy(&self, events: &[QueueEvent], tail: &[u8]) -> Vec<u8> {
        let mut raw = Vec::new();
        for event in events {
            raw.extend(serde_json::to_vec(event).unwrap());
            raw.push(b'\n');
        }
        raw.extend(tail);
        fs::write(self.0.join("queue.jsonl"), &raw).unwrap();
        raw
    }
}
impl Drop for Fixture {
    fn drop(&mut self) {
        let _ = fs::remove_dir_all(&self.0);
    }
}
fn event_count(queue: &Queue) -> i64 {
    queue
        .db
        .query_row("SELECT count(*) FROM events", [], |r| r.get(0))
        .unwrap()
}

#[test]
fn legacy_migration_preserves_all_phases_and_proofs() {
    let fixture = Fixture::new();
    let phases = [
        QueuePhase::Discovered,
        QueuePhase::Exporting,
        QueuePhase::Prepared,
        QueuePhase::Transferred,
        QueuePhase::BackupSeen,
        QueuePhase::MotionVerified,
        QueuePhase::Failed,
    ];
    let events: Vec<_> = phases
        .iter()
        .enumerate()
        .map(|(i, phase)| {
            let mut e = QueueEvent::new(&format!("asset-{i}"), "中文 ' photo.heic", *phase);
            e.sha256 = Some("a".repeat(64));
            e.remote = Some("/sdcard/DCIM/Camera/file.heic".into());
            e.message = Some("retained".into());
            e.timestamp_ms = 1234567890;
            e
        })
        .collect();
    let raw = fixture.legacy(&events, b"{\"interrupted\":");
    fs::write(fixture.0.join("retry.json"), b"untouched retry fixture").unwrap();
    {
        let queue = Queue::open(&fixture.0).unwrap();
        assert_eq!(event_count(&queue), 7);
        for event in &events {
            let item = queue.item(&event.asset_id).unwrap().unwrap();
            assert_eq!(item.phase, event.phase);
            assert_eq!(item.timestamp_ms, event.timestamp_ms);
            assert_eq!(item.sha256, event.sha256);
            assert_eq!(item.remote, event.remote);
            assert_eq!(item.filename, event.filename);
            assert_eq!(item.message, event.message);
        }
        assert_eq!(queue.delivered_copy("asset-3").unwrap().0, "a".repeat(64));
        assert!(queue.delivered_copy("asset-2").is_err());
        assert_eq!(
            queue
                .db
                .query_row("PRAGMA integrity_check", [], |r| r.get::<_, String>(0))
                .unwrap(),
            "ok"
        );
    }
    assert_eq!(fs::read(fixture.0.join("queue.legacy.jsonl")).unwrap(), raw);
    assert_eq!(
        fs::read(fixture.0.join("queue.jsonl")).unwrap(),
        LEGACY_BLOCKER
    );
    assert_eq!(
        fs::read(fixture.0.join("retry.json")).unwrap(),
        b"untouched retry fixture"
    );
    let queue = Queue::open(&fixture.0).unwrap();
    assert_eq!(event_count(&queue), 7);
    queue.add("asset-3", "ignored new name").unwrap();
    assert_eq!(event_count(&queue), 7);
    assert_eq!(
        queue.item("asset-3").unwrap().unwrap().phase,
        QueuePhase::Transferred
    );
}

#[test]
fn corrupt_legacy_rolls_back_without_replacing_original() {
    let fixture = Fixture::new();
    let raw = fixture.legacy(
        &[QueueEvent::new(
            "asset",
            "image.jpg",
            QueuePhase::Discovered,
        )],
        b"invalid-json\n",
    );
    assert!(Queue::open(&fixture.0).is_err());
    assert_eq!(fs::read(fixture.0.join("queue.jsonl")).unwrap(), raw);
    let db = Connection::open(fixture.0.join("queue.sqlite3")).unwrap();
    assert_eq!(
        db.pragma_query_value(None, "user_version", |r| r.get::<_, i64>(0))
            .unwrap(),
        0
    );
    assert_eq!(
        db.query_row(
            "SELECT count(*) FROM sqlite_master WHERE type='table'",
            [],
            |r| r.get::<_, i64>(0)
        )
        .unwrap(),
        0
    );
    drop(db);
    fixture.legacy(
        &[QueueEvent::new(
            "asset",
            "image.jpg",
            QueuePhase::Discovered,
        )],
        b"",
    );
    assert!(Queue::open(&fixture.0)
        .unwrap()
        .item("asset")
        .unwrap()
        .is_some());
}

#[test]
fn events_and_current_state_commit_together_and_are_idempotent() {
    let fixture = Fixture::new();
    let queue = Queue::open(&fixture.0).unwrap();
    queue.add("asset", "image.jpg").unwrap();
    queue.add("asset", "image.jpg").unwrap();
    assert_eq!(event_count(&queue), 1);
    assert!(queue
        .transition("asset", QueuePhase::MotionVerified, None, None, None)
        .is_err());
    queue.db.execute_batch("CREATE TRIGGER fail_update BEFORE UPDATE ON jobs BEGIN SELECT RAISE(ABORT,'injected write failure'); END;").unwrap();
    assert!(queue
        .transition("asset", QueuePhase::Exporting, None, None, None)
        .is_err());
    assert_eq!(event_count(&queue), 1);
    assert_eq!(
        queue.item("asset").unwrap().unwrap().phase,
        QueuePhase::Discovered
    );
    queue.db.execute_batch("DROP TRIGGER fail_update").unwrap();
    queue
        .transition("asset", QueuePhase::Exporting, None, None, None)
        .unwrap();
    queue
        .transition(
            "asset",
            QueuePhase::Prepared,
            Some(&"b".repeat(64)),
            None,
            None,
        )
        .unwrap();
    queue
        .transition(
            "asset",
            QueuePhase::Transferred,
            None,
            Some("/sdcard/file.jpg"),
            None,
        )
        .unwrap();
    queue
        .transition(
            "asset",
            QueuePhase::BackupSeen,
            None,
            None,
            Some("observed"),
        )
        .unwrap();
    queue
        .transition("asset", QueuePhase::BackupSeen, None, None, None)
        .unwrap();
    assert_eq!(event_count(&queue), 5);
    drop(queue);
    let queue = Queue::open(&fixture.0).unwrap();
    let item = queue.item("asset").unwrap().unwrap();
    assert_eq!(item.sha256, Some("b".repeat(64)));
    assert_eq!(item.remote.as_deref(), Some("/sdcard/file.jpg"));
    assert_eq!(item.phase, QueuePhase::BackupSeen);
}

#[test]
fn interrupted_sealing_resumes_without_reimporting() {
    let fixture = Fixture::new();
    let raw = fixture.legacy(
        &[QueueEvent::new(
            "asset",
            "image.jpg",
            QueuePhase::Discovered,
        )],
        b"",
    );
    drop(Queue::open(&fixture.0).unwrap());
    fs::write(fixture.0.join("queue.jsonl"), raw).unwrap();
    let queue = Queue::open(&fixture.0).unwrap();
    assert_eq!(event_count(&queue), 1);
    assert_eq!(
        fs::read(fixture.0.join("queue.jsonl")).unwrap(),
        LEGACY_BLOCKER
    );
}

#[test]
fn changed_legacy_after_commit_is_refused() {
    let fixture = Fixture::new();
    drop(Queue::open(&fixture.0).unwrap());
    let raw = fixture.legacy(
        &[QueueEvent::new(
            "late-old-app",
            "image.jpg",
            QueuePhase::Transferred,
        )],
        b"",
    );
    assert!(Queue::open(&fixture.0).is_err());
    assert_eq!(fs::read(fixture.0.join("queue.jsonl")).unwrap(), raw);
}

#[test]
fn missing_corrupt_and_future_databases_never_reset_progress() {
    let fixture = Fixture::new();
    drop(Queue::open(&fixture.0).unwrap());
    fs::remove_file(fixture.0.join("queue.sqlite3")).unwrap();
    assert!(Queue::open(&fixture.0).is_err());
    fs::write(fixture.0.join("queue.sqlite3"), b"not a SQLite database").unwrap();
    assert!(Queue::open(&fixture.0).is_err());
    assert_eq!(
        fs::read(fixture.0.join("queue.sqlite3")).unwrap(),
        b"not a SQLite database"
    );
    let future = Fixture::new();
    let queue = Queue::open(&future.0).unwrap();
    queue.db.pragma_update(None, "user_version", 999).unwrap();
    drop(queue);
    assert!(Queue::open(&future.0).is_err());
}
