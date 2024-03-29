/*
 Name        : main.c
 Author      : Gil
 Version     :
 Copyright   :
 Description : Hello RISC-V on FPGA
 */

#define IO_BASE 0xc0000000
#define IO_MTIME (volatile uint64_t *)(IO_BASE + 0x00004000)
#define IO_MTIMECMP (volatile uint64_t *)(IO_BASE + 0x00004008)

#include <stdio.h>
#include <stdint.h>

uint32_t lock_var = 0;

void handle_trap() {
    uint32_t mcause;
    asm volatile("csrr %0, mcause" : "=r"(mcause));

	switch (mcause) {
		case 0x80000007: { // Timer
		    // Clear the mip interrupt pending bit
		    uint32_t mip = 1 << 7;
		    asm volatile("csrc mip, %0" : : "r"(mip));

		    // Generate an interrupt after n units of time
		    *IO_MTIMECMP = *IO_MTIME + 1000;

		    //*((char*)NULL) = (char)1;
		break;
		}

		case 0x8000000b: { // External interrupts
		    // Clear the mip interrupt pending bit
		    uint32_t mip = 1 << 11;
		    asm volatile("csrc mip, %0" : : "r"(mip));
		break;
		}

		case 0: // EX_CODE_INSTRUCTION_ADDRESS_MISALIGNED
		case 1: // EX_CODE_INSTRUCTION_ACCESS_FAULT
			/*
			 * Execution for these exceptions cannot be resumed.
			 * The processor saves 0 in the mtval and the next instruction cannot be
			 * computed upon exiting the interrupt routine.
			 */
			while (1);
		break;

		case 2: // EX_CODE_ILLEGAL_INSTRUCTION
		case 4: // EX_CODE_LOAD_ADDRESS_MISALIGNED
		case 5: // EX_CODE_LOAD_ACCESS_FAULT
		case 6: // EX_CODE_STORE_ADDRESS_MISALIGNED
		case 7: // EX_CODE_STORE_ACCESS_FAULT
			/*
			 * Execution for these exceptions can be resumed (yet it makes no sense for machine).
			 * The processor saves the instruction that caused the fault in the mtval and the
			 * next instruction is computed upon exiting the interrupt routine.
			 */
			while (1);
		break;

		case 3: // EX_CODE_BREAKPOINT
			// The debugger function is not supported.
			// Stop execution
			while (1);
	    break;

		case 8: // EX_CODE_ECALL
			// Do any work you need to do and then...
			while (1);
		break;

		default: // Unhandled exception
			while (1);
		break;
	}
}

void atomic_lr_sc() {
	asm ("again:");
	//asm volatile("la a0, lock_var");
	asm volatile("la a0, 0xc0100000");
	asm volatile("li a1, 0");
	asm volatile("lr.w.aq a3, (a0)");
	asm volatile("bne a3, a1, again");

	asm volatile("sc.w.rl a3, a2, (a0)");
	asm volatile("bnez a3, again");
}

/*
 * Demonstrate how to print a greeting message on standard output and exit.
 */
int main(void) {
    // Generate an interrupt after 100 units of time
    *IO_MTIMECMP = *IO_MTIME + 100;
	// The string will end up in the .rodata or .data section (depending on the compiler)
	// It will live in ROM unless we copy it to RAM.
	// The code will end up in the .text section
	printf("Hello RISC-V on FPGA!" "\n");

	atomic_lr_sc();

	// Simulate a NULL Pointer Exception
//	*((char*)NULL) = (char)1;

	return 0;
}

