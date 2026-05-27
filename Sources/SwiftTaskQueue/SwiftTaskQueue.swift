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
        let continuation: CheckedContinuation<Any,Error>?
        let block: () async throws -> Any
        
        init(label: String?, continuation: CheckedContinuation<Any, Error>?, block: @escaping () async throws -> Any) {
            self.continuation = continuation
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
                        task.continuation?.resume(returning: result)
                    }
                    catch
                    {
//                        log.error("AsyncTask \(pendingTask.tag ?? "") error \(error)",source: tag)
                        task.continuation?.resume(throwing: error)
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
                    task.continuation?.resume(throwing: CancellationError())
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
        pendingTasksContinuation.yield(AsyncTask(label: label, continuation: nil, block: block))
    }

    public func dispatchAndWait<T>(label:String?=nil,block: @escaping () async throws -> T) async throws -> T
    {
        var pendingTask : AsyncTask?
        let cancel = {
            pendingTask?.isCancelled = true
        }
        return try await withTaskCancellationHandler {
            return (try await withCheckedThrowingContinuation({ continuation in
                let task = AsyncTask(label: label, continuation: continuation, block: block)
                pendingTask = task
                pendingTasksContinuation.yield(task)
            })) as! T
        } onCancel: {
            cancel()
        }
    }

    public func dispatchTask<T>(label:String?=nil,block: @escaping () async throws -> T) -> Task<T,Error>
    {
        var pendingTask : AsyncTask?
        let cancel = {
            pendingTask?.isCancelled = true
        }
        return Task {
            return try await withTaskCancellationHandler {
                return (try await withCheckedThrowingContinuation({ continuation in
                    let task = AsyncTask(label: label, continuation: continuation, block: block)
                    pendingTask = task
                    pendingTasksContinuation.yield(task)
                })) as! T
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
