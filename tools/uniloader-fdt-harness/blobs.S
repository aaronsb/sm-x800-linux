/* The DTB and the command line blob, placed like uniLoader's .dtb / .cmdline */
	.section .rodata
	.balign 4096
	.globl blob_dtb, blob_dtb_end
blob_dtb:
	.incbin BLOB_DTB
blob_dtb_end:

	.balign 8
	.globl blob_cmdline, blob_cmdline_end
blob_cmdline:
	.incbin BLOB_CMDLINE
blob_cmdline_end:
