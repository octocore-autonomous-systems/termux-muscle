/* SPDX-License-Identifier: MPL-2.0 */
/* Stand-in for `patchelf --set-interpreter PATH FILE` in offline tests.
 * The archive fixtures are 768-byte synthetic ELF files that real patchelf
 * cannot rewrite. Like patchelf, this appends the new loader path and points
 * the PT_INTERP program header at it; nothing else in the file changes.
 * Real patchelf runs against the real executable in device acceptance. */
#define _GNU_SOURCE 1
#include <elf.h>
#include <stdio.h>
#include <string.h>

int main(int argc, char **argv) {
    if (argc != 4 || strcmp(argv[1], "--set-interpreter"))
        return 64;
    FILE *file = fopen(argv[3], "r+b");
    Elf64_Ehdr header;
    if (!file || fread(&header, sizeof header, 1, file) != 1 ||
        memcmp(header.e_ident, ELFMAG, SELFMAG))
        return 65;
    if (fseek(file, 0, SEEK_END))
        return 66;
    long end = ftell(file);
    size_t length = strlen(argv[2]) + 1;
    if (end < 0 || fwrite(argv[2], length, 1, file) != 1)
        return 66;
    for (unsigned int i = 0; i < header.e_phnum; i++) {
        long position = (long)(header.e_phoff + i * sizeof(Elf64_Phdr));
        Elf64_Phdr program;
        if (fseek(file, position, SEEK_SET) || fread(&program, sizeof program, 1, file) != 1)
            return 67;
        if (program.p_type != PT_INTERP)
            continue;
        program.p_offset = (Elf64_Off)end;
        program.p_filesz = program.p_memsz = length;
        if (fseek(file, position, SEEK_SET) || fwrite(&program, sizeof program, 1, file) != 1)
            return 67;
        return fclose(file) ? 68 : 0;
    }
    return 69;
}
