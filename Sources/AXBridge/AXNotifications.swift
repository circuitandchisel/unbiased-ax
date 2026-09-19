import ApplicationServices
import Foundation

/// The app telling us it changed something, instead of us asking.
///
/// Every other signal this bridge has is a read: we perform an action, then
/// ask the accessibility layer what the element holds now. That layer can
/// report a control's PREVIOUS value for hundreds of milliseconds after a
/// write, and an entire previous document after a navigation — so a read taken
/// to confirm an action can confirm the state before it. Two reads agreeing
/// does not help, because they lag together.
///
/// A notification is different in kind. It is posted BY the application when
/// the value actually changes, and it cannot arrive before the change it
/// describes. That makes it the first evidence in this bridge that does not
/// come from asking the thing that lags.
///
/// The cost is a run loop. Notifications are delivered to a CFRunLoop, and the
/// bridge's own loop is a blocking `readLine` over stdio with no run loop at
/// all — deliberately, because a run loop on the main thread would have to be
/// pumped between requests and would make every request's timing depend on
/// what the observed apps happen to be doing. So this owns a thread of its own
/// and hands events back under a lock.
public final class AXNotifications {
  public static let shared = AXNotifications()

  /// One notification, as it arrived.
  struct Event {
    let element: AXUIElement
    let name: String
    let at: Date
  }

  private let lock = NSLock()
  private var observers: [pid_t: AXObserver] = [:]
  /// What is already being watched, so a second watch of the same thing is
  /// free rather than a duplicate registration.
  private var watching: Set<WatchKey> = []
  private var events: [Event] = []
  private var runLoop: CFRunLoop?
  private var started = false

  struct WatchKey: Hashable {
    let pid: pid_t
    let element: AXElement
    let name: String
  }

  /// Kept small. These exist to answer "did this change in the last moment",
  /// which needs the recent past and nothing else; an unbounded list would
  /// grow for the life of the process and is the shape of leak nobody notices.
  static let maxEvents = 500

  private init() {}

  /// Starts the observer thread. Idempotent, and waits for the run loop to
  /// exist before returning — a source added to a nil run loop is silently
  /// dropped, and the failure looks exactly like an app that posts nothing.
  public func start() {
    lock.lock()
    if started { lock.unlock(); return }
    started = true
    lock.unlock()

    let ready = DispatchSemaphore(value: 0)
    let thread = Thread { [weak self] in
      guard let self else { return }
      self.lock.lock()
      self.runLoop = CFRunLoopGetCurrent()
      self.lock.unlock()
      // A run loop with no sources returns immediately. This one is a port
      // nothing ever sends to: it exists to keep the loop alive between
      // notifications.
      var context = CFRunLoopSourceContext()
      if let keepAlive = CFRunLoopSourceCreate(kCFAllocatorDefault, 0, &context) {
        CFRunLoopAddSource(CFRunLoopGetCurrent(), keepAlive, .commonModes)
      }
      ready.signal()
      CFRunLoopRun()
    }
    thread.name = "unbiased-ax.notifications"
    thread.stackSize = 512 * 1024
    thread.start()
    _ = ready.wait(timeout: .now() + 2)
  }

  /// Watch one element for one notification. Returns false when the element
  /// refuses — which is information, not an error: an element that will not be
  /// observed cannot be confirmed this way, and the caller should fall back
  /// rather than wait for something that will never arrive.
  @discardableResult
  public func watch(pid: pid_t, element: AXUIElement, notification: String) -> Bool {
    start()
    let key = WatchKey(pid: pid, element: AXElement(ref: element), name: notification)
    lock.lock()
    if watching.contains(key) { lock.unlock(); return true }
    var observer = observers[pid]
    lock.unlock()

    if observer == nil {
      var made: AXObserver?
      let err = AXObserverCreate(pid, Self.callback, &made)
      guard err == .success, let made else { return false }
      observer = made
      lock.lock()
      observers[pid] = made
      let loop = runLoop
      lock.unlock()
      if let loop { CFRunLoopAddSource(loop, AXObserverGetRunLoopSource(made), .commonModes) }
    }
    guard let observer else { return false }
    let err = AXObserverAddNotification(observer, element, notification as CFString,
                                        UnsafeMutableRawPointer(Unmanaged.passUnretained(self).toOpaque()))
    // Already registered is success: two callers wanting the same evidence is
    // not a conflict.
    guard err == .success || err == .notificationAlreadyRegistered else { return false }
    lock.lock(); watching.insert(key); lock.unlock()
    return true
  }

  private static let callback: AXObserverCallback = { _, element, name, refcon in
    guard let refcon else { return }
    let me = Unmanaged<AXNotifications>.fromOpaque(refcon).takeUnretainedValue()
    me.record(Event(element: element, name: name as String, at: Date()))
  }

  private func record(_ e: Event) {
    lock.lock()
    events.append(e)
    if events.count > Self.maxEvents { events.removeFirst(events.count - Self.maxEvents) }
    lock.unlock()
  }

  /// A moment to measure from. Taken BEFORE the action, so a notification that
  /// arrives afterwards is known to be about it.
  public func mark() -> Date { Date() }

  /// Whether this element posted this notification since `mark`.
  ///
  /// Elements are compared with CFEqual rather than by pointer: the same
  /// control can arrive as different proxy objects, and pointer equality
  /// misses the match — which here would read as "the app said nothing".
  public func fired(element: AXUIElement, notification: String, since mark: Date) -> Bool {
    lock.lock()
    defer { lock.unlock() }
    return events.contains { $0.at >= mark && $0.name == notification && CFEqual($0.element, element) }
  }

  /// Waits up to `timeout` for the notification, returning as soon as it
  /// arrives. Polling a local array is not the cost here; the alternative is
  /// sleeping the full deadline on every write that lands quickly.
  public func await(element: AXUIElement, notification: String, since mark: Date, timeout: TimeInterval) -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
      if fired(element: element, notification: notification, since: mark) { return true }
      Thread.sleep(forTimeInterval: 0.02)
    }
    return fired(element: element, notification: notification, since: mark)
  }

  /// For diagnostics: how many events are held, and whether the thread is up.
  public var state: (running: Bool, events: Int, apps: Int) {
    lock.lock()
    defer { lock.unlock() }
    return (runLoop != nil, events.count, observers.count)
  }
}
