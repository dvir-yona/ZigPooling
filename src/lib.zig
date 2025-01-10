//! This file is part of ZigPooling.
//!
//! Copyright (c) 2025 dvir yona
//!
//! This program is free software: you can redistribute it and/or modify
//! it under the terms of the MIT License as published by the Free Software
//! Foundation.
//!
//! See the LICENSE file for more details.
const std = @import("std");

/// (allocation size = chunk sizes * bits per object)
///
/// use:
///
/// std.os.page_allocator for large allocation sizes, multiples of std.os.page_size rounded upwards
///
/// std.mem.ArenaAllocator for small size
///
/// std.heap.GeneralPurposeAllocator for medium/ unknown size allocations
///
/// using the std.heap.GeneralPurposeAllocator is recommended
pub fn InitPoolType(comptime T: type) type {
    return struct {
        allocator: std.mem.Allocator,
        poolBuffer: []T,
        poolMutex: std.Thread.Mutex,
        availableBuffer: []usize,
        availableCapacity: usize,
        availableLock: std.Thread.RwLock,
        capacity: usize,
        length: usize = 0,
        availableLength: usize = 0,
        chunkSize: usize,

        fn increaseCapacity(self: *@This()) !void {
            self.capacity = self.capacity + self.chunkSize;
            const newBuffer = try self.allocator.alloc(T, self.capacity);
            std.mem.copyForwards(T, newBuffer[0..self.length], self.poolBuffer[0..self.length]);
            self.allocator.free(self.poolBuffer);
            self.poolBuffer = newBuffer;
        }

        fn increaseAvailableCapacity(self: *@This()) !void {
            self.availableCapacity += self.chunkSize;
            const newBuffer = try self.allocator.alloc(usize, self.availableCapacity);
            std.mem.copyForwards(usize, newBuffer[0..self.availableLength], self.availableBuffer[0..self.availableLength]);
            self.allocator.free(self.availableBuffer);
            self.availableBuffer = newBuffer;
        }

        pub fn GetCapacity(self: *const @This()) usize {
            return self.capacity;
        }

        pub fn GetAvailableCapacity(self: *const @This()) usize {
            return self.availableCapacity;
        }

        pub fn GetLength(self: *const @This()) usize {
            return self.length;
        }

        pub fn GetAvailableLength(self: *const @This()) usize {
            return self.availableLength;
        }

        pub fn Reserve(self: *@This(), count: usize) !void {
            const neededChunks = std.math.divCeil(usize, count, self.chunkSize);
            self.poolMutex.lock();
            defer self.poolMutex.unlock();
            for (0..neededChunks) |_| {
                try self.increaseCapacity();
            }
        }

        pub fn ReserveUpTo(self: *@This(), count: usize) !void {
            const needed_capacity = std.math.divCeil(usize, count, self.chunkSize) * self.chunkSize;
            self.poolMutex.lock();
            defer self.poolMutex.unlock();
            while (self.capacity < needed_capacity) {
                try self.increaseCapacity();
            }
        }

        pub fn ReserveAvailable(self: *@This(), count: usize) !void {
            const neededChunks = std.math.divCeil(usize, count, self.chunkSize);
            self.availableLock.lock();
            defer self.availableLock.unlock();
            for (0..neededChunks) |_| {
                try self.increaseAvailableCapacity();
            }
        }

        pub fn ReserveAvailableUpTo(self: *@This(), count: usize) !void {
            const needed_capacity = std.math.divCeil(usize, count, self.chunkSize) * self.chunkSize;
            self.availableLock.lock();
            defer self.availableLock.unlock();
            while (self.availableCapacity < needed_capacity) {
                try self.increaseAvailableCapacity();
            }
        }

        pub fn RequestItem(self: *@This(), createObject: fn (*@This()) T) !struct { object: *T, index: usize } {
            self.availableLock.lockShared();
            if (self.availableLength > 0) {
                self.availableLock.unlockShared();
                self.availableLock.lock();
                defer self.availableLock.unlock();
                self.availableLength -= 1;
                const index = self.availableBuffer[self.availableLength];
                return .{
                    .object = &self.poolBuffer[index],
                    .index = index,
                };
            } else {
                self.poolMutex.lock();
                self.availableLock.unlockShared();
                defer self.poolMutex.unlock();
                if (self.length == self.capacity) {
                    try self.increaseCapacity();
                }
                self.poolBuffer[self.length] = createObject(self);
                defer self.length += 1;
                return .{
                    .object = &self.poolBuffer[self.length],
                    .index = self.length,
                };
            }
        }

        pub fn ReleaseItem(self: *@This(), index: usize) !void {
            self.availableLock.lock();
            defer self.availableLock.unlock();
            if (self.availableLength == self.availableCapacity) {
                try self.increaseAvailableCapacity();
            }
            self.availableBuffer[self.availableLength] = index;
            self.availableLength += 1;
        }
    };
}

pub fn InitPoolObject(comptime T: type, starting_size: usize, chunk_size: usize, allocator: std.mem.Allocator) !InitPoolType(T) {
    const chunked_size = try std.math.divCeil(usize, starting_size, chunk_size) * chunk_size;
    return InitPoolType(T){
        .allocator = allocator,
        .poolBuffer = try allocator.alloc(T, chunked_size),
        .availableBuffer = try allocator.alloc(usize, chunked_size),
        .chunkSize = chunk_size,
        .capacity = chunked_size,
        .availableCapacity = chunked_size,
        .poolMutex = std.Thread.Mutex{},
        .availableLock = std.Thread.RwLock{},
    };
}

const testing = std.testing;
fn create_test_int(_: *InitPoolType(u8)) u8 {
    return 1;
}

test "compilation-test" {
    var Pool = try InitPoolObject(u8, 10, 3, testing.allocator);
    defer testing.allocator.free(Pool.poolBuffer);
    defer testing.allocator.free(Pool.availableBuffer);
    try testing.expectEqual(@as(usize, 12), Pool.GetCapacity());

    const item1 = try Pool.RequestItem(create_test_int);
    try testing.expectEqual(@as(usize, 0), item1.index);
    try Pool.ReleaseItem(item1.index);
    const item2 = try Pool.RequestItem(create_test_int);
    try testing.expectEqual(@as(u8, 1), item2.object.*);
}
