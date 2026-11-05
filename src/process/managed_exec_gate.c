/* Private StdioBroker exec boundary. The broker owns supervision and facts. */
#define _DARWIN_C_SOURCE 1
#include <errno.h>
#include <fcntl.h>
#include <signal.h>
#include <stddef.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

#define GATE_FD 3
#define CHALLENGE_SIZE 32
#define ACK_LIMIT 96

static int write_all(const char *bytes, size_t size)
{
    size_t used = 0;
    while (used < size) {
        ssize_t count = write(GATE_FD, bytes + used, size - used);
        if (count < 0 && errno == EINTR) continue;
        if (count <= 0) return -1;
        used += (size_t)count;
    }
    return 0;
}

static void fail_gate(const char *challenge, const char *phase, int error,
                      const struct sigaction *ignore_pipe)
{
    char frame[192], digits[16];
    size_t used = 0, length = 0;
    unsigned int value = (unsigned int)(error > 0 ? error : EIO);
    (void)sigaction(SIGPIPE, ignore_pipe, NULL);
    const char *prefix = "METIS-EXEC-ERROR:1:";
    memcpy(frame + used, prefix, strlen(prefix)); used += strlen(prefix);
    memcpy(frame + used, challenge, CHALLENGE_SIZE); used += CHALLENGE_SIZE;
    frame[used++] = ':';
    memcpy(frame + used, phase, strlen(phase)); used += strlen(phase);
    frame[used++] = ':';
    do { digits[length++] = (char)('0' + value % 10); value /= 10; } while (value != 0);
    while (length != 0) frame[used++] = digits[--length];
    frame[used++] = '\n';
    (void)write_all(frame, used);
    /* Internal errors share a code; callers must use the private record. */
    _exit(125);
}

int main(int argc, char **argv)
{
    const char unknown[] = "00000000000000000000000000000000";
    const char hello_prefix[] = "METIS-EXEC-GATE:1:";
    const char ack_prefix[] = "METIS-EXEC-ACK:1:";
    char ack[ACK_LIMIT], challenge[CHALLENGE_SIZE + 1];
    unsigned char random_bytes[CHALLENGE_SIZE / 2];
    struct sigaction original_pipe, ignore_pipe;
    memset(&ignore_pipe, 0, sizeof(ignore_pipe));
    ignore_pipe.sa_handler = SIG_IGN;
    (void)sigemptyset(&ignore_pipe.sa_mask);
    if (sigaction(SIGPIPE, &ignore_pipe, &original_pipe) < 0) _exit(125);
    int flags = fcntl(GATE_FD, F_GETFD);
    if (flags < 0 || fcntl(GATE_FD, F_SETFD, flags | FD_CLOEXEC) < 0)
        fail_gate(unknown, "setup", errno, &ignore_pipe);
    if (argc < 2) fail_gate(unknown, "setup", EINVAL, &ignore_pipe);
    arc4random_buf(random_bytes, sizeof(random_bytes));
    const char hex[] = "0123456789abcdef";
    for (size_t index = 0; index < sizeof(random_bytes); ++index) {
        challenge[index * 2] = hex[random_bytes[index] >> 4];
        challenge[index * 2 + 1] = hex[random_bytes[index] & 15];
    }
    challenge[CHALLENGE_SIZE] = '\0';
    if (write_all(hello_prefix, sizeof(hello_prefix) - 1) != 0 ||
        write_all(challenge, CHALLENGE_SIZE) != 0 || write_all("\n", 1) != 0) _exit(125);

    size_t used = 0;
    for (;;) {
        char byte;
        ssize_t count = read(GATE_FD, &byte, 1);
        if (count < 0 && errno == EINTR) continue;
        if (count <= 0) fail_gate(challenge, "protocol", count < 0 ? errno : EPROTO, &ignore_pipe);
        if (used >= sizeof(ack)) fail_gate(challenge, "protocol", EOVERFLOW, &ignore_pipe);
        ack[used++] = byte;
        if (byte == '\n') break;
    }
    size_t prefix_size = sizeof(ack_prefix) - 1;
    if (used != prefix_size + CHALLENGE_SIZE + 1 ||
        memcmp(ack, ack_prefix, prefix_size) != 0)
        fail_gate(challenge, "protocol", EPROTO, &ignore_pipe);
    for (size_t index = 0; index < CHALLENGE_SIZE; ++index) {
        char byte = ack[prefix_size + index];
        if (!((byte >= '0' && byte <= '9') || (byte >= 'a' && byte <= 'f')))
            fail_gate(challenge, "protocol", EPROTO, &ignore_pipe);
    }
    if (memcmp(ack + prefix_size, challenge, CHALLENGE_SIZE) != 0)
        fail_gate(challenge, "protocol", EPROTO, &ignore_pipe);
    if (sigaction(SIGPIPE, &original_pipe, NULL) < 0)
        fail_gate(challenge, "setup", errno, &ignore_pipe);

    /* libc supplies the SDK's PATH search and real-exec ENOEXEC fallback. */
    (void)execvp(argv[1], argv + 1);
    int exec_error = errno;
    fail_gate(challenge, "exec", exec_error, &ignore_pipe);
}
