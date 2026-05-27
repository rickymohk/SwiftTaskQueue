import Foundation

public class TaskQueue{
    private class PendingTask{
        let label:String?
        var isCancelled = false
        init(label: String? = nil) {
            self.label = label
        }
    }
    private class AsyncTask : PendingTask {
        let onComplete: ((Result<Any,Error>) -> Void)?
        let block: () async throws -> Any

        init(label: String?, onComplete: ((Result<Any,Error>) -> Void)?, block: @escaping () async throws -> Any) {
            self.onComplete = onComplete
            self.block = block
            super.init(label: label)
        }
    }

    private class StreamTask : PendingTask{
        let continuation: AsyncThrowingStream<Any,Error>.Continuation
        let block: (AsyncThrowingStream<Any,Error>.Continuation) -> Void

        init(label: String?, continuation: AsyncThrowingStream<Any,Error>.Continuation, block: @escaping (AsyncThrowingStream<Any,Error>.Continuation) -> Void) {
            self.continuation = continuation
            self.block = block
            super.init(label: label)
        }
    }

    // Bridges a callback-based result delivery to an async awaiter, with a lock
    // to handle the race between the result arriving before or after await() is called.
    private class ResultBox<T> {
        private let lock = NSLock()
        private var result: Result<T,Error>?
        private var continuation: CheckedContinuation<T,Error>?

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

    public let label:String?

    private var pendingTasksContinuation: AsyncStream<PendingTask>.Continuation

    private var pendingTasks: AsyncStream<PendingTask>

    private var scope: Task<Void,Never>?

    private var isScopeCancelled = false


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

    public init(label: String? = nil){
        self.label = label
        (pendingTasks,pendingTasksContinuation) = AsyncStream.makeStream()
        initScope()
    }

    public func close()
    {
        if !isScopeCancelled
        {
            isScopeCancelled = true
        }
    }

    public func dispatch(label:String?=nil,block: @escaping () async throws -> Void)
    {
        pendingTasksContinuation.yield(AsyncTask(label: label, onComplete: nil, block: block))
    }

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
