package com.ryanheise.just_audio;

import android.content.Context;
import android.media.AudioDeviceCallback;
import android.media.AudioDeviceInfo;
import android.media.AudioFormat;
import android.media.AudioManager;
import android.media.AudioMixerAttributes;
import android.media.AudioTrack;
import android.os.Build;
import android.os.Handler;
import android.os.Looper;
import androidx.annotation.Nullable;
import androidx.annotation.OptIn;
import androidx.media3.common.C;
import androidx.media3.common.Format;
import androidx.media3.common.util.UnstableApi;
import androidx.media3.common.util.Util;
import androidx.media3.exoplayer.audio.AudioOutput;
import androidx.media3.exoplayer.audio.AudioOutputProvider;
import androidx.media3.exoplayer.audio.AudioSink;
import androidx.media3.exoplayer.audio.AudioTrackAudioOutput;
import androidx.media3.exoplayer.audio.AudioTrackAudioOutputProvider;
import androidx.media3.exoplayer.audio.DefaultAudioSink;
import androidx.media3.exoplayer.audio.ForwardingAudioOutput;
import io.flutter.plugin.common.BinaryMessenger;
import io.flutter.plugin.common.MethodCall;
import io.flutter.plugin.common.MethodChannel;
import java.nio.ByteBuffer;
import java.nio.ByteOrder;
import java.util.ArrayList;
import java.util.HashMap;
import java.util.HashSet;
import java.util.List;
import java.util.Map;
import java.util.Set;
import java.util.concurrent.CopyOnWriteArrayList;

/**
 * audiojoe: bit-perfect playback over USB (Android 14+, user 2026-11-10 „164 A“) and the facts for
 * Settings → Quality. See AUDIOJOE.md.
 *
 * <p>Media3 hands PCM to the output only as 16 bit or float (DefaultAudioSink). A USB mixer with
 * behaviour BIT_PERFECT only takes a track whose encoding, channel mask and rate match its
 * AudioMixerAttributes exactly, and USB offers integer encodings. So for music this provider asks
 * Android for the bit-perfect mixer of the USB device at the title's rate, opens the AudioTrack with
 * that integer encoding and converts Media3's float exactly ({@link PcmConvert}). In every other
 * case it is Media3's own provider unchanged.
 */
@OptIn(markerClass = UnstableApi.class)
final class BitPerfect implements AudioOutputProvider {
    /** Set by the app (Settings → Quality and, per title, "music"). */
    static volatile boolean enabled, music, lower = true;
    /** Bit depth of the source (0 = unknown); 16-bit integer output only for sources up to 16 bit. */
    static volatile int sourceBits;
    /** Media volume before bit-perfect playback after connecting a USB device (user: 20 %). */
    static final float LOWER_TO = 0.2f;

    private static final String CHANNEL = "com.ryanheise.just_audio.audiojoe";
    private static final android.media.AudioAttributes MEDIA =
        new android.media.AudioAttributes.Builder().setUsage(android.media.AudioAttributes.USAGE_MEDIA).build();

    private static Context app;
    private static AudioManager am;
    @Nullable private static MethodChannel channel;
    private static final Handler main = new Handler(Looper.getMainLooper());
    private static final List<BitPerfect> providers = new CopyOnWriteArrayList<>();
    /** USB devices (id per connection) whose volume was already lowered. */
    private static final Set<Integer> lowered = new HashSet<>();

    // Facts of the last configuration, for the Quality page.
    private static volatile Map<String, Object> lastIn, lastOut;
    private static volatile boolean active;
    @Nullable private static volatile AudioDeviceInfo preferredFor;
    @Nullable private static volatile AudioOutput lastOutput;

    private final AudioTrackAudioOutputProvider delegate;
    /** Integer encoding of the bit-perfect output configured last, 0 if none. */
    private volatile int target;
    private final List<Listener> listeners = new CopyOnWriteArrayList<>();

    private BitPerfect(Context context) {
        delegate = new AudioTrackAudioOutputProvider.Builder(context).build();
    }

    /** Called by the plugin for each engine; the device callback is registered once. */
    static void init(Context context, BinaryMessenger messenger) {
        channel = new MethodChannel(messenger, CHANNEL);
        channel.setMethodCallHandler(BitPerfect::onCall);
        if (app != null) return;
        app = context.getApplicationContext();
        am = (AudioManager) app.getSystemService(Context.AUDIO_SERVICE);
        am.registerAudioDeviceCallback(new AudioDeviceCallback() {
            @Override
            public void onAudioDevicesAdded(AudioDeviceInfo[] added) {
                changed();
            }

            @Override
            public void onAudioDevicesRemoved(AudioDeviceInfo[] removed) {
                for (AudioDeviceInfo d : removed) lowered.remove(d.getId());
                AudioDeviceInfo p = preferredFor;
                if (p != null) for (AudioDeviceInfo d : removed) if (d.getId() == p.getId()) preferredFor = null;
                changed();
            }
        }, main);
    }

    /** The audio sink of the player: float output, speed on the AudioTrack, this provider. */
    static AudioSink sink(Context context) {
        BitPerfect p = new BitPerfect(context);
        providers.add(p);
        return new DefaultAudioSink.Builder(context)
            .setEnableFloatOutput(true)
            .setEnableAudioOutputPlaybackParameters(true)
            .setAudioOutputProvider(p)
            .build();
    }

    private static void onCall(MethodCall call, MethodChannel.Result result) {
        switch (call.method) {
            case "set": {
                Boolean e = call.argument("enabled"), m = call.argument("music"), l = call.argument("lower");
                Integer b = call.argument("bits");
                boolean before = enabled && music;
                enabled = e != null && e;
                music = m != null && m;
                lower = l == null || l;
                sourceBits = b == null ? 0 : b;
                if (!(enabled && music)) clear();
                if (before != (enabled && music)) changed();
                result.success(null);
                break;
            }
            case "diagnostics":
                result.success(diagnostics());
                break;
            default:
                result.notImplemented();
        }
    }

    /** An error for the app's error log (only errors, user 2026-11-10 „184“). */
    static void log(String line) {
        main.post(() -> {
            if (channel != null) channel.invokeMethod("log", line);
        });
    }

    /** Media3 asks again for the output (e.g. after a switch or a USB device comes or goes). */
    private static void changed() {
        for (BitPerfect p : providers) {
            for (Listener l : p.listeners) {
                try {
                    l.onFormatSupportChanged();
                } catch (RuntimeException e) {
                    log("format support listener failed: " + e);
                }
            }
        }
    }

    @Override
    public FormatSupport getFormatSupport(FormatConfig formatConfig) {
        return delegate.getFormatSupport(formatConfig);
    }

    @Override
    public OutputConfig getOutputConfig(FormatConfig fc) throws ConfigurationException {
        lastIn = describe(fc.format.pcmEncoding, fc.format.sampleRate, fc.format.channelCount);
        Choice c;
        try {
            c = choose(fc);
        } catch (RuntimeException e) {
            log("choose failed: " + e);
            c = null;
        }
        OutputConfig out;
        if (c == null) {
            clear();
            target = 0;
            out = delegate.getOutputConfig(fc);
        } else {
            Format f = fc.format.buildUpon().setPcmEncoding(c.encoding).build();
            FormatConfig intFc = new FormatConfig.Builder(f)
                .setAudioAttributes(fc.audioAttributes)
                .setPreferredDevice(c.device)
                .setEnableHighResolutionPcmOutput(fc.enableHighResolutionPcmOutput)
                .setEnablePlaybackParameters(fc.enablePlaybackParameters)
                .setEnableOffload(false)
                .setAudioSessionId(fc.audioSessionId)
                .setVirtualDeviceId(fc.virtualDeviceId)
                .setEnableTunneling(false)
                .setPreferredBufferSize(fc.preferredBufferSize == C.LENGTH_UNSET
                    ? C.LENGTH_UNSET
                    : fc.preferredBufferSize / 4 * PcmConvert.bytesPerSample(bits(c.encoding)))
                .build();
            target = c.encoding;
            OutputConfig intOut = delegate.getOutputConfig(intFc);
            lastOut = describe(intOut.encoding, intOut.sampleRate, Integer.bitCount(intOut.channelMask));
            // DefaultAudioSink keeps working on float (its 20 ms fade-in after start and seek,
            // PcmAudioUtil.rampUpVolume, reads the buffer in the encoding of this config); the
            // AudioTrack gets the integer encoding in getAudioOutput.
            out = intOut.buildUpon()
                .setEncoding(C.ENCODING_PCM_FLOAT)
                .setBufferSize(intOut.bufferSize / PcmConvert.bytesPerSample(bits(c.encoding)) * 4)
                .build();
        }
        active = target != 0;
        if (target == 0) lastOut = describe(out.encoding, out.sampleRate, Integer.bitCount(out.channelMask));
        return out;
    }

    @Override
    public AudioOutput getAudioOutput(OutputConfig config) throws InitializationException {
        int t = target;
        if (t == 0 || config.encoding != C.ENCODING_PCM_FLOAT) {
            AudioTrackAudioOutput track = delegate.getAudioOutput(config);
            lastOutput = track;
            return track;
        }
        int bps = PcmConvert.bytesPerSample(bits(t));
        AudioTrackAudioOutput track = delegate.getAudioOutput(
            config.buildUpon().setEncoding(t).setBufferSize(config.bufferSize / 4 * bps).build());
        AudioDeviceInfo dev = preferredFor;
        if (dev != null) track.setPreferredDevice(dev);
        AudioOutput out = new Converting(track, bits(t), dev);
        lastOutput = out;
        return out;
    }

    @Override
    public void addListener(Listener listener) {
        listeners.add(listener);
        delegate.addListener(listener);
    }

    @Override
    public void removeListener(Listener listener) {
        listeners.remove(listener);
        delegate.removeListener(listener);
    }

    @Override
    public void setClock(androidx.media3.common.util.Clock clock) {
        delegate.setClock(clock);
    }

    @Override
    public boolean hasPendingReleases() {
        return delegate.hasPendingReleases();
    }

    @Override
    public void release() {
        providers.remove(this);
        delegate.release();
    }

    private static final class Choice {
        final int encoding;
        @Nullable final AudioDeviceInfo device;

        Choice(int encoding, @Nullable AudioDeviceInfo device) {
            this.encoding = encoding;
            this.device = device;
        }
    }

    private static int bits(int encoding) {
        return encoding == C.ENCODING_PCM_16BIT ? 16 : encoding == C.ENCODING_PCM_24BIT ? 24 : 32;
    }

    @Nullable
    private static AudioDeviceInfo usbDevice() {
        if (am == null) return null;
        for (AudioDeviceInfo d : am.getDevices(AudioManager.GET_DEVICES_OUTPUTS)) {
            int t = d.getType();
            if (t == AudioDeviceInfo.TYPE_USB_DEVICE || t == AudioDeviceInfo.TYPE_USB_HEADSET) return d;
        }
        return null;
    }

    /** Integer encodings in order of preference for this source. */
    private static int[] candidates() {
        int b = sourceBits;
        return b > 0 && b <= 16
            ? new int[] {C.ENCODING_PCM_32BIT, C.ENCODING_PCM_24BIT, C.ENCODING_PCM_16BIT}
            : new int[] {C.ENCODING_PCM_32BIT, C.ENCODING_PCM_24BIT};
    }

    /**
     * Test of the integer output without a USB DAC (emulator): {@code adb shell setprop
     * debug.audiojoe.int_output 32} (or 24, 16) makes music play through {@link Converting} on the
     * normal mixer; the switch is usable then. Empty: off.
     */
    static int testBits() {
        try {
            String v = (String) Class.forName("android.os.SystemProperties")
                .getMethod("get", String.class).invoke(null, "debug.audiojoe.int_output");
            return "32".equals(v) ? 32 : "24".equals(v) ? 24 : "16".equals(v) ? 16 : 0;
        } catch (Exception e) {
            return 0;
        }
    }

    @Nullable
    private static Choice choose(FormatConfig fc) {
        Format f = fc.format;
        if (!enabled || !music) return null;
        if (f.pcmEncoding != C.ENCODING_PCM_FLOAT || f.sampleRate <= 0) return null;
        int test = testBits();
        if (test != 0) {
            return new Choice(test == 16 ? C.ENCODING_PCM_16BIT : test == 24 ? C.ENCODING_PCM_24BIT : C.ENCODING_PCM_32BIT, null);
        }
        if (Build.VERSION.SDK_INT < 34) return null;
        AudioDeviceInfo dev = usbDevice();
        if (dev == null) return null;
        int mask = Util.getAudioTrackChannelConfig(f.channelCount);
        List<AudioMixerAttributes> offered = am.getSupportedMixerAttributes(dev);
        for (int enc : candidates()) {
            for (AudioMixerAttributes m : offered) {
                AudioFormat af = m.getFormat();
                if (m.getMixerBehavior() == AudioMixerAttributes.MIXER_BEHAVIOR_BIT_PERFECT
                    && af.getEncoding() == enc && af.getSampleRate() == f.sampleRate && af.getChannelMask() == mask) {
                    lowerOnce(dev);
                    if (!am.setPreferredMixerAttributes(MEDIA, dev, m)) {
                        log("Android refused the bit-perfect mixer of " + dev.getProductName() + " (" + bits(enc)
                            + " bit, " + f.sampleRate + " Hz); the title plays through the normal mixer");
                        return null;
                    }
                    preferredFor = dev;
                    return new Choice(enc, dev);
                }
            }
        }
        return null;
    }

    /** Lowers the media volume once per connection of the USB device (user „167“). */
    private static void lowerOnce(AudioDeviceInfo dev) {
        if (!lower || !lowered.add(dev.getId())) return;
        int max = am.getStreamMaxVolume(AudioManager.STREAM_MUSIC);
        int to = Math.max(1, Math.round(max * LOWER_TO));
        if (am.getStreamVolume(AudioManager.STREAM_MUSIC) <= to) return;
        am.setStreamVolume(AudioManager.STREAM_MUSIC, to, 0);
        main.post(() -> {
            if (channel != null) channel.invokeMethod("lowered", Math.round(LOWER_TO * 100));
        });
    }

    private static void clear() {
        AudioDeviceInfo dev = preferredFor;
        preferredFor = null;
        if (dev != null && Build.VERSION.SDK_INT >= 34) {
            try {
                am.clearPreferredMixerAttributes(MEDIA, dev);
            } catch (RuntimeException ignored) {
            }
        }
    }

    private static Map<String, Object> describe(int encoding, int rate, int channels) {
        Map<String, Object> m = new HashMap<>();
        m.put("encoding", encodingName(encoding));
        m.put("rate", rate);
        m.put("channels", channels);
        return m;
    }

    private static String encodingName(int encoding) {
        switch (encoding) {
            case C.ENCODING_PCM_16BIT: return "16";
            case C.ENCODING_PCM_24BIT: return "24";
            case C.ENCODING_PCM_32BIT: return "32";
            case C.ENCODING_PCM_FLOAT: return "float";
            default: return "other";
        }
    }

    private static Map<String, Object> diagnostics() {
        Map<String, Object> d = new HashMap<>();
        d.put("android", Build.VERSION.RELEASE);
        d.put("sdk", Build.VERSION.SDK_INT);
        d.put("model", Build.MANUFACTURER + " " + Build.MODEL);
        d.put("test", testBits());
        AudioDeviceInfo usb = usbDevice();
        d.put("usb", usb == null ? null : String.valueOf(usb.getProductName()));
        List<Map<String, Object>> offered = new ArrayList<>();
        if (usb != null && Build.VERSION.SDK_INT >= 34) {
            for (AudioMixerAttributes m : am.getSupportedMixerAttributes(usb)) {
                AudioFormat af = m.getFormat();
                Map<String, Object> o = describe(af.getEncoding(), af.getSampleRate(), af.getChannelCount());
                o.put("bitPerfect", m.getMixerBehavior() == AudioMixerAttributes.MIXER_BEHAVIOR_BIT_PERFECT);
                offered.add(o);
            }
        }
        d.put("offered", offered);
        d.put("in", lastIn);
        d.put("out", lastOut);
        d.put("bitPerfect", active && preferredFor != null);
        AudioOutput o = lastOutput;
        AudioTrack t = o instanceof Converting ? ((Converting) o).track.getAudioTrack()
            : o instanceof AudioTrackAudioOutput ? ((AudioTrackAudioOutput) o).getAudioTrack() : null;
        AudioDeviceInfo routed = null;
        try {
            if (t != null && t.getState() == AudioTrack.STATE_INITIALIZED) routed = t.getRoutedDevice();
        } catch (RuntimeException ignored) {
        }
        if (routed != null) {
            Map<String, Object> r = new HashMap<>();
            r.put("name", String.valueOf(routed.getProductName()));
            r.put("type", routed.getType());
            d.put("routed", r);
        }
        return d;
    }

    /** Writes Media3's float buffers as integers of the bit-perfect mixer's encoding. */
    private static final class Converting extends ForwardingAudioOutput {
        final AudioTrackAudioOutput track;
        private final int bits;
        private ByteBuffer buffer = ByteBuffer.allocateDirect(0);

        Converting(AudioTrackAudioOutput track, int bits, @Nullable AudioDeviceInfo device) {
            super(track);
            this.track = track;
            this.bits = bits;
        }

        @Override
        public boolean write(ByteBuffer in, int encodedAccessUnitCount, long presentationTimeUs) throws WriteException {
            int start = in.position();
            int samples = in.remaining() / 4, size = samples * PcmConvert.bytesPerSample(bits);
            if (buffer.capacity() < size) buffer = ByteBuffer.allocateDirect(size).order(ByteOrder.LITTLE_ENDIAN);
            PcmConvert.floatToInt(in, buffer, bits);
            boolean done = super.write(buffer, encodedAccessUnitCount, presentationTimeUs);
            int written = buffer.position() / PcmConvert.bytesPerSample(bits);
            in.position(done ? in.limit() : start + written * 4);
            return done;
        }

        @Override
        public void setPreferredDevice(@Nullable AudioDeviceInfo preferredDevice) {
            // The bit-perfect mixer belongs to the USB device; Media3's own preference (none) does not change it.
            if (preferredDevice != null) super.setPreferredDevice(preferredDevice);
        }
    }
}
