/* Prints the memory Windows reports, to check AQUA_MEMORY_LIMIT_MB. */
#include <windows.h>
#include <stdio.h>

int main(void)
{
    MEMORYSTATUSEX status = { sizeof(status) };
    GlobalMemoryStatusEx(&status);
    printf("TotalPhys %llu MB, AvailPhys %llu MB, Load %lu%%\n",
           status.ullTotalPhys >> 20, status.ullAvailPhys >> 20, status.dwMemoryLoad);
    return 0;
}
