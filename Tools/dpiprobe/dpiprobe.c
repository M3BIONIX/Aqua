// dpiprobe: for each visible top-level window, prints its DPI awareness and DPI as Wine sees them.
// "unaware" windows are drawn at 96 DPI and stretched, which looks soft on Retina.
// Build: zig cc -target x86_64-windows-gnu -O2 dpiprobe.c -o dpiprobe.exe -luser32
#include <windows.h>
#include <stdio.h>
static const char *names[] = { "unaware", "system-aware", "per-monitor-aware" };
static BOOL CALLBACK each(HWND hwnd, LPARAM unused) {
    if (!IsWindowVisible(hwnd)) return TRUE;
    RECT r; GetWindowRect(hwnd, &r);
    if (r.right - r.left < 100) return TRUE;
    char title[128] = {0}; GetWindowTextA(hwnd, title, sizeof(title));
    DPI_AWARENESS a = GetAwarenessFromDpiAwarenessContext(GetWindowDpiAwarenessContext(hwnd));
    printf("\"%s\" %ldx%ld awareness=%s dpi=%u\n", title, r.right - r.left, r.bottom - r.top,
           (a >= 0 && a <= 2) ? names[a] : "invalid", GetDpiForWindow(hwnd));
    return TRUE;
}
int main(void) {
    SetProcessDpiAwarenessContext(DPI_AWARENESS_CONTEXT_PER_MONITOR_AWARE_V2);
    printf("system dpi=%u\n", GetDpiForSystem());
    EnumWindows(each, 0);
    return 0;
}
