/* Opt-in Linux fixture control. Godot NetSocketUnix::recv uses libc recv. */
#define _GNU_SOURCE
#include <dlfcn.h>
#include <errno.h>
#include <pthread.h>
#include <stdio.h>
#include <stdlib.h>
#include <sys/socket.h>

static ssize_t (*real_recv)(int, void *, size_t, int);
static size_t cap;
static const char *report_path;
static unsigned long reads, limited_reads, bytes, largest;
static pthread_mutex_t lock = PTHREAD_MUTEX_INITIALIZER;

__attribute__((constructor)) static void initialize(void) {
    real_recv = dlsym(RTLD_NEXT, "recv");
    const char *value = getenv("SF_RECV_CAP_BYTES");
    cap = value ? strtoul(value, NULL, 10) : 0;
    report_path = getenv("SF_RECV_CAP_REPORT");
}

ssize_t recv(int fd, void *buffer, size_t length, int flags) {
    if (!real_recv) {
        errno = ENOSYS;
        return -1;
    }
    size_t requested = length;
    if (cap && length > cap) {
        length = cap;
    }
    ssize_t result = real_recv(fd, buffer, length, flags);
    int saved_errno = errno;
    if (result > 0) {
        pthread_mutex_lock(&lock);
        reads++;
        limited_reads += requested > length;
        bytes += (unsigned long)result;
        if ((unsigned long)result > largest) {
            largest = (unsigned long)result;
        }
        pthread_mutex_unlock(&lock);
    }
    errno = saved_errno;
    return result;
}

__attribute__((destructor)) static void report(void) {
    if (!report_path) {
        return;
    }
    FILE *stream = fopen(report_path, "wx");
    if (!stream) {
        return;
    }
    pthread_mutex_lock(&lock);
    fprintf(stream,
            "{\"cap_bytes\":%zu,\"reads\":%lu,\"limited_reads\":%lu,"
            "\"bytes\":%lu,\"largest_read\":%lu}\n",
            cap, reads, limited_reads, bytes, largest);
    pthread_mutex_unlock(&lock);
    fclose(stream);
}
