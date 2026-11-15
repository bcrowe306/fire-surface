package surface

// How often the kit's timer runs tasks (at the host's resolution: it may
// be a host frame).
TICK_MS :: 5

@(private)
Task :: struct {
	id:        u32,
	owner:     ^Component, // cancelled when it is deactivated (nil: with the surface)
	due_ns:    u64,
	period_ns: u64, // 0 = once
	fn:        proc(data: rawptr),
	data:      rawptr,
	cleanup:   proc(data: rawptr), // when it is removed (done or cancelled)
	cancelled: bool,
}

// Runs `fn(data)` once after `ms`; cancelled when `owner` (if any) is
// deactivated, or the surface is. The task's id, for `task_cancel`.
task_after :: proc(cs: ^Control_Surface, ms: u32, fn: proc(data: rawptr), data: rawptr = nil, owner: ^Component = nil) -> u32 {
	return task_add(cs, ms, 0, fn, data, owner)
}

// Runs `fn(data)` every `ms`, until cancelled.
task_every :: proc(cs: ^Control_Surface, ms: u32, fn: proc(data: rawptr), data: rawptr = nil, owner: ^Component = nil) -> u32 {
	return task_add(cs, ms, u64(max(ms, 1)) * 1_000_000, fn, data, owner)
}

@(private)
task_add :: proc(cs: ^Control_Surface, ms: u32, period: u64, fn: proc(data: rawptr), data: rawptr, owner: ^Component, cleanup: proc(data: rawptr) = nil) -> u32 {
	id := cs.next_task
	cs.next_task += 1
	if cs.next_task == 0 do cs.next_task = 1
	append(&cs.tasks, Task{id = id, owner = owner, due_ns = now_ns(cs) + u64(ms) * 1_000_000, period_ns = period, fn = fn, data = data, cleanup = cleanup})
	return id
}

// Cancels a task (0, or one that's done: nothing).
task_cancel :: proc(cs: ^Control_Surface, id: u32) {
	if id == 0 do return
	for &t in cs.tasks do if t.id == id do t.cancelled = true
}

@(private)
tasks_cancel_owner :: proc(cs: ^Control_Surface, owner: ^Component) {
	for &t in cs.tasks do if t.owner == owner do t.cancelled = true
}

@(private)
run_tasks :: proc(cs: ^Control_Surface) {
	now := now_ns(cs)
	n := len(cs.tasks) // those added now wait for the next tick
	for i in 0 ..< n {
		if i >= len(cs.tasks) do break
		t := cs.tasks[i]
		if t.cancelled || now < t.due_ns do continue
		if t.period_ns > 0 {
			cs.tasks[i].due_ns = max(t.due_ns + t.period_ns, now)
		} else {
			cs.tasks[i].cancelled = true
		}
		t.fn(t.data)
	}
	tasks_sweep(cs)
}

@(private)
tasks_sweep :: proc(cs: ^Control_Surface) {
	for i := len(cs.tasks) - 1; i >= 0; i -= 1 {
		if !cs.tasks[i].cancelled do continue
		if cs.tasks[i].cleanup != nil do cs.tasks[i].cleanup(cs.tasks[i].data)
		ordered_remove(&cs.tasks, i)
	}
}

// Every task cancelled and removed (deactivated, destroyed).
@(private)
tasks_clear :: proc(cs: ^Control_Surface) {
	for &t in cs.tasks do t.cancelled = true
	tasks_sweep(cs)
}

// Sends messages one after another, `gap_ms` apart (the first now): for
// devices that need time between the messages of a hello. The messages are
// copied.
send_sequence :: proc(cs: ^Control_Surface, messages: [][]u8, gap_ms: u32, port := 0, owner: ^Component = nil) {
	for m, i in messages {
		if i == 0 {
			send(cs, m, port)
			continue
		}
		Delayed :: struct { cs: ^Control_Surface, bytes: []u8, port: int }
		d := new(Delayed, cs.allocator)
		d^ = {cs, clone_bytes(m, cs.allocator), port}
		task_add(cs, gap_ms * u32(i), 0, proc(data: rawptr) {
			d := (^Delayed)(data)
			send(d.cs, d.bytes, d.port)
		}, d, owner, proc(data: rawptr) {
			d := (^Delayed)(data)
			delete(d.bytes, d.cs.allocator)
			free(d, d.cs.allocator)
		})
	}
}

@(private)
clone_bytes :: proc(b: []u8, allocator := context.allocator) -> []u8 {
	out := make([]u8, len(b), allocator)
	copy(out, b)
	return out
}

// Blinks a control between two skin values every `ms` while `owner` is
// active (or until cancelled: the id).
blink :: proc(c: ^Control, on, off: string, ms: u32, owner: ^Component) -> u32 {
	Blink :: struct { c: ^Control, on, off: string, lit: bool }
	b := new(Blink, c.cs.allocator)
	b^ = {c, on, off, true}
	light(c, on)
	return task_add(c.cs, ms, u64(max(ms, 1)) * 1_000_000, proc(data: rawptr) {
		b := (^Blink)(data)
		b.lit = !b.lit
		light(b.c, b.on if b.lit else b.off)
	}, b, owner, proc(data: rawptr) { free(data, (^Blink)(data).c.cs.allocator) })
}
