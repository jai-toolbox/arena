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

REGION_DEFAULT_CAPACITY :: 8 * 1024;

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

// in jai the point of creating your own Allocator is that you can then push that allocator onto the context
// and then all calls to alloc/realloc/etc... are wired into your specific allocators logic
// that's why the following section exists, it creates an allocator that is tied to a specific arena
// so we can do what I just described.

arena_allocator :: (a: *Arena, region_allocator := context.allocator) -> Allocator {
    a.region_allocator = region_allocator;
    allocator: Allocator;
    allocator.proc = arena_allocator_proc;
    allocator.data = a;
    return allocator;
}


// the allocator proc is what gets triggered when functions like alloc/realloc etc get called.

arena_allocator_proc :: (mode: Allocator_Mode, requested_size: s64, old_size: s64, old_memory: *void, allocator_data: *void) -> *void {
    arena := cast(*Arena) allocator_data;

    if #complete mode == {
        case .ALLOCATE;
            return arena_alloc(arena, requested_size);

        case .RESIZE;
            old_aligned := (old_size + 7) & ~7;
            if requested_size <= old_aligned return old_memory;

            new_ptr := arena_alloc(arena, requested_size);
            memcpy(new_ptr, old_memory, old_size);
            return new_ptr;

        case .FREE;
            return null;

        case .STARTUP;
            return null;

        case .SHUTDOWN;
            return null;

        case .THREAD_START;
            return null;

        case .THREAD_STOP;
            return null;

        case .CREATE_HEAP;
            return null;

        case .DESTROY_HEAP;
            return null;

        case .IS_THIS_YOURS;
            region := arena.begin;
            while region != null {
                if old_memory >= region.data && old_memory < region.data + region.capacity {
                    return cast(*void) true;
                }
                region = region.next;
            }
            return null;

        case .CAPS;
            return null;
    }
}
