#define _GNU_SOURCE
#include <endian.h>
#include <errno.h>
#include <fcntl.h>
#include <linux/capability.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <sys/stat.h>
#include <sys/xattr.h>
#include <unistd.h>

static uint32_t parse_id(const char *text)
{
    char *end;
    errno = 0;
    unsigned long value = strtoul(text, &end, 10);
    if (text[0] < '0' || text[0] > '9' || *end || errno ||
        value >= UINT32_MAX) {
        fprintf(stderr, "capsule: invalid storage owner ID: %s\n", text);
        exit(EXIT_FAILURE);
    }
    return (uint32_t)value;
}

static int remap_path(const char *path, uid_t old_uid, gid_t old_gid,
                      uid_t new_uid, gid_t new_gid)
{
    int descriptor = open(path, O_PATH | O_NOFOLLOW | O_CLOEXEC);
    if (descriptor < 0)
        return -1;

    int result = -1;
    struct stat metadata;
    struct vfs_ns_cap_data capabilities = {0};
    struct vfs_ns_cap_data original_capabilities = {0};
    ssize_t capability_size = 0;
    int capability_changed = 0;
    int owner_applied = 0;
    char descriptor_path[64];
    snprintf(descriptor_path, sizeof(descriptor_path),
             "/proc/self/fd/%d", descriptor);
    if (fstat(descriptor, &metadata) < 0)
        goto done;

    uid_t uid = metadata.st_uid == old_uid ? new_uid : metadata.st_uid;
    gid_t gid = metadata.st_gid == old_gid ? new_gid : metadata.st_gid;
    int owner_changed = uid != metadata.st_uid || gid != metadata.st_gid;
    if (S_ISREG(metadata.st_mode) && (owner_changed || old_uid != new_uid)) {
        capability_size = getxattr(descriptor_path, "security.capability",
                                   &capabilities, sizeof(capabilities));
        if (capability_size < 0) {
            if (errno != ENODATA && errno != ENOTSUP)
                goto done;
            capability_size = 0;
        }
        if (capability_size > 0) {
            original_capabilities = capabilities;
            uint32_t revision = le32toh(capabilities.magic_etc) &
                                VFS_CAP_REVISION_MASK;
            if ((revision != VFS_CAP_REVISION_1 ||
                 capability_size != XATTR_CAPS_SZ_1) &&
                (revision != VFS_CAP_REVISION_2 ||
                 capability_size != XATTR_CAPS_SZ_2) &&
                (revision != VFS_CAP_REVISION_3 ||
                 capability_size != XATTR_CAPS_SZ_3)) {
                errno = EINVAL;
                goto done;
            }
            if (revision == VFS_CAP_REVISION_3 && old_uid != new_uid &&
                le32toh(capabilities.rootid) == old_uid) {
                capabilities.rootid = htole32(new_uid);
                capability_changed = 1;
            }
        }
    }
    if (owner_changed) {
        if (fchownat(descriptor, "", uid, gid,
                     AT_EMPTY_PATH | AT_SYMLINK_NOFOLLOW) < 0)
            goto done;
        owner_applied = 1;
        if (!S_ISLNK(metadata.st_mode) &&
            (metadata.st_mode & (S_ISUID | S_ISGID)) &&
            chmod(descriptor_path, metadata.st_mode & 07777) < 0)
            goto done;
    }
    if (capability_size > 0 && (owner_changed || capability_changed) &&
        setxattr(descriptor_path, "security.capability", &capabilities,
                 (size_t)capability_size, 0) < 0)
        goto done;
    result = 0;

done:;
    int saved_errno = errno;
    if (result < 0 && owner_applied) {
        if (fchownat(descriptor, "", metadata.st_uid, metadata.st_gid,
                     AT_EMPTY_PATH | AT_SYMLINK_NOFOLLOW) < 0 ||
            (!S_ISLNK(metadata.st_mode) &&
             chmod(descriptor_path, metadata.st_mode & 07777) < 0) ||
            (capability_size > 0 &&
             setxattr(descriptor_path, "security.capability",
                      &original_capabilities, (size_t)capability_size, 0) < 0))
            perror("capsule: cannot roll back storage metadata");
    }
    close(descriptor);
    errno = saved_errno;
    return result;
}

int main(int argument_count, char **arguments)
{
    if (argument_count < 6) {
        fprintf(stderr, "usage: %s OLD_UID OLD_GID UID GID PATH...\n",
                arguments[0]);
        return EXIT_FAILURE;
    }
    uid_t old_uid = parse_id(arguments[1]);
    gid_t old_gid = parse_id(arguments[2]);
    uid_t new_uid = parse_id(arguments[3]);
    gid_t new_gid = parse_id(arguments[4]);
    for (int index = 5; index < argument_count; index++) {
        if (remap_path(arguments[index], old_uid, old_gid,
                       new_uid, new_gid) < 0) {
            perror(arguments[index]);
            return EXIT_FAILURE;
        }
    }
    return EXIT_SUCCESS;
}
