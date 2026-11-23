#include <fcntl.h>
#include "kernel/calls.h"
#include "platform/platform.h"

int get_random(char *buf, size_t len) {
    return platform_get_random_bytes(buf, len);
}

dword_t sys_getrandom(addr_t buf_address, dword_t len, dword_t UNUSED(flags)) {
    if (len > 1 << 20)
        return _EIO;
    // Small requests (stack canaries, hash seeds, UUIDs — the dominant
    // startup traffic) skip the malloc/free round trip on a stack buffer.
    char stack_buf[512];
    char *buf = len <= sizeof(stack_buf) ? stack_buf : malloc(len);
    if (buf == NULL)
        return _ENOMEM;
    if (get_random(buf, len) != 0) {
        if (buf != stack_buf)
            free(buf);
        return _EIO;
    }
    if (user_write(buf_address, buf, len)) {
        if (buf != stack_buf)
            free(buf);
        return _EFAULT;
    }
    if (buf != stack_buf)
        free(buf);
    return len;
}
