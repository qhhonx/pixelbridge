import Foundation
@main struct CleanupSchedulingTests {
 @MainActor static func main() async throws {
  let defaults = UserDefaults.standard
  let keys = ["automatic", "autoReclaimCache", "concurrentTasks", "pixelCleanupEnabled"]
  let saved = keys.map { defaults.object(forKey: $0) }
  defer { for (key,value) in zip(keys,saved) { if let value { defaults.set(value,forKey:key) } else { defaults.removeObject(forKey:key) } } }
  defaults.set(true, forKey: "pixelCleanupEnabled")
  let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
  try ensureDirectory(root.appendingPathComponent("State"))
  defer { try? FileManager.default.removeItem(at: root) }
  let model = BridgeModel(root: root)
  model.autoReclaimCache = false; model.autoRunning = true; model.concurrentTasks = 3
  let items = (0..<3).map { LibraryItem(id: "cleanup-test-\($0)",name:"sample.jpg",date:.distantPast,kind:"photo") }
  model.library = items
  model.testPrepareBatch = {}; model.testGuardDevice = {}
  var cleanups = 0, active = 0, interrupt = true
  model.testCleanup = {
   precondition(active == 0 && model.activeIDs.isEmpty && model.testReservedPixelBytes == 0)
   cleanups += 1
  }
  model.testPrepareItem = { item,_ in
   model.rows.append(QueueRow(asset_id:item.id,filename:item.name,phase:"prepared",timestamp_ms:0,sha256:"verified",remote:nil,message:nil))
   return PreparedDelivery(item:item,file:root.appendingPathComponent(item.id),hash:"verified",bytes:100)
  }
  model.testDeliverItem = { delivery in
   active += 1; defer { active -= 1 }
   if interrupt {
    if delivery.item.id == items[0].id {
     while active < 3 { try await Task.sleep(nanoseconds:1_000_000) }
     throw fail(Message(.error_pixel_storage))
    }
    try await Task.sleep(nanoseconds:60_000_000_000)
   }
   model.rows.removeAll { $0.id == delivery.item.id }
   model.rows.append(QueueRow(asset_id:delivery.item.id,filename:"sample.jpg",phase:"transferred",timestamp_ms:0,sha256:"verified",remote:"/device/sample.jpg",message:nil))
  }
  await model.batch()
  precondition(cleanups == 2 && model.failed == 0 && model.delivered == 0 && active == 0)
  precondition(model.rows.count == 3 && model.rows.allSatisfy { $0.phase == "prepared" })
  interrupt = false
  // Prepared files are reused; do not create duplicate queue rows in the fixture.
  model.testPrepareItem = { item,_ in PreparedDelivery(item:item,file:root.appendingPathComponent(item.id),hash:"verified",bytes:100) }
  await model.batch()
  precondition(cleanups == 3 && model.delivered == 3)
  await model.batch(); precondition(model.completed == 0 && model.delivered == 3)
  model.pause()
  print("PASS: low-space failure drains all concurrent workers before cleanup; prepared progress resumes without repeated delivered jobs")
 }
}
