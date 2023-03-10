# SwiftTaskQueue

> A library to serialize async `Task`. Also support `AsyncThrowingStream`.

[![Swift Version][swift-image]][swift-url]
[![Build Status][travis-image]][travis-url]
[![License][license-image]][license-url]

This library helps organizing async tasks into a queue, making sure multiple tasks are executed one by one. This could be handy when multiple tasks are being fired at arbitary moment but must not run concurrently.

## Installation

Add this project on your `Package.swift`

```swift
import PackageDescription

let package = Package(
    dependencies: [
        .package(url: "https://github.com/rickymohk/SwiftTaskQueue.git", .branch("master"))
    ]
)
```

## Usage example


```swift
import SwiftTaskQueue

let taskQueue = TaskQueue()

// Call from non-async context, without waiting for result
taskQueue.dispatch {
    // your async code here
}

Task{
    // Call from async context, waiting for result
    let result = try? await taskQueue.dispatch {
        // your async code here
        // ...
        return "result"
    }

    // Create AsyncThrowingStream
    let stream = taskQueue.dispatchStream { continuation in
        // your stream builder here
        // ...
        continuation.yield("result")
        // ...
        // remember to call finish when you are done with this stream, otherwise the whole queue will be blocked
        continuation.finish() 
    }
    
    do{
        for try await result in stream
        {
            // use the result from the stream
        }
    }
    catch
    {
        print("stream error \(error)")
    }
}
```

[swift-image]:https://img.shields.io/badge/swift-5.7-orange.svg
[swift-url]: https://swift.org/
[license-image]: https://img.shields.io/badge/License-MIT-blue.svg
[license-url]: https://opensource.org/license/mit/
[travis-image]: https://img.shields.io/travis/dbader/node-datadog-metrics/master.svg
[travis-url]: https://travis-ci.org/dbader/node-datadog-metrics
