// 假镜像入口：被 bootloader 拷到 PSRAM 0x11000000 后从这里开始执行。
// RISC-V 启动协议：a0 = hartid，a1 = DTB 物理地址（S1 用不到，传 0）。
.section .text
.global _start
.type _start, @function
_start:
    // 栈放在 PSRAM 顶部（0x11000000 + 8MB - 4KB）
    li   sp, 0x117ff000
    // a0/a1 已经是 C 函数 main_c(hart, dtb) 的参数位置，直接调用
    call main_c
1:  j    1b
