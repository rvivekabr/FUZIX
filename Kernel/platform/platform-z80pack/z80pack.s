# 0 "z80pack.S"
# 0 "<built-in>"
# 0 "<command-line>"
# 1 "z80pack.S"
;
; Z80Pack hardware support
;
;
; This goes straight after udata for common.
;


 ; exported symbols
 .export init_early
 .export init_hardware
 .export _program_vectors
 .export plt_interrupt_all

 .export map_kernel
 .export map_kernel_di
 .export map_kernel_restore
 .export map_proc
 .export map_proc_di
 .export map_proc_always
 .export map_proc_always_di
 .export map_proc_a
 .export map_save_kernel
 .export map_restore

 .export mmu_user
 .export mmu_kernel
 .export mmu_kernel_irq
 .export mmu_restore_irq

 .export _fd_bankcmd

 .export _int_disabled

 .export _plt_reboot

 ; exported debugging tools
 .export _plt_monitor
 .export outchar

# 1 "kernelu.def" 1
; UZI mnemonics for memory addresses etc
# 42 "z80pack.S" 2
# 1 "../../cpu-z80u/kernel-z80.def" 1
# 43 "z80pack.S" 2

; -----------------------------------------------------------------------------
; COMMON MEMORY BANK (0xF000 upwards)
; -----------------------------------------------------------------------------

 .common

_plt_monitor:
 ld a, 128
 out (29), a
plt_interrupt_all:
 ret

_plt_reboot:
 ld a, 1
 out (29), a

;
; We need the right bank present when we cause the transfer
;
_fd_bankcmd:
 ld de,#5
 add hl,de
 ld d,(hl)
 dec hl
 ld h,(hl)
 dec hl
 dec hl
 ld l,(hl)

 ex de,hl ; bank to HL command to E

 ld a, (_int_disabled)
 di
 push af ; save DI state
 call map_proc_di ; HL alread holds our bank
 ld a, e ; issue the command
 out (13), a ;
 call map_kernel_di ; return to kernel mapping
 pop af
 or a
 ret nz
 ei
 ret

; -----------------------------------------------------------------------------
; KERNEL MEMORY BANK (below 0xC000, only accessible when the kernel is mapped)
; -----------------------------------------------------------------------------
 .code

init_early:
 ld a, 240 ; 240 * 256 bytes (60K)
 out (22), a ; set up memory banking
 ld a, 8
 out (20), a ; 8 segments
 ret

init_hardware:
 ; set system RAM size
 ld hl, 484
 ld (_ramsize), hl
 ld hl, (484-64) ; 64K for kernel
 ld (_procmem), hl

 ld a, 1
 out (27), a ; 100Hz timer on

 ; set up interrupt vectors for the kernel (also sets up common memory in page 0x000F which is unused)
 ld hl, 0
 push hl
 call _program_vectors
 pop hl

 ld a, 0xfe ; Use FEFF (currently free)
 ld i, a
 im 2 ; set CPU interrupt mode
 ret


;------------------------------------------------------------------------------
; COMMON MEMORY PROCEDURES FOLLOW

 .common

_int_disabled:
 .byte 1

_program_vectors:
 ; we are called, with interrupts disabled, by both newproc() and crt0
 ; will exit with interrupts off
 di ; just to be sure
 pop de ; temporarily store return address
 pop hl ; function argument -- base page number
 push hl ; put stack back as it was
 push de

 call map_proc

 ; write zeroes across all vectors
 ld hl, 0
 ld de, 1
 ld bc, 0x007f ; program first 0x80 bytes only
 ld (hl), 0x00
 ldir

 ; now install the interrupt vector at 0xFEFF
 ld hl, interrupt_handler
 ld (0xFEFF), hl

 ld a,0xC3 ; JP
 ; set restart vector for UZI system calls
 ld (0x0030), a ; (rst 30h is unix function call vector)
 ld hl, unix_syscall_entry
 ld (0x0031), hl

 ; Set vector for jump to NULL
 ld (0x0000), a
 ld hl, null_handler ; to Our Trap Handler
 ld (0x0001), hl

 ld (0x0066), a ; Set vector for NMI
 ld hl, nmi_handler
 ld (0x0067), hl

 ; our platform has a "true" common area, if it did not we would
 ; need to copy the "common" code into the common area of the new
 ; process.

 ; falls through

 ; put the paging back as it was -- we're in kernel mode so this is predictable
map_kernel:
map_kernel_di:
map_kernel_restore:
 push af
 xor a
 out (21), a
 pop af
 ret
map_proc:
map_proc_di:
 ld a, h
 or l
 jr z, map_kernel
 ld a, (hl)
map_proc_a:
 out (21), a
 ret
map_proc_always:
map_proc_always_di:
 push af
 ld a, (_udata + 2)
 out (21), a
 pop af
 ret
map_save_kernel:
 push af
 in a, (21)
 ld (map_store), a
 xor a
 out (21),a
 pop af
 ret
map_restore:
 push af
 ld a, (map_store)
 out (21), a
 pop af
 ret

map_store:
 .byte 0

 .common

; outchar: Wait for UART TX idle, then print the char in A
; destroys: AF
outchar:
 out (0x01), a
 ret

;
; The entry logic is a bit scary. We want to make sure that we
; don't get tricked into anything bad by messed up callers.
;
; At the point we are called the push hl and call to us might have
; gone onto a dud stack, but if so that is ok as we won't be returning
;
mmu_kernel:
 push af
 push hl
 ld hl,0
 add hl,sp
 ld a,h
 or a ; 00xx is bad
 jr z, badstack
 cp 0xF0
 jr nc, badstack ; Fxxx is bad
 in a,(23)
 bit 7,a ; Tripped MMU is bad if user
 jr nz, badstackifu
do_mmu_kernel:
 xor a ; Switch MMU off
 out (23),a
 pop hl
 pop af
 ret
;
; We have been called with SP pointing into la-la land. That means
; something bad has happened to our process (or the kernel)
;
badstack:
 ld a, (_udata + 6)
 or a
 jr nz, badbadstack
 ld a, (_udata + 16)
 or a
 jr nz, badbadstack
 ;
 ; Ok we are in user mode, this is less bad.
 ; Fake a sigkill
 ;
badstack_do:
 ld sp,#kstack_top ; Our syscall stack
 xor a
 out (23),a ; MMU off
 call map_kernel ; So we can _doexit
 ld hl, 9 ; SIGKILL
 push hl
; ld a,#'@'
; call outchar
 call _doexit ; Will not return
 ld hl,zombieapocalypse
 push hl
 call _panic
zombieapocalypse:
 .ascii "ZombAp"
 .byte 0

badbadstack:
 ld hl,#badbadstack_msg
 push hl
 call _panic

badstackifu:
 ld a, (_udata + 6)
 or a
 jr nz, do_mmu_kernel
 ld a, (_udata + 16)
 or a
 jr nz, do_mmu_kernel
 jr badstack_do

;
; IRQ version - we need different error handling as we can't just
; exit and have the IRQ vanish (we'd survive fine but the IRQ wouldn't
; get processed).
;
mmu_kernel_irq:
 ld hl,0
 add hl,sp
 ld a,h
 or a
 jr z, badstackirq
 inc a
 jr z,badstackirq
 in a,(23)
 bit 7,a
 jr nz, badstackirqifu
do_mmu_kernel_irq:
 in a,(23)
 ld l,a
 xor a
 out (23),a
 ld a,l
 ld (mmusave),a
 jp mmu_irq_ret

 ld a, (_udata + 6)
 or a
 ld a, (_udata + 16)
 or a
badstackirq:
 ld a, (_udata + 6)
 or a
 jr nz, badbadstack_irq
 ld a, (_udata + 16)
 or a
 jr nz, badbadstack_irq
badstack_doirq:
 ;
 ; If we get here we *are* interrupted from user space and
 ; thus we can safely use map_save/map_restore
 ;
 ; Put the stack somewhere that will be safe - kstack will do
 ; The user stack won't do as we're going to switch to kernel
 ; mappings
 ld sp,kstack_top
 xor a
 out (23),a ; MMU off so we can do our job
; ld a,#'!'
; call outchar
 call map_save_kernel
 ld hl,9
 push hl
 ld hl,(_udata + 0)
 push hl
 call _ssig
 pop hl
 pop hl
 ld a,1
 ld (_need_resched),a
 call map_restore
 ;
 ; Ok this looks pretty wild but the idea is that the stack we
 ; came in on could be completely hosed so we just need somewhere
 ; in user memory to scribble freely. The pre-emption path will
 ; kill us before we return to userland and use that stack for
 ; anything non-kernel
 ;
 ld sp,0x8000
 jp mmu_irq_ret
 ; This will complete the IRQ and then hit preemption at which
 ; point it'll call switchout, chksigs and vanish forever
badstackirqifu:
 ld a, (_udata + 6)
 or a
 jr nz, do_mmu_kernel_irq
 ld a, (_udata + 16)
 or a
 jr nz, do_mmu_kernel_irq
 jr badstack_doirq

badbadstack_irq:
 ld hl,#badbadstackirq_msg
 push hl
 call _panic

badbadstackirq_msg:
 .ascii 'IRQ:'
badbadstack_msg:
 .ascii 'MMU trap/bad stack'
 .byte 0


;
; This side is easy. We are coming from a sane context (hopefully).
; MMU on, clear flag.
;
mmu_restore_irq:
 ld a,(mmusave)
 and 0x01
 out (23),a
 ret
mmu_user:
 ld a,1
 out (23),a
 ret
mmusave:
 .byte 0
