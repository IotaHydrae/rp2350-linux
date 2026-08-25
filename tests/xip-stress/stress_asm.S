/*
 * xip-stress：纯汇编测试例程，放在独立 section，可被搬移到 PSRAM 执行。
 * 只使用寄存器，无绝对地址引用，因此拷贝后地址无关。
 * 由 main.c 拷贝 [xip_stress_text_start, xip_stress_text_end) 到 PSRAM。
 */

.section .xip_stress_text, "ax"
.align 2

.global xip_stress_text_start
xip_stress_text_start:

/*
 * int stress_write_readback(uint32_t base, uint32_t pattern, uint32_t words)
 * 写 pattern 到 [base, base+words*4)，读回，返回不一致的个数。
 */
.global stress_write_readback
stress_write_readback:
	mv	t0, a0
	mv	t1, a2
1:	sw	a1, 0(t0)
	addi	t0, t0, 4
	addi	t1, t1, -1
	bnez	t1, 1b

	mv	t0, a0
	mv	t1, a2
	li	t2, 0
2:	lw	t3, 0(t0)
	beq	t3, a1, 3f
	addi	t2, t2, 1
3:	addi	t0, t0, 4
	addi	t1, t1, -1
	bnez	t1, 2b
	mv	a0, t2
	ret

/*
 * int stress_read_flake(uint32_t addr, uint32_t count)
 * 读 addr 共 count 次，返回与第一次读不一致的次数。
 */
.global stress_read_flake
stress_read_flake:
	lw	t0, 0(a0)
	mv	t1, a1
	li	t2, 0
1:	lw	t3, 0(a0)
	beq	t3, t0, 2f
	addi	t2, t2, 1
2:	addi	t1, t1, -1
	bnez	t1, 1b
	mv	a0, t2
	ret

.global xip_stress_text_end
xip_stress_text_end:
