#!/usr/bin/env python3
import os
import sys

def main():
    mesa_dir = sys.argv[1] if len(sys.argv) > 1 else '.'
    print(f'[*] Applying iOS / Darwin patches to Mesa source in {mesa_dir}')

    # 1. freedreno_common.h: fix underlying type (do NOT add <type_traits> outside C++!)
    fd_common = os.path.join(mesa_dir, 'src', 'freedreno', 'common', 'freedreno_common.h')
    if os.path.exists(fd_common):
        with open(fd_common, 'r', encoding='utf-8', errors='ignore') as f:
            txt = f.read()
        if 'using underlying = typename std::underlying_type_t<E>;' in txt:
            txt = txt.replace(
                'using underlying = typename std::underlying_type_t<E>;',
                'using underlying = __underlying_type(E);'
            )
            with open(fd_common, 'w', encoding='utf-8') as f:
                f.write(txt)
            print(f'[+] Patched {fd_common}')
        elif 'using underlying = __underlying_type(E);' in txt:
            print(f'[*] {fd_common} already patched')

    # 2. disk_cache.h: include <dlfcn.h> unconditionally for dladdr
    disk_cache = os.path.join(mesa_dir, 'src', 'util', 'disk_cache.h')
    if os.path.exists(disk_cache):
        with open(disk_cache, 'r', encoding='utf-8', errors='ignore') as f:
            txt = f.read()
        if '#ifdef HAVE_DLFCN_H\n#include <dlfcn.h>' in txt:
            txt = txt.replace('#ifdef HAVE_DLFCN_H\n#include <dlfcn.h>', '#if 1\n#include <dlfcn.h>')
            with open(disk_cache, 'w', encoding='utf-8') as f:
                f.write(txt)
            print(f'[+] Patched {disk_cache}')
        elif '#ifdef HAVE_DLFCN_H\r\n#include <dlfcn.h>' in txt:
            txt = txt.replace('#ifdef HAVE_DLFCN_H\r\n#include <dlfcn.h>', '#if 1\r\n#include <dlfcn.h>')
            with open(disk_cache, 'w', encoding='utf-8') as f:
                f.write(txt)
            print(f'[+] Patched {disk_cache}')

    # 3. c11/time.h: guard struct timespec against Darwin redefinition
    time_h = os.path.join(mesa_dir, 'src', 'c11', 'time.h')
    if os.path.exists(time_h):
        with open(time_h, 'r', encoding='utf-8', errors='ignore') as f:
            txt = f.read()
        if '#ifndef HAVE_STRUCT_TIMESPEC' in txt:
            txt = txt.replace('#ifndef HAVE_STRUCT_TIMESPEC', '#if !defined(__APPLE__) && !defined(HAVE_STRUCT_TIMESPEC)')
            with open(time_h, 'w', encoding='utf-8') as f:
                f.write(txt)
            print(f'[+] Patched {time_h} (HAVE_STRUCT_TIMESPEC guard)')
        elif 'struct timespec {' in txt and '#if !defined(__APPLE__)' not in txt:
            txt = txt.replace('struct timespec {', '#if !defined(__APPLE__) && !defined(HAVE_STRUCT_TIMESPEC)\nstruct timespec {')
            idx = txt.find('struct timespec {')
            end_brace = txt.find('};', idx)
            if end_brace != -1:
                txt = txt[:end_brace+2] + '\n#endif\n' + txt[end_brace+2:]
            with open(time_h, 'w', encoding='utf-8') as f:
                f.write(txt)
            print(f'[+] Patched {time_h} (wrapped struct timespec)')

    print('[*] Patch application finished.')

if __name__ == '__main__':
    main()
