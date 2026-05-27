# SwiftTaskQueue

> A library to serialize async `Task`. Also support `AsyncThrowingStream`.

[![Swift Version][swift-image]][swift-url]
[![Build Status][travis-image]][travis-url]
[![License][license-image]][license-url]

This library helps organizing async tasks into a queue, making sure multiple tasks are executed one by one. This could be handy when multiple tasks are being fired at arbitrary moment but must not run concurrently.

## Installation

Add this project on your `Package.swift`

```swift
import PackageDescription

let package = Package(
    dependencies: [
        .package(url: "https://github.com/rickymohk/SwiftTaskQueue.git", .branch("main"))
    ]
)
```

## Usage example

```swift
import SwiftTaskQueue

let taskQueue = TaskQueue()

Task {

    // Fire and forget — enqueue without waiting for result
    taskQueue.dispatch {
        // your async code here
    }

    // Enqueue and await the result
    let result = try await taskQueue.dispatchAndWait {
        // your async code here
        return "result"
    }

    // Enqueue and get a Task handle — await the result later
    let deferred = taskQueue.dispatchTask {
        // your async code here
        return "result"
    }
    // ... do other work ...
    let deferredResult = try await deferred.value

    // Create an AsyncThrowingStream in the queue
    let stream = taskQueue.dispatchStream { continuation in
        // your stream builder here
        continuation.yield("result")
        // remember to call finish when done, otherwise the queue will be blocked
        continuation.finish()
    }

    do {
        for try await result in stream {
            // use the result from the stream
        }
    }
    catch {
        print("stream error \(error)")
    }
}
```

## Migration guide — 2.0.0 breaking changes

### Method renames

| 1.x | 2.0 | Notes |
|-----|-----|-------|
| `dispatch { }` _(non-async, void)_ | `dispatch { }` | Fire-and-forget, no result (unchanged) |
| `try await dispatch { … }` _(returns T)_ | `try await dispatchAndWait { … }` | Enqueue and suspend until result is ready |
| _(new)_ | `dispatchTask { … }` | Enqueue and return a `Task<T, Error>` handle immediately; await `.value` whenever needed |

`dispatchStream` is unchanged.


[swift-image]:https://img.shields.io/badge/swift-5.7-orange.svg
[swift-url]: https://swift.org/
[license-image]: https://img.shields.io/badge/License-MIT-blue.svg
[license-url]: https://opensource.org/license/mit/
[travis-image]: https://img.shields.io/travis/dbader/node-datadog-metrics/master.svg
[travis-url]: https://travis-ci.org/dbader/node-datadog-metrics
