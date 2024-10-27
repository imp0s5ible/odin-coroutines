# Odin Coroutines
A Simple Coroutines Library for the Odin Programming Language

This library uses the C standard library's `setjmp` and `longjmp` functions to switch execution contexts and provide coroutines with full stack support, taking advantage of Odin's execution context feature to improve developer ergonomics.

**Warning:** This is **experimental software** that has *not* been thoroughly tested and is **not portable what so ever!**

**Use at your own risk!**

## Usage Example
Simply copy `coroutines.odin` to a directory of your choice, or clone this repo as a submodule, for example:
```
git submodule add https://github.com/imp0s5ible/odin-coroutines.git deps/coroutines
```

You can then print the documentation like so:
```
odin doc deps/coroutines
```

Finally, here is a minimal example usage of the library, assuming this file is in a directory next to `deps`:
```rust
package test

import cr "../deps/coroutines"
import "core:log"

example_coroutine :: proc(range: [2]int) -> int {
	log.info("Hello from coroutine!")
	for i in range.x ..< range.y - 1 {
		log.info("Sending from coroutine:", i)
		cr.yield(i)
	}
	log.info("Final send from coroutine:", range.y - 1)
	return range.y - 1
}

main :: proc() {
	console_logger := log.create_console_logger()
	context.logger = console_logger
	log.info("Begin coroutine construction")
	my_coroutine, err := cr.make(example_coroutine)
	if err != .None {
		log.panic("Failed to allocate storage for coroutine!")
	}
	defer cr.destroy(&my_coroutine)

	cr.start(&my_coroutine, [2]int{5, 11})
	for i in cr.next(&my_coroutine) {
		log.info("Received from coroutine:", i)
	}

	log.info("Done!")
}
```

## Notes
- The `context` passed to the coroutine proc is the `context` passed to `start`, except for `context.user_index` and `context.user_ptr` which are overwritten with a special marker and a pointer to the `Coroutine` struct, respectively
- As the coroutine uses `context.user_index` to mark the `context` as part of a coroutine and `context.user_ptr` to point to the `Coroutine` struct, if you need to use these you will need to create a scope in which to overwrite them, and refrain from calling `yield` in this scope
- `yield` is not type checked, instead its type is checked at run time against the return type's `typeid` stored in the `Coroutine` struct. This may trip you up if you call `yield` with literals.
- The `Coroutine` struct is only responsible for freeing its own call stack space
- The user is responsible for freeing any resources used/acquired by the coroutine, by either letting the `defer`ed statements run via running the coroutine to the end, or by manually freeing them
- You can normally return from a coroutine proc, this counts as your last `yield` and should guarantee that all `defer`ed statements are run as long as the coroutine is run to the end.
- Due to its signature, `next` can be used as a for-loop proc
- `jmp_buf` is huge, probably needlessly
- Only one argument and return value are supported
- There are no functions for `await`ing conditions in coroutines or having coroutines be in a waiting status, they always must run to the next return value
- There is no way to have a tiny in-line stack with no allocations (i.e. for small coroutines that are created/called often)

## (Known) Non-portable Parts
- We assume the stack grows downwards (from high towards low addresses)
- We assume the architecture has such a thing as *a* stack pointer, and that setting it to a valid address is enough to switch the call stack out. This is not always the case i.e. wasm is a stack based VM, and ARM has more than one stack pointer.
