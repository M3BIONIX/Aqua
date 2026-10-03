// winshot: saves every visible top-level window in the current Wine prefix as a BMP,
// so window contents can be checked without macOS screen-recording permission.
// Build: zig cc -target x86_64-windows-gnu -O2 winshot.c -o winshot.exe -lgdi32 -luser32
// Usage: wine winshot.exe <output folder as Windows path, e.g. Z:\tmp\shots>
#include <windows.h>
#include <stdio.h>

static const char *outdir;
static int count;

static void save_bmp(HBITMAP bmp, HDC dc, int w, int h, const char *path) {
    BITMAPINFOHEADER bi = { sizeof(bi), w, -h, 1, 24, BI_RGB };
    int stride = ((w * 3 + 3) & ~3);
    DWORD size = stride * h;
    BYTE *pixels = malloc(size);
    GetDIBits(dc, bmp, 0, h, pixels, (BITMAPINFO *)&bi, DIB_RGB_COLORS);
    BITMAPFILEHEADER bf = { 0x4D42, sizeof(bf) + sizeof(bi) + size, 0, 0, sizeof(bf) + sizeof(bi) };
    FILE *f = fopen(path, "wb");
    if (f) { fwrite(&bf, sizeof(bf), 1, f); fwrite(&bi, sizeof(bi), 1, f); fwrite(pixels, size, 1, f); fclose(f); }
    free(pixels);
}

static BOOL CALLBACK each(HWND hwnd, LPARAM unused) {
    RECT r;
    if (!IsWindowVisible(hwnd) || !GetWindowRect(hwnd, &r)) return TRUE;
    int w = r.right - r.left, h = r.bottom - r.top;
    if (w < 50 || h < 50) return TRUE;
    char title[256] = {0}, path[MAX_PATH];
    GetWindowTextA(hwnd, title, sizeof(title));
    HDC screen = GetDC(NULL), mem = CreateCompatibleDC(screen);
    HBITMAP bmp = CreateCompatibleBitmap(screen, w, h);
    HGDIOBJ old = SelectObject(mem, bmp);
    // Wine's PrintWindow returns empty pixels here; copy from the window's own DC instead,
    // falling back to Wine's virtual screen.
    HDC wdc = GetWindowDC(hwnd);
    BOOL ok = BitBlt(mem, 0, 0, w, h, wdc, 0, 0, SRCCOPY);
    ReleaseDC(hwnd, wdc);
    if (!ok) ok = BitBlt(mem, 0, 0, w, h, screen, r.left, r.top, SRCCOPY) ? 2 : 0;
    // GetDIBits fails while the bitmap is selected into a DC.
    SelectObject(mem, old);
    snprintf(path, sizeof(path), "%s\\window%d.bmp", outdir, count++);
    save_bmp(bmp, mem, w, h, path);
    printf("%s %dx%d copied=%d title=\"%s\"\n", path, w, h, ok, title);
    DeleteObject(bmp); DeleteDC(mem); ReleaseDC(NULL, screen);
    return TRUE;
}

int main(int argc, char **argv) {
    outdir = argc > 1 ? argv[1] : ".";
    EnumWindows(each, 0);
    return 0;
}
