// This module provides a simple arena (bump) allocator.
// An arena allocates memory by bumping a pointer forward in a pre-allocated region.
// Individual frees are no-ops, you free all memory at once via reset or deinit.
// This makes arenas very fast for allocation-heavy workloads where lifetimes are scoped.

// this is literally just memory for us to use, if we run out of it then we link in new memory.
Region :: struct {
    next: *Region; // the next region, this is an intrusive linked list
    count: s64;    // number of bytes that we have used in this region
    capacity: s64; // number of bytes allocated to this region
    data: *u8;     // pointer to the start of the region
}

Arena :: struct {
    begin: *Region;
    end: *Region;

    // we have to get our regions from somewhere, if we used the context allocator it'd most likely be an
    // issue because the arena allocator would be set causing infinite recursion when a new region is required.
    region_allocator: Allocator;
}

REGION_DEFAULT_CAPACITY :: 8 * 1024; // measured in bytes

get_arena_allocator :: (region_allocator: Allocator = .{}) -> Allocator {
    a := New(Arena);

    // So that if you store this Allocator in a global or somewhere else accessible from a global,
    // we don't consider all sub-allocations to be non-leaks!
    this_allocation_does_not_propagate_leak_ownership(a);

    a.region_allocator = ifx region_allocator.proc then region_allocator else context.allocator;

    return .{ arena_allocator_proc, a };
}

// If you want to release an Arena allocator, use this.
// Since arenas are often scoped to a phase of work, you may want to call this
// when that phase is done. But if the arena lives for the whole program, you
// might not need to care about this.
deinit_arena_allocator :: (allocator: Allocator) {
    a := cast(*Arena) allocator.data;
    assert(a != null);

    arena_free(a);
    free(a);
}


// Resets the arena so all regions are reusable, but does not free any region memory.
// This is useful if you want to reuse the arena for another phase of work without
// paying the cost of reallocating regions.
reset_arena_allocator :: (allocator: Allocator) {
    a := cast(*Arena) allocator.data;
    assert(a != null);
    arena_reset(a);
}

// the allocator proc is what gets triggered when functions like alloc/realloc etc get called.

arena_allocator_proc :: (mode: Allocator_Mode, requested_size: s64, old_size: s64, old_memory: *void, allocator_data: *void) -> *void {
    arena := cast(*Arena) allocator_data;
    assert(arena != null);  // We need our stuff!

    if #complete mode == {
      case .ALLOCATE;
        // Triggered by: alloc(), New(), array_add(), array_reserve(), resizable_array operations,
        // operator new, or any allocation through context.allocator when this arena is pushed.
        return arena_alloc(arena, requested_size);

      case .RESIZE;
        // Triggered by: realloc(), array_reserve() when growing, array_add() when the dynamic array
        // runs out of space and needs a bigger backing buffer, or << (array append operator).
        old_aligned := (old_size + 7) & ~7;
        if requested_size <= old_aligned return old_memory;

        new_ptr := arena_alloc(arena, requested_size);
        memcpy(new_ptr, old_memory, old_size);
        return new_ptr;

      case .FREE;
        // Triggered by: free(), array_free(), array_reset(), free(string), or any explicit
        // deallocation through context.allocator when this arena is pushed.
        // No-op for individual frees. That's the whole point of an arena.
        return null;

      case .STARTUP;      #through;
      case .SHUTDOWN;
        // Triggered by the runtime at program startup/shutdown. These are called once on whatever
        // allocator is set as context.allocator at those times. Arenas don't need to do anything here.
        return null;

      case .THREAD_START; #through;
      case .THREAD_STOP;
        // Triggered by the runtime when a new thread starts or stops, on that thread's context.allocator.
        // Gives allocators a chance to set up or tear down per-thread state. Arenas don't need this.
        return null;

      case .CREATE_HEAP; #through;
      case .DESTROY_HEAP;
        // Triggered by: context.allocator.proc(.CREATE_HEAP, ...) explicitly, or by runtime internals
        // that want sub-heaps (e.g. for per-thread heaps in the default allocator).
        // Arenas don't support this.
        assert(false, "Create/Destroy heap are not supported by arena_allocator_proc (yet?)\n");
        return null;

      case .IS_THIS_YOURS;
        // Triggered by: the runtime or user code asking "does this pointer belong to this allocator?"
        // Used for debugging, or by allocators that need to verify ownership before freeing.
        // We walk our region list to check if the pointer falls within any region's range.
        region := arena.begin;
        while region != null {
            if old_memory >= region.data && old_memory < region.data + region.capacity {
                return cast(*void) true;
            }
            region = region.next;
        }
        return null;

      case .CAPS; // CAPABILITIES
        // Triggered by: code that wants to query what this allocator supports, e.g.
        // "is this a debug allocator?", "does it support free?", "is it thread-safe?"
        // The version string identifies the module for diagnostics.
        if old_memory { (.*)cast(*string)old_memory = CAPS_VERSION_STRING; }
        return cast(*void)(Allocator_Caps.HINT_I_AM_A_GENERAL_HEAP_ALLOCATOR|.FREE);
    }
}

#scope_module

// actual internal logic starts here

#import "Basic";

CAPS_VERSION_STRING :: "tbx/Arena_Allocator";

new_region :: (capacity: s64, using_allocator: Allocator) -> *Region {
    region := cast(*Region) using_allocator.proc(.ALLOCATE, size_of(Region), 0, null, using_allocator.data);
    region.data = cast(*u8) using_allocator.proc(.ALLOCATE, capacity, 0, null, using_allocator.data);
    region.next = null;
    region.count = 0;
    region.capacity = capacity;
    return region;
}

arena_alloc :: (a: *Arena, size_bytes: s64) -> *u8 {
    // align to 8 bytes, by zeroing out the bottom 3 bits
    size := (size_bytes + 7) & ~7;

    if a.end == null {
        capacity := REGION_DEFAULT_CAPACITY;
        if capacity < size then capacity = size;
        a.end = new_region(capacity, a.region_allocator);
        a.begin = a.end;
    }

    while a.end.count + size > a.end.capacity && a.end.next != null {
        a.end = a.end.next;
    }

    if a.end.count + size > a.end.capacity {
        capacity := REGION_DEFAULT_CAPACITY;
        if capacity < size then capacity = size;
        a.end.next = new_region(capacity, a.region_allocator);
        a.end = a.end.next;
    }

    result := a.end.data + a.end.count;
    a.end.count += size;
    return result;
}

arena_reset :: (a: *Arena) {
    r := a.begin;
    while r != null {
        r.count = 0;
        r = r.next;
    }
    a.end = a.begin;
}

arena_free :: (a: *Arena) {
    r := a.begin;
    while r != null {
        next := r.next;
        a.region_allocator.proc(.FREE, 0, a.end.capacity, r.data, a.region_allocator.data);
        a.region_allocator.proc(.FREE, 0, size_of(Region), r, a.region_allocator.data);
        r = next;
    }
    a.begin = null;
    a.end = null;
}
