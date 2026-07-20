const std = @import("std");

/// Stable, model-local identities. Zero is reserved so domain values may be
/// constructed by provider parsers before the model assigns an identity.
pub const AccountId = struct {
    value: u64 = 0,

    pub fn isValid(id: AccountId) bool {
        return id.value != 0;
    }
};

pub const MessageId = struct {
    value: u64 = 0,

    pub fn isValid(id: MessageId) bool {
        return id.value != 0;
    }
};

pub const DraftId = struct {
    value: u64 = 0,

    pub fn isValid(id: DraftId) bool {
        return id.value != 0;
    }
};

pub const OperationId = struct {
    value: u64 = 0,

    pub fn isValid(id: OperationId) bool {
        return id.value != 0;
    }
};

pub fn nextAccountId(counter: *u64) AccountId {
    return allocate(AccountId, counter);
}

pub fn nextMessageId(counter: *u64) MessageId {
    return allocate(MessageId, counter);
}

pub fn nextDraftId(counter: *u64) DraftId {
    return allocate(DraftId, counter);
}

pub fn nextOperationId(counter: *u64) OperationId {
    return allocate(OperationId, counter);
}

fn allocate(comptime Id: type, counter: *u64) Id {
    if (counter.* == 0) counter.* = 1;
    const value = counter.*;
    counter.* +%= 1;
    if (counter.* == 0) counter.* = 1;
    return .{ .value = value };
}

pub fn toInt(id: anytype) u64 {
    return id.value;
}

test "stable ids reserve zero and survive counter wrap" {
    var account_counter: u64 = 1;
    try std.testing.expectEqual(@as(u64, 1), toInt(nextAccountId(&account_counter)));
    try std.testing.expectEqual(@as(u64, 2), toInt(nextAccountId(&account_counter)));

    var message_counter: u64 = std.math.maxInt(u64);
    try std.testing.expectEqual(std.math.maxInt(u64), toInt(nextMessageId(&message_counter)));
    try std.testing.expectEqual(@as(u64, 1), toInt(nextMessageId(&message_counter)));

    var draft_counter: u64 = 4;
    try std.testing.expectEqual(@as(u64, 4), nextDraftId(&draft_counter).value);
    var operation_counter: u64 = 7;
    try std.testing.expectEqual(@as(u64, 7), nextOperationId(&operation_counter).value);
}
