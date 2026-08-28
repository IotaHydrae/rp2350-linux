/* S3-05 /init 链接脚本：text 从 0x0 开始，data 紧随且 32 对齐（FLAT_DATA_ALIGN） */
/* 注意：bFLT 头 64 字节，加载后 entry 在 text 基址 +64 处；data 相对 text 基址 = _data_start */
OUTPUT_ARCH(riscv)
ENTRY(_start)

PHDRS
{
	text PT_LOAD FLAGS(5); /* R+X */
	data PT_LOAD FLAGS(6); /* R+W */
}

SECTIONS
{
	. = 0x0;

	.text : {
		*(.text*)
	} :text

	. = ALIGN(0x20);
	_data_start = .;

	.data : {
		*(.rodata*)
		*(.data*)
	} :data

	. = ALIGN(0x4);
	_bss_start = .;

	.bss : {
		*(.bss*)
		*(COMMON)
	} :data

	_bss_end = .;

	/DISCARD/ : {
		*(.comment*)
		*(.note*)
		*(.eh_frame*)
		*(.riscv.attributes)
		*(.interp)
		*(.dynsym)
		*(.dynstr)
		*(.gnu.hash)
		*(.dynamic)
		*(.got*)
		*(.plt*)
		*(.hash)
		*(.rela*)
		*(.rel*)
	}
}
