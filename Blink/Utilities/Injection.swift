//
//  Injection.swift
//  Blink
//
//  Created by Ben on 3/25/26.
//

/// Updates a copy of the given value using a closure and returns the updated value.
@discardableResult
func with<Value>(_ value: Value, update: (inout Value) throws -> Void) rethrows -> Value {
    var copy = value
    try update(&copy)
    return copy
}

/// Updates a copy of the given value using a closure and returns the updated value.
@discardableResult
func with<Value>(_ value: Value, update: (inout Value) async throws -> Void) async rethrows -> Value
{
    var copy = value
    try await update(&copy)
    return copy
}
