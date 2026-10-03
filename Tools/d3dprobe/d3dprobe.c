// d3dprobe: creates a DXGI factory and a D3D11 (and optionally D3D12) device and prints
// which adapter answered. Used to verify Aqua's renderer setup inside a bottle.
// Build: zig cc -target x86_64-windows-gnu -O2 d3dprobe.c -o d3dprobe.exe -ld3d11 -ldxgi
// Run:   aqua-cli exec epic <d3dmetal|dxmt|dxvk|wined3d> Tools/d3dprobe/d3dprobe.exe
#define COBJMACROS
#include <stdio.h>
#include <windows.h>
#include <dxgi.h>
#include <d3d11.h>
#include <d3d12.h>

static void describe_adapter(IDXGIAdapter *adapter) {
    DXGI_ADAPTER_DESC desc;
    if (SUCCEEDED(IDXGIAdapter_GetDesc(adapter, &desc))) {
        wprintf(L"adapter: %ls (vendor %04x device %04x, %llu MB)\n", desc.Description, desc.VendorId, desc.DeviceId,
                (unsigned long long)(desc.DedicatedVideoMemory / (1024 * 1024)));
    }
}

int main(void) {
    IDXGIFactory1 *factory = NULL;
    HRESULT hr = CreateDXGIFactory1(&IID_IDXGIFactory1, (void **)&factory);
    printf("CreateDXGIFactory1: 0x%08lx\n", (unsigned long)hr);
    if (SUCCEEDED(hr)) {
        IDXGIAdapter1 *adapter = NULL;
        if (SUCCEEDED(IDXGIFactory1_EnumAdapters1(factory, 0, &adapter))) {
            describe_adapter((IDXGIAdapter *)adapter);
            IDXGIAdapter1_Release(adapter);
        }
        IDXGIFactory1_Release(factory);
    }

    ID3D11Device *device = NULL;
    D3D_FEATURE_LEVEL level = 0;
    hr = D3D11CreateDevice(NULL, D3D_DRIVER_TYPE_HARDWARE, NULL, 0, NULL, 0, D3D11_SDK_VERSION, &device, &level, NULL);
    printf("D3D11CreateDevice: 0x%08lx feature level %x\n", (unsigned long)hr, (unsigned)level);
    if (SUCCEEDED(hr)) {
        HMODULE d3d11 = GetModuleHandleA("d3d11.dll");
        char path[MAX_PATH] = {0};
        GetModuleFileNameA(d3d11, path, MAX_PATH);
        printf("d3d11 loaded from: %s\n", path);
        ID3D11Device_Release(device);
    }
    int ok11 = SUCCEEDED(hr);

    // D3D12 is optional: only D3DMetal provides it on macOS.
    HMODULE d3d12 = LoadLibraryA("d3d12.dll");
    PFN_D3D12_CREATE_DEVICE create12 = d3d12 ? (PFN_D3D12_CREATE_DEVICE)(void *)GetProcAddress(d3d12, "D3D12CreateDevice") : NULL;
    if (create12) {
        ID3D12Device *device12 = NULL;
        hr = create12(NULL, D3D_FEATURE_LEVEL_12_0, &IID_ID3D12Device, (void **)&device12);
        printf("D3D12CreateDevice: 0x%08lx\n", (unsigned long)hr);
        if (SUCCEEDED(hr)) ID3D12Device_Release(device12);
    } else {
        printf("D3D12CreateDevice: unavailable\n");
    }
    return ok11 ? 0 : 1;
}
