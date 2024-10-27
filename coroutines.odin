package coroutines

import "base:intrinsics"
import "base:runtime"
import "core:c/libc"
import "core:log"
import "core:mem"
import "core:reflect"

Coroutine :: struct($A: typeid, $R: typeid) #no_copy {
	ret_type_id:   typeid,
	ret:           R,
	finished:      bool,
	cor_proc:      proc(arg: A) -> R,
	stack:         []byte,
	parent_env:    libc.jmp_buf,
	coroutine_env: libc.jmp_buf,
}

DEFAULT_STACK_SIZE :: #config(COROUTINE_DEFAULT_STACK_SIZE, mem.Megabyte)

/*
Create a Coroutine struct of the appropriate type given the provided proc

Inputs:
- cor_proc: A proc taking a single argument and returning a single value
- stack_size: The amount of space to allocate for the stack, in bytes. Default is one megabyte
- allocator: The allocator with which to allocate storage for the call stack. Default is context.allocator

Returns:
- A Coroutine struct with call stack storage allocated, on which `start` can be called later
- An allocator error, if this is not None then the returned Coroutine struct is not valid, and no cleanup is necessary
*/
@(require_results)
make :: proc(
	cor_proc: proc(arg: $A) -> $R,
	stack_size := DEFAULT_STACK_SIZE,
	allocator := context.allocator,
) -> (
	result: Coroutine(A, R),
	err: runtime.Allocator_Error,
) {
	result.ret_type_id = typeid_of(R)
	result.stack = runtime.mem_alloc_bytes(stack_size, 16, allocator) or_return
	result.cor_proc = cor_proc
	result.finished = false
	return
}

/*
Begins the execution of the coroutine struct by copying the context and argument from the call site
into the first stack frame of the coroutine.

Can only be called directly after `make`!

After this, `next` can be called on the coroutine to get its first `return``/`yield`` value.

Note: `context.user_index` and `context.user_ptr` will be overwritten inside the coroutine.
If you need to use these, create a scope in which to overwrite them, and refrain from calling
`yield` while in this scope.

Inputs:
- cor: The coroutine struct to start
- arg: The argument to pass to the coroutine proc
*/
start :: proc(cor: ^Coroutine($A, $R), arg: A) {
    init_stack_beg := asm() -> rawptr{GET_STACK_PTR,"=r"}()
	start_coroutine(cor, arg, init_stack_beg)
}

/*
Switches contexts to the coroutine proc and runs it until the next `yield` or `return`.
Can be used as a `for` loop iterator.

Inputs:
- cor: The coroutine to run

Returns:
- The return value of the last `yield` or `return`
- `false` if the coroutine execution has finished, `true` otherwise
If execution has finished, it will keep returning the final `return` value.
*/
next :: #force_inline proc(cor: ^Coroutine($A, $R)) -> (R, bool) {
	context_switch(&cor.parent_env, &cor.coroutine_env)
	return cor.ret, !cor.finished
}

/*
Switches contexts back to the caller and returns a value to its `next` call.

Note: Calls to `yield` are not statically type checked, instead the `Coroutine`
struct stores the `typeid` of the correct return type, against which this call is checked.
This may trip you up if you're returning typeless literals which may not coerce to the correct
type here.

Inputs:
- ret: The value to return to the caller
*/
yield :: #force_inline proc(ret: $R) {
	cor := get_coroutine_for_yield(R)
	cor.ret = ret
	context_switch(&cor.coroutine_env, &cor.parent_env)
}

/*
Destroys the coroutine context by freeing the stack space allocated for it
and zeroing the struct's contents, returning it to an uninitialized state.

Note: The Coroutine struct is only responsible for freeing its own call stack space.
Freeing resources acquired by the coroutine proc itself is the responsibility of the user.

Inputs:
- cor: The coroutine to free and destroy
- allocator: The allocator with which the stack deallocation is done. This should be the same as the one passed to `make` earlier.
*/
destroy :: proc(cor: ^Coroutine($A, $R), allocator := context.allocator) {
	cor^ = {}
}

@(private = "file")
start_coroutine :: #force_no_inline proc(cor: ^Coroutine($A, $R), arg: A, init_stack_beg: rawptr) {
	cor_c := cor
	arg_c := arg
	/*
        Copy the stack to our buffer and point the jmp_buf stack pointer to it.
        Currently this is non-portable as we assume the stack grows downward.
    */
	stack_beg := init_stack_beg
    stack_end := asm() -> rawptr{GET_STACK_PTR,"=r"}()
	frame_len := int(uintptr(stack_beg) - uintptr(stack_end))
	assert(frame_len < len(cor.stack))
    
    // Anything below this line will be uninitialized after jumping to the allocated stack
	mem.copy(&cor.stack[len(cor.stack) - frame_len], stack_end, frame_len)

	desired_stack_pointer := rawptr(&cor.stack[len(cor.stack) - frame_len])
	asm(rawptr) #side_effect {SET_STACK_PTR,"r"}(desired_stack_pointer)

	if 0 == libc.setjmp(&cor.coroutine_env) {
	    asm(rawptr) #side_effect {SET_STACK_PTR,"r"}(stack_end)
		return
	} else {
		context.user_ptr = rawptr(cor_c)
		context.user_index = (^int)(raw_data(COROUTINE_MARKER))^
		// we want this so cor_proc can run its defers
		final_ret := cor.cor_proc(arg_c)
		end(final_ret)
	}
	unreachable()
}

@(private = "file")
end :: #force_inline proc(ret: $R) {
	cor := get_coroutine_for_yield(R)
	for {
		yield(ret)
		cor.finished = true
	}
}

@(private = "file")
get_coroutine_for_yield :: #force_inline proc($R: typeid) -> (cor: ^Coroutine(rawptr, R)) {
	#assert(size_of(int) <= len(COROUTINE_MARKER_C))
	if context.user_index != (^int)(raw_data(COROUTINE_MARKER))^ {
		panic("Attempted to yield from non-coroutine context")
	}
	cor = (^Coroutine(rawptr, R))(context.user_ptr)
	if cor == nil {
		panic("Missing coroutine object from coroutine context")
	} else if cor.ret_type_id != typeid_of(R) {
		panic("Attempted to yield from coroutine with incorrect type")
	}
	return
}

@(private = "file")
context_switch :: #force_inline proc(from: ^libc.jmp_buf, to: ^libc.jmp_buf) {
	if (0 == libc.setjmp(from)) {
		libc.longjmp(to, 1)
	}
}

@(private = "file")
COROUTINE_MARKER_C :: "COROUTINECONTEXT"

@(private = "file")
@(rodata)
COROUTINE_MARKER: string = COROUTINE_MARKER_C

@(private = "file")
GET_STACK_PTR :: "mov %rsp, $0" when ODIN_ARCH == .amd64 else
                 "mov %esp, $0" when ODIN_ARCH == .i386 else
                 #panic("odin-coroutines: Unsupported architecture")

@(private = "file")
SET_STACK_PTR :: "mov $0, %rsp" when ODIN_ARCH == .amd64 else
                 "mov $0, %esp" when ODIN_ARCH == .i386 else
                 #panic("odin-coroutines: Unsupported architecture")
