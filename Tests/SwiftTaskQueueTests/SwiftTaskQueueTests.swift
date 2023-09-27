import XCTest
@testable import SwiftTaskQueue


final class SwiftTaskQueueTests: XCTestCase {
    

    actor StringTestResult{
        var result : String = ""
        func append(_ result:String?)
        {
            self.result += result ?? ""
        }
    }
    
    func testPreInitTaskOrder() async throws
    {
        let result = StringTestResult()
        let taskQueue = TaskQueue()
        
        ({
            taskQueue.dispatch(label: "task1") {
                await result.append("1")
            }
            taskQueue.dispatch(label: "task2") {
                await result.append("2")
            }
            taskQueue.dispatch(label: "task3") {
                await result.append("3")
            }
            taskQueue.dispatch(label: "task4") {
                await result.append("4")
            }
        }())
        try? await Task.sleep(nanoseconds: 5000000000)
        let resultStr = await result.result
        print("testPreInitTaskOrder result: \(resultStr)")
        XCTAssert(resultStr == "1234")
    }
    
    func testCancellation() async throws
    {
        let result = StringTestResult()
        let taskQueue = TaskQueue()
        try await taskQueue.dispatch {
            try? await Task.sleep(nanoseconds: 1000000000)
            print("task1")
            await result.append("1")
        }
        try await taskQueue.dispatch {
            try? await Task.sleep(nanoseconds: 1000000000)
            print("task2")
            await result.append("2")
        }
        ({
            taskQueue.dispatch {
                try? await Task.sleep(nanoseconds: 3000000000)
                print("task3")
                await result.append("3")
            }
        }())
        
        ({
            taskQueue.dispatch {
                try? await Task.sleep(nanoseconds: 1000000000)
                print("task4")
                await result.append("4")
            }
        }())
        
        taskQueue.close()
        
        try? await Task.sleep(nanoseconds: 1000000000)
        
        let resultStr = await result.result
        print("testCancellation result: \(resultStr)")
        XCTAssertFalse(resultStr.contains("4"))
    }
    
    
    actor TestResult{
        var result : String = ""
        var task2ret: String?
        var task3ret: String?
        var task4ret: String?
        func append(_ result:String?)
        {
            self.result += result ?? ""
        }
        func task2(_ result:String?)
        {
            self.task2ret = result
        }
        func task3(_ result:String)
        {
            self.task3ret = result
        }
        func task4(_ result:String?)
        {
            self.task4ret = result
        }
    }
    
    func testNonAsync(taskQueue:TaskQueue,testResult:TestResult)
    {
        print("dispatch task1")
        taskQueue.dispatch(label: "task1") {
            await testResult.append("<1")
            print("\(Date()) task1 start")
            try? await Task.sleep(nanoseconds: 1000000000)
            await testResult.append("1>")
            print("\(Date()) task1 end")
        }
    }
    
    func testExample() async throws {
        // This is an example of a functional test case.
        // Use XCTAssert and related functions to verify your tests produce the correct
        // results.
        let taskQueue = TaskQueue()
        let testResult = TestResult()
        let testStartTime = Date()
        testNonAsync(taskQueue: taskQueue, testResult: testResult)
        await withTaskGroup(of: Void.self) { taskGroup in
            taskGroup.addTask {
                print("dispatch task2")
                let result = try? await taskQueue.dispatch(label: "task2") {
                    await testResult.append("<2")
                    print("\(Date()) task2 start")
                    try? await Task.sleep(nanoseconds: 1000000000)
                    print("\(Date()) task2 end")
                    await testResult.append("2>")
                    return "task2result"
                }
                await testResult.task2(result)
            }
            taskGroup.addTask {
                print("dispatch task3")
                let stream = taskQueue.dispatchStream(label: "task3") { continuation in
                    Task{
                        await testResult.append("<3")
                        print("\(Date()) task3 start")
                        for i in 3..<10
                        {
                            try? await Task.sleep(nanoseconds: 1000000000)
                            print("\(Date()) task3 yield \(i)")
                            continuation.yield(i)
                        }
                        continuation.finish()
                        print("\(Date()) task3 end")
                        await testResult.append("3>")
                    }
                }
                do{
                    var results : String = ""
                    for try await result in stream
                    {
                        results += "\(result)"
                    }
                    await testResult.task3(results)
                }
                catch
                {
                    print("task3 error \(error)")
                }
            }
            taskGroup.addTask {
                print("dispatch task4")
                let result = try? await taskQueue.dispatch(label: "task4") {
                    await testResult.append("<4")
                    print("\(Date()) task4 start")
                    try? await Task.sleep(nanoseconds: 1000000000)
                    print("\(Date()) task4 end")
                    await testResult.append("4>")
                    return "task4result"
                }
                await testResult.task4(result)
            }
        }
        
        try? await Task.sleep(nanoseconds: 1000000000)
        try? await taskQueue.dispatch {
            print("ensure unwaited task1 is executed")
        }
        
        let testEndTime = Date()
        let testDuration = testEndTime.timeIntervalSince(testStartTime)
        let result = await testResult.result
        let task2ret = await testResult.task2ret
        let task3ret = await testResult.task3ret
        let task4ret = await testResult.task4ret
        print("\(Date()) Test duration = \(testDuration), \(result)")
        XCTAssertTrue(result.contains("<11>"))
        XCTAssertTrue(result.contains("<22>"))
        XCTAssertTrue(result.contains("<33>"))
        XCTAssertTrue(result.contains("<44>"))
        XCTAssertEqual(task2ret, "task2result")
        XCTAssertEqual(task3ret, "3456789")
        XCTAssertEqual(task4ret, "task4result")
    }
}
