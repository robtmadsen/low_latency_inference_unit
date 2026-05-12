// UVM DPI function stubs for Verilator
#include "verilated.h"
#include "verilated_dpi.h"
#include <cstring>
#include <cstdlib>
#include <cstdio>
#include <regex.h>

extern "C" {

// ---- HDL backdoor access (not supported in Verilator) ----
int uvm_hdl_check_path(const char* path) { return 0; }
int uvm_hdl_deposit(const char* path, const svLogicVecVal* value, int size) { return 0; }
int uvm_hdl_release(const char* path, int size) { return 0; }
int uvm_hdl_read(const char* path, svLogicVecVal* value, int size) { return 0; }

// ---- Command-line argument access ----
static int    s_argc = 0;
static char** s_argv = nullptr;
static int    s_arg_idx = 0;

const char* uvm_dpi_get_next_arg_c(int init) {
    if (init) { s_arg_idx = 0; }
    if (s_argv && s_arg_idx < s_argc) return s_argv[s_arg_idx++];
    return "";
}

// Called from main() before simulation starts to provide args
void uvm_dpi_set_args(int argc, char** argv) {
    s_argc = argc;
    s_argv = argv;
}

const char* uvm_dpi_get_tool_name_c() { return "verilator"; }

const char* uvm_dpi_get_tool_version_c() { return "5.046"; }

// ---- Regex support ----
int uvm_re_compexec(const char* re_str, const char* str,
                    unsigned char deglob, int* cached_regex) {
    if (!re_str || !str) return 1;
    if (re_str[0] == '\0') return 0;  // empty pattern matches all

    regex_t reg;
    int ret = regcomp(&reg, re_str, REG_EXTENDED | REG_NOSUB);
    if (ret != 0) return 1;
    ret = regexec(&reg, str, 0, nullptr, 0);
    regfree(&reg);
    return (ret == 0) ? 0 : 1;
}

unsigned char uvm_re_compexecfree(const char* re_str, const char* str,
                                   unsigned char deglob, int* cached_regex) {
    return uvm_re_compexec(re_str, str, deglob, cached_regex) == 0 ? 1 : 0;
}

void uvm_re_free(void* regex_ptr) { /* no-op */ }

const char* uvm_re_buffer() {
    static char buf[256] = "";
    return buf;
}

const char* uvm_re_deglobbed(const char* glob_str, unsigned char with_brackets) {
    static char buf[1024];
    if (!glob_str) { buf[0] = '\0'; return buf; }
    // Simple deglob: return as-is (UVM uses this for pattern matching)
    snprintf(buf, sizeof(buf), "%s", glob_str);
    return buf;
}

// ---- Polling stubs (not used in basic UVM) ----
void* uvm_polling_create(const char* name, int size) { return nullptr; }
void  uvm_polling_destroy(void* handle) {}
int   uvm_polling_check(void* handle) { return 0; }

// ---- Report DPI (used by uvm_common.c) ----
void m_uvm_report_dpi(int severity, const char* id, const char* message,
                       int verbosity, const char* file, int line) {
    // Fallback: print to stderr
    fprintf(stderr, "UVM_DPI [%s] %s\n", id ? id : "", message ? message : "");
}

}  // extern "C"
