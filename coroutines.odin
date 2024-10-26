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

DEFAULT_STACK_SIZE :: mem.Megabyte
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

@(thread_local)
init_stack_beg: libc.jmp_buf

start :: proc(cor: ^Coroutine($A, $R), arg: A) {
	libc.setjmp(&init_stack_beg)
	start_coroutine(cor, arg)
}

next :: #force_inline proc(cor: ^Coroutine($A, $R)) -> (R, bool) {
	context_switch(&cor.parent_env, &cor.coroutine_env)
	return cor.ret, !cor.finished
}

yield :: #force_inline proc(ret: $R) {
	cor := get_coroutine_for_yield(R)
	cor.ret = ret
	context_switch(&cor.coroutine_env, &cor.parent_env)
}

destroy :: proc(cor: ^Coroutine($A, $R), allocator := context.allocator) {
	delete(cor.stack, allocator)
	cor^ = {}
}

@(private = "file")
start_coroutine :: #force_no_inline proc(cor: ^Coroutine($A, $R), arg: A) {
	cor_c := cor
	arg_c := arg
	if 0 == libc.setjmp(&cor.coroutine_env) {
		/*
            Copy the stack to our buffer and point the jmp_buf stack pointer to it.
            Currently this is non-portable as we assume the stack grows downward.
        */
		beg := get_stack_pointer(&init_stack_beg)
		end := get_stack_pointer(&cor.coroutine_env)
		frame_len := int(uintptr(beg) - uintptr(end))
		assert(frame_len < len(cor.stack))
		mem.copy(&cor.stack[len(cor.stack) - frame_len], end, frame_len + 16)
		set_stack_pointer(&cor.coroutine_env, &cor.stack[len(cor.stack) - frame_len])
		init_stack_beg = {}
		return
	} else {
		context.user_ptr = rawptr(cor_c)
		context.user_index = (^int)(raw_data(COROUTINE_MARKER))^
		// we want this so cor_proc can run its defers
		final_ret := cor.cor_proc(arg_c)
		end(final_ret)
	}
	return
}

@(private = "file")
end :: #force_inline proc(ret: $R) {
	cor := get_coroutine_for_yield(R)
	for {
		yield(ret)
		cor.finished = true
	}
}

COROUTINE_MARKER_C :: "COROUTINECONTEXT"
@(rodata)
COROUTINE_MARKER: string = COROUTINE_MARKER_C

@(private = "file")
get_coroutine_for_yield :: #force_inline proc($R: typeid) -> (cor: ^Coroutine(rawptr, R)) {
	assert(size_of(int) <= len(COROUTINE_MARKER_C))
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

// TODO: Non-portable, implement for other platforms
STACK_PTR_OFFSET_C :: 16
STACK_PTR_OFFSET: uintptr = STACK_PTR_OFFSET_C

@(private = "file")
set_stack_pointer :: #force_inline proc(jmp: ^libc.jmp_buf, ptr: rawptr) {
	ptr := ptr
	mem.copy(rawptr(uintptr(jmp) + STACK_PTR_OFFSET), &ptr, size_of(rawptr))
}

@(private = "file")
get_stack_pointer :: #force_inline proc(jmp: ^libc.jmp_buf) -> (result: rawptr) {
	mem.copy(&result, rawptr(uintptr(jmp) + STACK_PTR_OFFSET), size_of(rawptr))
	return
}
