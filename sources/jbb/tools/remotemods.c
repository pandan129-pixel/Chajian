#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <mach/mach.h>
#include <mach/task_info.h>
#include <mach-o/dyld_images.h>

int main(int argc, char **argv) {
    if (argc < 2) { printf("usage: %s <pid> [filter]\n", argv[0]); return 2; }
    pid_t pid = atoi(argv[1]);
    const char *filter = argc > 2 ? argv[2] : NULL;
    mach_port_t task = MACH_PORT_NULL;
    kern_return_t kr = task_for_pid(mach_task_self(), pid, &task);
    if (kr != KERN_SUCCESS) { printf("task_for_pid(%d) failed: %s (%d)\n", pid, mach_error_string(kr), kr); return 3; }

    struct task_dyld_info tdi;
    mach_msg_type_number_t cnt = TASK_DYLD_INFO_COUNT;
    kr = task_info(task, TASK_DYLD_INFO, (task_info_t)&tdi, &cnt);
    if (kr != KERN_SUCCESS) { printf("task_info failed: %s\n", mach_error_string(kr)); return 4; }

    struct dyld_all_image_infos ai;
    vm_size_t outsz = 0;
    kr = vm_read_overwrite(task, (vm_address_t)tdi.all_image_info_addr,
                          sizeof(ai), (vm_address_t)&ai, &outsz);
    if (kr != KERN_SUCCESS) { printf("read all_image_infos failed: %s\n", mach_error_string(kr)); return 5; }

    printf("remote images = %u\n", ai.infoArrayCount);
    size_t arrsz = (size_t)ai.infoArrayCount * sizeof(struct dyld_image_info);
    struct dyld_image_info *arr = malloc(arrsz);
    kr = vm_read_overwrite(task, (vm_address_t)ai.infoArray, arrsz, (vm_address_t)arr, &outsz);
    if (kr != KERN_SUCCESS) { printf("read infoArray failed: %s\n", mach_error_string(kr)); return 6; }

    int shown = 0;
    for (uint32_t i = 0; i < ai.infoArrayCount; i++) {
        char path[1024] = {0};
        vm_size_t n = 0;
        if (vm_read_overwrite(task, (vm_address_t)arr[i].imageFilePath,
                              sizeof(path)-1, (vm_address_t)path, &n) != KERN_SUCCESS) continue;
        path[sizeof(path)-1] = 0;
        if (!filter || strcasestr(path, filter)) { printf("  %s\n", path); shown++; }
    }
    printf("matched = %d\n", shown);
    return 0;
}
