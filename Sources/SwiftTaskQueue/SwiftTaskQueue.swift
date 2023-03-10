public class TaskQueue{
    private class PendingTask{
        let label:String?
        
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
    
    private var pendingTasksContinuation: AsyncStream<PendingTask>.Continuation?
    
    private var pendingTasks: AsyncStream<PendingTask>?
    
    private var scope: Task<Void,Never>?
    
    private var initTask: Task<Void,Never>?
    
    private func initScope(initContinuation:CheckedContinuation<Void,Never>)
    {
        pendingTasks = AsyncStream{ continuation in
            pendingTasksContinuation = continuation
            print("pendingTasksContinuation initialized")
            initContinuation.resume()
        }
        scope = Task{
            guard let pendingTasks = pendingTasks else { return }
            for await pendingTask in pendingTasks
            {
//                print("PendingTask \(pendingTask.label ?? "") received", label ?? "")
                if(Task.isCancelled){ break }
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
//                            print("StreamTask \(pendingTask.tag ?? "") yield",source: tag)
                            task.continuation.yield(value)
                        }
//                        print("StreamTask \(pendingTask.tag ?? "") finish",source: tag)
                        task.continuation.finish()
                    }
                    catch
                    {
//                        log.error("StreamTask \(pendingTask.tag ?? "") error \(error)",source: tag)
                        task.continuation.finish(throwing: error)
                    }
                    
                }
                else
                {
//                    print("PendingTask discard \(pendingTask)", label ?? "")
                }
                if(Task.isCancelled){ break }
            }
        }
    }
    
    public init(label: String? = nil){
        self.label = label
        initTask = Task{
            await withCheckedContinuation{ initScope(initContinuation: $0) }
            initTask = nil
        }
    }
    
    public func close()
    {
        if let scope = scope,
           !scope.isCancelled
        {
            scope.cancel()
        }
    }
    
    public func dispatch(label:String?=nil,block: @escaping () async throws -> Void)
    {
        if let initTask = initTask
        {
            Task{
                await initTask.value
                pendingTasksContinuation?.yield(AsyncTask(label: label, continuation: nil, block: block))
            }
        }
        else
        {
            pendingTasksContinuation?.yield(AsyncTask(label: label, continuation: nil, block: block))
        }
    }
    
    public func dispatch<T>(label:String?=nil,block: @escaping () async throws -> T) async throws -> T
    {
        if let initTask = initTask
        {
            await initTask.value
        }
        return (try await withCheckedThrowingContinuation({ continuation in
            pendingTasksContinuation?.yield(AsyncTask(label: label, continuation: continuation, block: block))
        })) as! T
    }
    
    public func dispatchStream<T>( label:String?=nil, block:@escaping (AsyncThrowingStream<T,Error>.Continuation) -> Void) -> AsyncThrowingStream<T,Error>
    {
        let anyStream = AsyncThrowingStream<Any,Error> { continuation in
            pendingTasksContinuation?.yield(StreamTask(label: label, continuation: continuation, block: { anyContinuation in
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
                if let initTask = initTask
                {
                    await initTask.value
                }
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
