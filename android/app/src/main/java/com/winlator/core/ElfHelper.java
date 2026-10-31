package com.winlator.core;

import java.io.File;
import java.io.FileInputStream;
import java.io.IOException;
import java.io.InputStream;
import java.io.RandomAccessFile;
import java.nio.charset.StandardCharsets;

public abstract class ElfHelper {
    private static final byte ELF_CLASS_32 = 1;
    private static final byte ELF_CLASS_64 = 2;
    private static final byte ELF_DATA_LSB = 1;
    private static final int PT_INTERP = 3;
    /** PT_INTERP 的字符串理论上很短，超过这个长度的读取结果一律视为异常 */
    private static final int MAX_INTERP_SIZE = 4096;

    private static int getEIClass(File binFile) {
        try (InputStream inStream = new FileInputStream(binFile)) {
            byte[] header = new byte[52];
            inStream.read(header);
            if (header[0] == 0x7F && header[1] == 'E' && header[2] == 'L' && header[3] == 'F') {
                return header[4];
            }
        }
        catch (IOException e) {}
        return 0;
    }

    public static boolean is32Bit(File binFile) {
        return getEIClass(binFile) == ELF_CLASS_32;
    }

    public static boolean is64Bit(File binFile) {
        return getEIClass(binFile) == ELF_CLASS_64;
    }

    /** 程序头表里 PT_INTERP 段的定位信息（{@code valid == false} 表示没有这个段） */
    private static final class InterpSegment {
        long fileOffset = -1;
        long fileSize = 0;
        boolean valid = false;
    }

    private static int toUnsignedShort(byte[] data, int offset) {
        return (data[offset] & 0xFF) | ((data[offset + 1] & 0xFF) << 8);
    }

    private static long toUnsignedInt(byte[] data, int offset) {
        return (data[offset] & 0xFFL) |
               ((data[offset + 1] & 0xFFL) << 8) |
               ((data[offset + 2] & 0xFFL) << 16) |
               ((data[offset + 3] & 0xFFL) << 24);
    }

    private static long toLong(byte[] data, int offset) {
        return (data[offset] & 0xFFL) |
               ((data[offset + 1] & 0xFFL) << 8) |
               ((data[offset + 2] & 0xFFL) << 16) |
               ((data[offset + 3] & 0xFFL) << 24) |
               ((data[offset + 4] & 0xFFL) << 32) |
               ((data[offset + 5] & 0xFFL) << 40) |
               ((data[offset + 6] & 0xFFL) << 48) |
               ((data[offset + 7] & 0xFFL) << 56);
    }

    /**
     * 找到 PT_INTERP 段。只支持 Android 上实际会遇到的 64 位小端 ELF（arm64），
     * 其它情况返回 {@code valid = false}。
     */
    private static InterpSegment findInterpSegment(RandomAccessFile file) {
        InterpSegment result = new InterpSegment();
        try {
            byte[] ident = new byte[16];
            file.seek(0);
            if (file.read(ident) != ident.length) return result;
            if (ident[0] != 0x7F || ident[1] != 'E' || ident[2] != 'L' || ident[3] != 'F') return result;
            if (ident[4] != ELF_CLASS_64 || ident[5] != ELF_DATA_LSB) return result;

            byte[] header = new byte[64];
            file.seek(0);
            file.readFully(header);

            long programHeaderOffset = toLong(header, 0x20);
            int programHeaderEntrySize = toUnsignedShort(header, 0x36);
            int programHeaderCount = toUnsignedShort(header, 0x38);
            if (programHeaderOffset <= 0 || programHeaderEntrySize < 56 || programHeaderCount <= 0) return result;

            byte[] entry = new byte[programHeaderEntrySize];
            for (int i = 0; i < programHeaderCount; i++) {
                file.seek(programHeaderOffset + (long)i * programHeaderEntrySize);
                file.readFully(entry);
                if (toUnsignedInt(entry, 0) != PT_INTERP) continue;

                result.fileOffset = toLong(entry, 8);
                result.fileSize = toLong(entry, 32);
                result.valid = result.fileOffset > 0 && result.fileSize > 0 && result.fileSize <= MAX_INTERP_SIZE;
                return result;
            }
        }
        catch (IOException e) {}
        return result;
    }

    /**
     * 读取 ELF 的 PT_INTERP（内核 exec 该可执行文件时使用的动态加载器路径）。
     *
     * @return 解释器路径；不是 64 位小端 ELF、或没有 PT_INTERP（例如普通动态库）时返回 {@code null}
     */
    public static String getInterpreter(File binFile) {
        try (RandomAccessFile file = new RandomAccessFile(binFile, "r")) {
            InterpSegment segment = findInterpSegment(file);
            if (!segment.valid) return null;

            byte[] buffer = new byte[(int)segment.fileSize];
            file.seek(segment.fileOffset);
            file.readFully(buffer);

            int length = 0;
            while (length < buffer.length && buffer[length] != 0) length++;
            return new String(buffer, 0, length, StandardCharsets.UTF_8);
        }
        catch (IOException e) {
            return null;
        }
    }

    /** 返回 PT_INTERP 段能容纳的最大字节数（含结尾的 NUL）；无法解析时返回 0 */
    public static int getInterpreterCapacity(File binFile) {
        try (RandomAccessFile file = new RandomAccessFile(binFile, "r")) {
            InterpSegment segment = findInterpSegment(file);
            return segment.valid ? (int)segment.fileSize : 0;
        }
        catch (IOException e) {
            return 0;
        }
    }

    /**
     * 原地改写 PT_INTERP。<b>不改变任何程序头/段的大小</b>，只把 .interp 段里的字符串换成新路径并用 NUL 补齐，
     * 因此不会移动文件里其余内容的偏移。
     *
     * @return 写入成功返回 {@code true}；新路径比原段长（放不下）、不是目标格式、或没有写权限时返回 {@code false}
     */
    public static boolean setInterpreter(File binFile, String interpreter) {
        byte[] pathBytes = interpreter.getBytes(StandardCharsets.UTF_8);
        if (pathBytes.length == 0) return false;

        try (RandomAccessFile file = new RandomAccessFile(binFile, "rw")) {
            InterpSegment segment = findInterpSegment(file);
            if (!segment.valid) return false;
            if (pathBytes.length + 1 > segment.fileSize) return false;

            byte[] buffer = new byte[(int)segment.fileSize];
            System.arraycopy(pathBytes, 0, buffer, 0, pathBytes.length);
            file.seek(segment.fileOffset);
            file.write(buffer);
            return true;
        }
        catch (IOException e) {
            return false;
        }
    }
}
