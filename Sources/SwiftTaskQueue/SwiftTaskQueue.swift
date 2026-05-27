import Foundation

/// A serial queue that executes async tasks one at a time, in the order they were enqueued.
///
/// `TaskQueue` guarantees that no two tasks run concurrently, regardless of how many callers
/// enqueue work simultaneously. Tasks are started in strict FIFO order.
///
/// ```swift
/// let queue = TaskQueue()
///
/// // Fire and forget
/// queue.dispatch { await doWork() }
///
/// // Enqueue and await the result
/// let value = try await queue.dispatchAndWait { try await fetch() }
///
/// // Enqueue without blocking the caller, await the result later
/// let task = queue.dispatchTask { try await fetch() }
/// // ... do other work ...
/// let value = try await task.value
///
/// // Stream results from a queued task
/// let stream = queue.dispatchStream { continuation in
///     continuation.yield(1)
///     continuation.finish()
/// }
/// ```
public class TaskQueue{

    // MARK: - Private task types

    /// Base class for all pending tasks held in the queue.
    private class PendingTask{
        let label:String?
        /// Set to `true` by the cancellation handler before the task is dequeued,
        /// causing the queue to skip it without executing the block.
        var isCancelled = false
        init(label: String? = nil) {
            self.label = label
        }
    }

    /// A task whose block produces a single value (or throws), delivered via `onComplete`.
    private class AsyncTask : PendingTask {
        /// Called by the queue with the block's result. `nil` for fire-and-forget tasks.
        let onComplete: ((Result<Any,Error>) -> Void)?
        let block: () async throws -> Any

        init(label: String?, onComplete: ((Result<Any,Error>) -> Void)?, block: @escaping () async throws -> Any) {
            self.onComplete = onComplete
            self.block = block
            super.init(label: label)
        }
    }

    /// A task whose block produces a stream of values, forwarded through an
    /// `AsyncThrowingStream.Continuation`.
    private class StreamTask : PendingTask{
        let continuation: AsyncThrowingStream<Any,Error>.Continuation
        let block: (AsyncThrowingStream<Any,Error>.Continuation) -> Void

        init(label: String?, continuation: AsyncThrowingStream<Any,Error>.Continuation, block: @escaping (AsyncThrowingStream<Any,Error>.Continuation) -> Void) {
            self.continuation = continuation
            self.block = block
            super.init(label: label)
        }
    }

    // MARK: - ResultBox

    /// Bridges a callback-based result delivery to an `async` awaiter.
    ///
    /// Because `dispatchTask` must enqueue synchronously (before returning), it cannot use
    /// `withCheckedThrowingContinuation` at the call site — that requires an `async` context.
    /// `ResultBox` decouples the two sides: the queue calls `deliver` when the block finishes,
    /// and the caller calls `awaitResult` when it is ready for the value. Either side may arrive
    /// first; the lock ensures the rendezvous is always correct.
    ///
    /// **Race scenarios**
    /// - *Normal case — `awaitResult` first:* the continuation is stored; `deliver` resumes it.
    /// - *Fast case — `deliver` first:* the result is stored; `awaitResult` resumes immediately
    ///   without ever suspending.
    private class ResultBox<T> {
        private let lock = NSLock()
        private var result: Result<T,Error>?
        private var continuation: CheckedContinuation<T,Error>?

        /// Called by the queue when the block finishes. Resumes a waiting `awaitResult` call,
        /// or stores the result for the next `awaitResult` call.
        func deliver(_ result: Result<T,Error>) {
            lock.lock()
            defer { lock.unlock() }
            if let cont = continuation {
                continuation = nil
                cont.resume(with: result)
            } else {
                self.result = result
            }
        }

        /// Suspends until `deliver` is called, or returns immediately if the result is
        /// already available.
        func awaitResult() async throws -> T {
            return try await withCheckedThrowingContinuation { cont in
                lock.lock()
                defer { lock.unlock() }
                if let result = result {
                    self.result = nil
                    cont.resume(with: result)
                } else {
                    continuation = cont
                }
            }
        }
    }

    // MARK: - Queue state

    /// Optional label used for debugging and logging.
    public let label:String?

    private var pendingTasksContinuation: AsyncStream<PendingTask>.Continuation

    private var pendingTasks: AsyncStream<PendingTask>

    private var scope: Task<Void,Never>?

    /// Set to `true` by `close()` to signal the scope loop to stop after the current task.
    private var isScopeCancelled = false

    // MARK: - Scope

    /// Starts the internal serial execution loop.
    ///
    /// The loop drains `pendingTasks` one at a time. When `isScopeCancelled` becomes `true`
    /// or the Swift task is cancelled, the loop breaks and a second pass drains any remaining
    /// tasks, failing them all with `CancellationError`.
    private func initScope()
    {
        scope = Task{
            for await pendingTask in pendingTasks
            {
//                print("PendingTask \(pendingTask.label ?? "") received", label ?? "")
//                print("\(label ?? "TaskQueue"): scope isCancelled \(Task.isCancelled)")
                if(Task.isCancelled){ break }
                if(isScopeCancelled){ break }
                if(pendingTask.isCancelled) { continue }
                if let task = pendingTask as? AsyncTask
                {
                    do{
//                        print("AsyncTask \(pendingTask.tag ?? "") start",source: tag)
                        let result = try await task.block()
//                        print("AsyncTask \(pendingTask.tag ?? "") resume",source: tag)
                        task.onComplete?(.success(result))
                    }
                    catch
                    {
//                        log.error("AsyncTask \(pendingTask.tag ?? "") error \(error)",source: tag)
                        task.onComplete?(.failure(error))
                    }
                }
                else if let task = pendingTask as? StreamTask
                {
                    do
                    {
//                        print("StreamTask \(pendingTask.tag ?? "") start",source: tag)
                        for try await value in AsyncThrowingStream(Any.self, task.block)
                        {
                            //check task cancelled
//                            print("StreamTask cancelled=\(Task.isCancelled)")
                            if(isScopeCancelled){ throw CancellationError() }
//                            print("StreamTask \(pendingTask.tag ?? "") yield",source: tag)
                            task.continuation.yield(value)
                        }
//                        print("StreamTask \(pendingTask.tag ?? "") finish",source: tag)
                        task.continuation.finish()
                    }
                    catch
                    {
//                        print("StreamTask error \(error)")
//                        log.error("StreamTask \(pendingTask.tag ?? "") error \(error)",source: tag)
                        task.continuation.finish(throwing: error)
                    }

                }
                else
                {
//                    print("PendingTask discard \(pendingTask)", label ?? "")
                }
                if(Task.isCancelled){ break }
                if(isScopeCancelled){ break }
            }
            // Drain remaining tasks after the queue is closed, failing each one.
            for await pendingTask in pendingTasks
            {
                if let task = pendingTask as? AsyncTask
                {
                    task.onComplete?(.failure(CancellationError()))
                }
                else if let task = pendingTask as? StreamTask
                {
                    task.continuation.finish(throwing: CancellationError())
                }
            }
        }
    }

    // MARK: - Lifecycle

    /// Creates a new `TaskQueue` and starts its internal execution loop.
    /// - Parameter label: An optional name for debugging purposes.
    public init(label: String? = nil){
        self.label = label
        (pendingTasks,pendingTasksContinuation) = AsyncStream.makeStream()
        initScope()
    }

    /// Signals the queue to stop accepting new work after the current task finishes.
    ///
    /// Any tasks already in the queue when `close()` is called will be cancelled and their
    /// callers will receive a `CancellationError`. Tasks enqueued after `close()` are ignored.
    public func close()
    {
        if !isScopeCancelled
        {
            isScopeCancelled = true
        }
    }

    // MARK: - Enqueue

    /// Enqueues a fire-and-forget task and returns immediately.
    ///
    /// The block is executed when it reaches the front of the queue. There is no way to
    /// observe the result or whether the block throws — use `dispatchAndWait` or
    /// `dispatchTask` if you need the outcome.
    ///
    /// This method is synchronous and non-blocking; it is safe to call from any context.
    ///
    /// - Parameters:
    ///   - label: An optional name for debugging purposes.
    ///   - block: The async work to execute.
    public func dispatch(label:String?=nil,block: @escaping () async throws -> Void)
    {
        pendingTasksContinuation.yield(AsyncTask(label: label, onComplete: nil, block: block))
    }

    /// Enqueues a task and suspends the caller until the block finishes, returning its result.
    ///
    /// The caller is suspended for the entire time the task waits in the queue *and* while it
    /// executes. If the calling `Task` is cancelled before the block starts, the queued task is
    /// skipped and a `CancellationError` is thrown.
    ///
    /// - Parameters:
    ///   - label: An optional name for debugging purposes.
    ///   - block: The async work to execute.
    /// - Returns: The value returned by `block`.
    /// - Throws: Any error thrown by `block`, or `CancellationError` if cancelled.
    public func dispatchAndWait<T>(label:String?=nil,block: @escaping () async throws -> T) async throws -> T
    {
        var pendingTask : AsyncTask?
        let cancel = { pendingTask?.isCancelled = true }
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<T,Error>) in
                let task = AsyncTask(label: label, onComplete: { result in
                    continuation.resume(with: result.map { $0 as! T })
                }, block: block)
                pendingTask = task
                pendingTasksContinuation.yield(task)
            }
        } onCancel: {
            cancel()
        }
    }

    /// Enqueues a task and returns a `Task` handle immediately, without waiting for the result.
    ///
    /// Unlike `dispatchAndWait`, this method does not suspend the caller. The block is placed
    /// in the queue synchronously at the point of the call, so ordering relative to other
    /// `dispatch` / `dispatchTask` calls made on the same queue is preserved. The caller can
    /// await the result at any later point via the returned `Task`.
    ///
    /// ```swift
    /// let task = queue.dispatchTask { try await fetch() }
    /// // enqueue more work, do other things...
    /// let value = try await task.value  // block here when ready
    /// ```
    ///
    /// - Parameters:
    ///   - label: An optional name for debugging purposes.
    ///   - block: The async work to execute.
    /// - Returns: A `Task<T, Error>` whose `value` resolves to the block's return value.
    public func dispatchTask<T>(label:String?=nil,block: @escaping () async throws -> T) -> Task<T,Error>
    {
        let resultBox = ResultBox<T>()
        var pendingTask : AsyncTask?
        let cancel = { pendingTask?.isCancelled = true }
        let task = AsyncTask(label: label, onComplete: { result in
            resultBox.deliver(result.map { $0 as! T })
        }, block: block)
        pendingTask = task
        pendingTasksContinuation.yield(task)  // synchronous — preserves queue order
        return Task {
            try await withTaskCancellationHandler {
                try await resultBox.awaitResult()
            } onCancel: {
                cancel()
            }
        }
    }

    /// Enqueues a streaming task and returns an `AsyncThrowingStream` of its values.
    ///
    /// The stream is backed by the queue — only one streaming task runs at a time, and it
    /// blocks all subsequent tasks until it calls `continuation.finish()`. Make sure every
    /// code path in `block` eventually calls `finish()` or `finish(throwing:)`, otherwise
    /// the queue will stall indefinitely.
    ///
    /// ```swift
    /// let stream = queue.dispatchStream { continuation in
    ///     Task {
    ///         for item in items { continuation.yield(item) }
    ///         continuation.finish()
    ///     }
    /// }
    /// for try await value in stream { ... }
    /// ```
    ///
    /// - Parameters:
    ///   - label: An optional name for debugging purposes.
    ///   - block: A closure that receives a typed continuation and is responsible for
    ///     yielding values and finishing the stream.
    /// - Returns: An `AsyncThrowingStream<T, Error>` that emits the values produced by `block`.
    public func dispatchStream<T>( label:String?=nil, block:@escaping (AsyncThrowingStream<T,Error>.Continuation) -> Void) -> AsyncThrowingStream<T,Error>
    {
        let anyStream = AsyncThrowingStream<Any,Error> { continuation in
            pendingTasksContinuation.yield(StreamTask(label: label, continuation: continuation, block: { anyContinuation in

                Task{
                    do
                    {
                        for try await element in AsyncThrowingStream(T.self,block)
                        {
                            anyContinuation.yield(element)
                        }
                        anyContinuation.finish()
                    }
                    catch
                    {
                        anyContinuation.finish(throwing: error)
                    }
                }
            }))
        }
        return AsyncThrowingStream<T,Error> { typedContinuation in
            Task
            {
                do{
                    for try await element in anyStream
                    {
                        typedContinuation.yield(element as! T)
                    }
                    typedContinuation.finish()
                }
                catch
                {
                    typedContinuation.finish(throwing: error)
                }
            }
        }
    }
}
