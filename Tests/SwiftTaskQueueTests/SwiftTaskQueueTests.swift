import XCTest
@testable import SwiftTaskQueue

actor TestResult{
    var task1: String?
    var task2: String?
    var task3: [String] = []
    var task4: String?
    
    func task1Done(result:String)
    {
        task1 = result
    }
    func task2Done(result:String)
    {
        task2 = result
    }
    func task3Yield(result:String)
    {
        task3.append(result)
    }
    func task4Done(result:String)
    {
        task4 = result
    }
}

final class SwiftTaskQueueTests: XCTestCase {
    
    func testNonIsoloated(taskQueue:TaskQueue,testResult:TestResult)
    {
        print("dispatch task1")
        taskQueue.dispatch(label: "task1") {
            print("\(Date()) task1 start")
            try? await Task.sleep(nanoseconds: 1000000000)
            await testResult.task1Done(result: "1")
            print("\(Date()) task1 end")
        }
    }
    
    func testExample() async throws {
        // This is an example of a functional test case.
        // Use XCTAssert and related functions to verify your tests produce the correct
        // results.
        let taskQueue = await TaskQueue()
        let testResult = TestResult()
        let testStartTime = Date()
        testNonIsoloated(taskQueue: taskQueue, testResult: testResult)
        await withTaskGroup(of: Void.self) { taskGroup in
            taskGroup.addTask {
                print("dispatch task2")
                let result = try? await taskQueue.dispatch(label: "task2") {
                    print("\(Date()) task2 start")
                    try? await Task.sleep(nanoseconds: 1000000000)
                    print("\(Date()) task2 end")
                    return "2"
                }
                await testResult.task2Done(result: result ?? "")
            }
            taskGroup.addTask {
                print("dispatch task3")
                let stream = taskQueue.dispatchStream(label: "task3") { continuation in
                    print("\(Date()) task3 start")
                    Task{
                        for i in 3..<10
                        {
                            try? await Task.sleep(nanoseconds: 1000000000)
                            print("\(Date()) task3 yield \(i)")
                            continuation.yield(i)
                        }
                        continuation.finish()
                        print("\(Date()) task3 end")
                    }
                }
                do{
                    for try await result in stream
                    {
                        await testResult.task3Yield(result: "\(result)")
                    }
                }
                catch
                {
                    print("task3 error \(error)")
                }
            }
            taskGroup.addTask {
                print("dispatch task4")
                let result = try? await taskQueue.dispatch(label: "task4") {
                    print("\(Date()) task4 start")
                    try? await Task.sleep(nanoseconds: 1000000000)
                    print("\(Date()) task4 end")
                    return "Finish"
                }
                await testResult.task4Done(result: result ?? "")
            }
        }
        let testEndTime = Date()
        let testDuration = testEndTime.timeIntervalSince(testStartTime)
        let task1 = await testResult.task1
        let task2 = await testResult.task2
        let task3 = await testResult.task3
        let task4 = await testResult.task4
        print("\(Date()) Test duration = \(testDuration), \(task1) \(task2) \(task3) \(task4)")
        XCTAssertEqual(task1 , "1")
        XCTAssertEqual(task2 , "2")
        XCTAssertEqual(task3 , ["3","4","5","6","7","8","9"])
        XCTAssertEqual(task4 , "Finish")
        XCTAssertGreaterThan(testDuration, TimeInterval(10.0))
    }
}
