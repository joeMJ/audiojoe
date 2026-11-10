package com.ryanheise.just_audio;

import java.nio.ByteBuffer;
import java.nio.ByteOrder;

/**
 * audiojoe: float PCM to integer PCM for the bit-perfect USB output (see AUDIOJOE.md).
 *
 * <p>Android's decoders hand 16- and 24-bit sources over as float s / 2^(bits-1), which a float
 * holds exactly (24-bit significand). Scaling back by 2^15, 2^23 or 2^31 therefore gives the
 * original samples bit for bit; 32-bit integer output carries a 24-bit sample in its upper 24 bits.
 * No Android classes here, so tools/dev/pcmconvert-check can test it with a plain JDK.
 */
final class PcmConvert {
    private PcmConvert() {}

    /** Bytes per sample of an integer encoding: 2 (16 bit), 3 (24 bit packed) or 4 (32 bit). */
    static int bytesPerSample(int bits) {
        return bits / 8;
    }

    /**
     * Converts the float samples from {@code in} (position to limit, in its byte order) into
     * little-endian integer samples of {@code bits} (16, 24 or 32) in {@code out} (cleared and
     * flipped here). {@code in}'s position is not moved.
     */
    static void floatToInt(ByteBuffer in, ByteBuffer out, int bits) {
        out.clear();
        out.order(ByteOrder.LITTLE_ENDIAN);
        int start = in.position(), end = in.limit() - (in.limit() - start) % 4;
        ByteBuffer src = in.duplicate().order(in.order());
        for (int p = start; p < end; p += 4) {
            float v = src.getFloat(p);
            switch (bits) {
                case 16:
                    out.putShort((short) clamp(Math.round(v * 32768.0), 32767));
                    break;
                case 24: {
                    int s = (int) clamp(Math.round(v * 8388608.0), 8388607);
                    out.put((byte) s).put((byte) (s >> 8)).put((byte) (s >> 16));
                    break;
                }
                default:
                    out.putInt((int) clamp(Math.round(v * 2147483648.0), 2147483647L));
            }
        }
        out.flip();
    }

    private static long clamp(long v, long max) {
        return v > max ? max : Math.max(v, -max - 1);
    }
}
