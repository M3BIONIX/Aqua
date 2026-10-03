// fontprobe: lists font families Wine exposes, and what common Windows UI fonts resolve to.
// Build: zig cc -target x86_64-windows-gnu -O2 fontprobe.c -o fontprobe.exe -lgdi32
#include <windows.h>
#include <stdio.h>
static int count;
static int CALLBACK each(const LOGFONTA *lf, const TEXTMETRICA *tm, DWORD type, LPARAM all) {
    count++;
    if (all) printf("%s\n", lf->lfFaceName);
    return 1;
}
int main(int argc, char **argv) {
    HDC dc = GetDC(NULL);
    LOGFONTA lf = { .lfCharSet = DEFAULT_CHARSET };
    EnumFontFamiliesExA(dc, &lf, (FONTENUMPROCA)each, argc > 1, 0);
    printf("families: %d\n", count);
    const char *wanted[] = { "Segoe UI", "Microsoft YaHei", "Microsoft YaHei UI", "Arial", "Tahoma", "Helvetica Neue", "PingFang SC" };
    for (int i = 0; i < 7; i++) {
        HFONT f = CreateFontA(-16, 0, 0, 0, 400, 0, 0, 0, DEFAULT_CHARSET, 0, 0, 0, 0, wanted[i]);
        HGDIOBJ old = SelectObject(dc, f);
        char face[64] = {0};
        GetTextFaceA(dc, sizeof(face), face);
        printf("%-20s -> %s\n", wanted[i], face);
        SelectObject(dc, old); DeleteObject(f);
    }
    return 0;
}
