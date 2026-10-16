#define _GNU_SOURCE
#include <endian.h>
#include <errno.h>
#include <linux/capability.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/syscall.h>
#include <sys/xattr.h>
#include <unistd.h>

#ifdef FAIL_CAPABILITY_RESTORE
int setxattr(const char *path, const char *name, const void *value,
             size_t size, int flags)
{
    static int fail_once = 1;
    if (fail_once && strcmp(name, "security.capability") == 0) {
        fail_once = 0;
        errno = EPERM;
        return -1;
    }
    return (int)syscall(SYS_setxattr, path, name, value, size, flags);
}
#else
static void check(int success, const char *operation)
{
    if (!success) {
        perror(operation);
        exit(EXIT_FAILURE);
    }
}

int main(int argument_count, char **arguments)
{
    if (argument_count == 1) {
        struct __user_cap_header_struct header = {
            .version = _LINUX_CAPABILITY_VERSION_3
        };
        struct __user_cap_data_struct process_caps[2] = {0};
        check(syscall(SYS_capget, &header, process_caps) == 0, "capget");
        if (!(process_caps[0].effective & (1U << CAP_NET_RAW))) {
            fputs("effective CAP_NET_RAW is missing\n", stderr);
            return EXIT_FAILURE;
        }
        return EXIT_SUCCESS;
    }
    if (argument_count != 4) {
        fputs("usage: probe {set|check|empty|check-empty} PATH ROOT_ID\n",
              stderr);
        return EXIT_FAILURE;
    }
    uint32_t root_id = (uint32_t)strtoul(arguments[3], NULL, 10);
    int empty = strcmp(arguments[1], "empty") == 0 ||
                strcmp(arguments[1], "check-empty") == 0;
    int rich = strcmp(arguments[1], "set-rich") == 0 ||
               strcmp(arguments[1], "check-rich") == 0;
    struct vfs_ns_cap_data expected = {0};
    expected.magic_etc = htole32((root_id ? VFS_CAP_REVISION_3 :
                                VFS_CAP_REVISION_2) |
                               (empty ? 0 : VFS_CAP_FLAGS_EFFECTIVE));
    if (!empty)
        expected.data[0].permitted = htole32(1U << CAP_NET_RAW);
    if (rich) {
        expected.data[0].inheritable = htole32(1U << CAP_CHOWN);
        expected.data[1].permitted = htole32(1U << (CAP_SYSLOG - 32));
    }
    expected.rootid = htole32(root_id);
    size_t expected_size = root_id ? XATTR_CAPS_SZ_3 : XATTR_CAPS_SZ_2;
    if (strncmp(arguments[1], "check", 5) == 0) {
        struct vfs_ns_cap_data actual = {0};
        ssize_t actual_size = getxattr(arguments[2], "security.capability",
                                       &actual, sizeof(actual));
        check(actual_size >= 0, arguments[2]);
        if ((size_t)actual_size != expected_size ||
            memcmp(&actual, &expected, expected_size) != 0) {
            fprintf(stderr, "capability mismatch: %s, expected root %u\n",
                    arguments[2], root_id);
            return EXIT_FAILURE;
        }
    } else {
        check(setxattr(arguments[2], "security.capability", &expected,
                       expected_size, 0) == 0, arguments[2]);
    }
    return EXIT_SUCCESS;
}
#endif
