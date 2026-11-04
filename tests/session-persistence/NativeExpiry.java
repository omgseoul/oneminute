import java.time.Instant;

// Same expiry parser used by installed NativeStaffChatApi / push / receipt code.
class NativeExpiry {
    public static void main(String[] args) {
        long expiry = Instant.parse("9999-12-31T23:59:59Z").toEpochMilli();
        if (expiry <= System.currentTimeMillis()) throw new AssertionError("expired");
        System.out.println("PASS: existing Android Instant.parse/toEpochMilli accepts persistent-session wire expiry");
    }
}
