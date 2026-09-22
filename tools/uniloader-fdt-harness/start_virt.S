/* Entry and exception vectors for the bare-metal harness. */
	.section .text.start, "ax"
	.globl _start
_start:
	adrp	x0, _stack_top
	add	x0, x0, :lo12:_stack_top
	mov	sp, x0

	adrp	x0, vectors
	add	x0, x0, :lo12:vectors
	msr	vbar_el1, x0
	isb

	/* zero .bss */
	adrp	x0, __bss_start
	add	x0, x0, :lo12:__bss_start
	adrp	x1, __bss_end
	add	x1, x1, :lo12:__bss_end
1:	cmp	x0, x1
	b.hs	2f
	str	xzr, [x0], #8
	b	1b
2:
	bl	main
	bl	plat_exit
3:	b	3b

	.macro	vec num
	.balign	0x80
	mov	x3, #\num
	b	exc_common
	.endm

	.section .text.vectors, "ax"
	.balign	0x800
	.globl vectors
vectors:
	vec 0
	vec 1
	vec 2
	vec 3
	vec 4
	vec 5
	vec 6
	vec 7
	vec 8
	vec 9
	vec 10
	vec 11
	vec 12
	vec 13
	vec 14
	vec 15

exc_common:
	/* a fresh stack in case SP was the problem */
	adrp	x0, _stack_top
	add	x0, x0, :lo12:_stack_top
	sub	x0, x0, #0x1000
	mov	sp, x0
	mrs	x0, esr_el1
	mrs	x1, elr_el1
	mrs	x2, far_el1
	bl	plat_exception
4:	b	4b
