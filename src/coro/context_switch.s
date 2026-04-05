# x86_64 coroutine context switch (System V AMD64 ABI).
#
# void switchContext(Context* from, const Context* to);
#   rdi = from
#   rsi = to
#
# Context layout (7 x u64 = 56 bytes):
#   offset 0:  rsp
#   offset 8:  rbx
#   offset 16: rbp
#   offset 24: r12
#   offset 32: r13
#   offset 40: r14
#   offset 48: r15

.global switchContext
.type switchContext, @function

switchContext:
    mov %rsp,  0(%rdi)
    mov %rbx,  8(%rdi)
    mov %rbp, 16(%rdi)
    mov %r12, 24(%rdi)
    mov %r13, 32(%rdi)
    mov %r14, 40(%rdi)
    mov %r15, 48(%rdi)

    mov 48(%rsi), %r15
    mov 40(%rsi), %r14
    mov 32(%rsi), %r13
    mov 24(%rsi), %r12
    mov 16(%rsi), %rbp
    mov  8(%rsi), %rbx
    mov  0(%rsi), %rsp

    ret

.size switchContext, .-switchContext
