#include <windows.h>
#include <stdio.h>

static HMODULE g_self = nullptr;
static HMODULE g_mobileglues = nullptr;
static wchar_t g_log_path[MAX_PATH] = {};

static void InitLogPath() {
    if (g_log_path[0]) return;

    wchar_t runtimeDir[MAX_PATH] = {};
    DWORD len = GetEnvironmentVariableW(L"MC_RUNTIME_DIR", runtimeDir, ARRAYSIZE(runtimeDir));
    if (len > 0 && len < ARRAYSIZE(runtimeDir)) {
        swprintf_s(g_log_path, L"%s\\xboxone_gl_proxy.log", runtimeDir);
        return;
    }

    swprintf_s(g_log_path, L"xboxone_gl_proxy.log");
}

static void Log(const char* fmt, ...) {
    InitLogPath();
    FILE* f = nullptr;
    _wfopen_s(&f, g_log_path, L"a");
    if (!f) return;

    SYSTEMTIME st;
    GetLocalTime(&st);
    fprintf(f, "[%02d:%02d:%02d.%03d] [xboxone_gl_proxy] ",
        st.wHour, st.wMinute, st.wSecond, st.wMilliseconds);

    va_list args;
    va_start(args, fmt);
    vfprintf(f, fmt, args);
    va_end(args);
    fprintf(f, "\n");
    fclose(f);
}

static void BuildSiblingPath(const wchar_t* file, wchar_t* out, int cch) {
    out[0] = L'\0';
    if (!g_self) return;

    wchar_t modulePath[MAX_PATH] = {};
    if (!GetModuleFileNameW(g_self, modulePath, ARRAYSIZE(modulePath))) return;

    wchar_t* slash = wcsrchr(modulePath, L'\\');
    if (slash) {
        slash[1] = L'\0';
        swprintf_s(out, cch, L"%s%s", modulePath, file);
    }
}

static HMODULE LoadMobileGlues() {
    if (g_mobileglues) return g_mobileglues;

    wchar_t packagedPath[MAX_PATH] = {};
    swprintf_s(packagedPath, L"graphics\\xboxone\\mobileglues.dll");
    g_mobileglues = LoadPackagedLibrary(packagedPath, 0);
    if (g_mobileglues) {
        Log("LoadPackagedLibrary(mobileglues.dll) => %p", (void*)g_mobileglues);
        return g_mobileglues;
    }
    Log("LoadPackagedLibrary(mobileglues.dll) failed err=%u", GetLastError());

    wchar_t siblingPath[MAX_PATH] = {};
    BuildSiblingPath(L"mobileglues.dll", siblingPath, ARRAYSIZE(siblingPath));
    if (siblingPath[0]) {
        g_mobileglues = LoadLibraryW(siblingPath);
        if (g_mobileglues) {
            Log("LoadLibraryW(mobileglues.dll) => %p", (void*)g_mobileglues);
            return g_mobileglues;
        }
        Log("LoadLibraryW(mobileglues.dll) failed err=%u", GetLastError());
    }

    return nullptr;
}

static FARPROC ResolveMobileGluesProc(const char* name) {
    if (!name || !*name) return nullptr;
    HMODULE module = LoadMobileGlues();
    if (!module) return nullptr;
    return GetProcAddress(module, name);
}

extern "C" __declspec(dllexport) void proc_init() {
    using ProcInit = void (*)();
    auto proc = reinterpret_cast<ProcInit>(ResolveMobileGluesProc("proc_init"));
    Log("proc_init forward => %p", (void*)proc);
    if (proc) proc();
}

extern "C" __declspec(dllexport) PROC WINAPI wglGetProcAddress(LPCSTR name) {
    FARPROC proc = nullptr;
    if (g_self && name && *name) {
        proc = GetProcAddress(g_self, name);
    }
    if (!proc) {
        proc = ResolveMobileGluesProc(name);
    }

    static int logCount = 0;
    if (logCount < 2000 || !proc) {
        ++logCount;
        Log("wglGetProcAddress #%d %s => %p", logCount, name ? name : "(null)", (void*)proc);
    }

    return reinterpret_cast<PROC>(proc);
}

extern "C" __declspec(dllexport) PROC WINAPI wglGetProcAddressARB(LPCSTR name) {
    return wglGetProcAddress(name);
}

extern "C" __declspec(dllexport) void* WINAPI eglGetProcAddress(const char* name) {
    using EglGetProcAddress = void* (WINAPI*)(const char*);
    auto proc = reinterpret_cast<EglGetProcAddress>(ResolveMobileGluesProc("eglGetProcAddress"));
    if (proc) return proc(name);
    return reinterpret_cast<void*>(ResolveMobileGluesProc(name));
}

extern "C" __declspec(dllexport) void* WINAPI wglCreateContext(void*) {
    Log("wglCreateContext stub => null");
    return nullptr;
}

extern "C" __declspec(dllexport) void* WINAPI wglCreateLayerContext(void*, int) {
    Log("wglCreateLayerContext stub => null");
    return nullptr;
}

extern "C" __declspec(dllexport) BOOL WINAPI wglCopyContext(void*, void*, UINT) {
    Log("wglCopyContext stub => false");
    return FALSE;
}

extern "C" __declspec(dllexport) BOOL WINAPI wglDeleteContext(void*) {
    Log("wglDeleteContext stub => true");
    return TRUE;
}

extern "C" __declspec(dllexport) void* WINAPI wglGetCurrentContext() {
    return nullptr;
}

extern "C" __declspec(dllexport) void* WINAPI wglGetCurrentDC() {
    return nullptr;
}

extern "C" __declspec(dllexport) BOOL WINAPI wglMakeCurrent(void*, void*) {
    Log("wglMakeCurrent stub => true");
    return TRUE;
}

extern "C" __declspec(dllexport) BOOL WINAPI wglShareLists(void*, void*) {
    Log("wglShareLists stub => false");
    return FALSE;
}

BOOL WINAPI DllMain(HINSTANCE instance, DWORD reason, LPVOID) {
    if (reason == DLL_PROCESS_ATTACH) {
        g_self = instance;
        DisableThreadLibraryCalls(instance);
        InitLogPath();
        FILE* f = nullptr;
        _wfopen_s(&f, g_log_path, L"w");
        if (f) fclose(f);
        Log("DllMain attached");
    }
    return TRUE;
}
