package com.ryanheise.just_audio;

import java.nio.ByteBuffer;
import java.nio.ByteOrder;

/**
 * Checks PcmConvert bit for bit (0.3.0 bit-perfect): every 24-bit and 16-bit sample as Android's
 * FLAC decoder hands it over (float_from_i32(s << (32 - bits)), AOSP FLACDecoder.cpp copyToFloat,
 * audio_utils primitives.h) must come back unchanged as 24-bit packed, 32-bit and 16-bit integer.
 * Run: tools/dev/pcmconvert-check/run.sh
 */
public final class PcmConvertCheck {
    static int errors;

    public static void main(String[] args) {
        check(24, 24);
        check(24, 32);
        check(16, 16);
        check(16, 24);
        check(16, 32);
        // A buffer that does not start at 0 and ends with a partial sample.
        ByteBuffer in = ByteBuffer.allocate(4 * 3 + 2).order(ByteOrder.nativeOrder());
        in.putFloat(0f).putFloat(0.5f).putFloat(-1f).put((byte) 1).put((byte) 2).flip();
        in.position(4);
        ByteBuffer out = ByteBuffer.allocate(16);
        PcmConvert.floatToInt(in, out, 32);
        if (in.position() != 4 || out.remaining() != 8 || out.getInt(0) != 0x40000000 || out.getInt(4) != 0x80000000) {
            System.out.println("FEHLER Teilpuffer"); errors++;
        }
        // Full scale +1.0 is clamped.
        in = ByteBuffer.allocate(4).order(ByteOrder.nativeOrder()); in.putFloat(1f).flip();
        PcmConvert.floatToInt(in, out, 24);
        int s = (out.get(0) & 0xff) | (out.get(1) & 0xff) << 8 | out.get(2) << 16;
        if (s != 8388607) { System.out.println("FEHLER +1.0 bei 24 bit: " + s); errors++; }
        System.out.println(errors == 0 ? "PCMCONVERT OK" : "PCMCONVERT FEHLER " + errors);
        System.exit(errors == 0 ? 0 : 1);
    }

    /** All samples of a source depth through the conversion to one output depth. */
    static void check(int srcBits, int outBits) {
        int n = 1 << srcBits, min = -(n >> 1);
        int chunk = 1 << 16;
        ByteBuffer in = ByteBuffer.allocateDirect(chunk * 4).order(ByteOrder.nativeOrder());
        ByteBuffer out = ByteBuffer.allocateDirect(chunk * 4);
        float scale = 1f / (float) (1L << 31);
        long checked = 0;
        for (int base = 0; base < n; base += chunk) {
            in.clear();
            int count = Math.min(chunk, n - base);
            for (int i = 0; i < count; i++) in.putFloat(((min + base + i) << (32 - srcBits)) * scale);
            in.flip();
            PcmConvert.floatToInt(in, out, outBits);
            for (int i = 0; i < count; i++) {
                int v = min + base + i, got;
                if (outBits == 16) got = out.getShort(i * 2);
                else if (outBits == 24) got = (out.get(i * 3) & 0xff) | (out.get(i * 3 + 1) & 0xff) << 8 | out.get(i * 3 + 2) << 16;
                else got = out.getInt(i * 4);
                int want = v << (outBits - srcBits);
                if (got != want) {
                    if (errors++ < 5) System.out.println("FEHLER " + srcBits + "→" + outBits + ": " + v + " ergab " + got);
                }
                checked++;
            }
        }
        System.out.println(srcBits + " bit → " + outBits + " bit: " + checked + " Werte geprüft");
    }
}
