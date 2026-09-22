ENTRY(_start)
SECTIONS
{
	. = 0x40000000;
	.text : {
		KEEP(*(.text.start))
		*(.text.vectors)
		*(.text .text.*)
	}
	.rodata ALIGN(4096) : { *(.rodata .rodata.*) }
	.data ALIGN(8) : { *(.data .data.*) }
	.bss ALIGN(8) : {
		__bss_start = .;
		*(.bss .bss.*)
		*(COMMON)
		. = ALIGN(8);
		__bss_end = .;
	}
	. = ALIGN(4096);
	. += 0x20000;
	_stack_top = .;
	/DISCARD/ : { *(.note*) *(.eh_frame*) *(.comment) }
}
