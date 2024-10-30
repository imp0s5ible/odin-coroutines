package minimal

import cr "../.."
import "core:log"

example_coroutine :: proc(cor: ^cr.Coroutine(int), range: [2]int) -> int {
	log.info("Hello from coroutine!")
	for i in range.x ..< range.y - 1 {
		log.info("Sending from coroutine:", i)
		cr.yield(cor, i)
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
	defer cr.destroy(&my_coroutine.cor)

	cr.start(&my_coroutine, [2]int{5, 11})
	for i in cr.next(&my_coroutine.cor) {
		log.info("Received from coroutine:", i)
	}

	log.info("Done!")
}
