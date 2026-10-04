/* Test program for "Add a Windows game". Named setup*.exe it installs itself (plus a fake
 * uninstaller) into C:\Program Files\Aqua Test Game; otherwise it records that it ran. */
#include <windows.h>
#include <stdio.h>
#include <string.h>

int main(int argc, char **argv)
{
    char self[MAX_PATH];
    GetModuleFileNameA(NULL, self, MAX_PATH);
    const char *name = strrchr(self, '\\') ? strrchr(self, '\\') + 1 : self;
    if (_strnicmp(name, "setup", 5) == 0) {
        CreateDirectoryA("C:\\Program Files\\Aqua Test Game", NULL);
        if (!CopyFileA(self, "C:\\Program Files\\Aqua Test Game\\AquaTestGame.exe", FALSE)) return 1;
        CopyFileA(self, "C:\\Program Files\\Aqua Test Game\\unins000.exe", FALSE);
        printf("installed\n");
        return 0;
    }
    FILE *f = fopen("C:\\aqua-test-game-ran.txt", "w");
    if (!f) return 1;
    fprintf(f, "ran from %s with %d args\n", self, argc - 1);
    fclose(f);
    return 0;
}
