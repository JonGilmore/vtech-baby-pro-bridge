/* VTech Baby Pro native bridge (Android arm64).
 *
 * Uses the official VTech app's TUTK SDK 4.x via dlopen + libsodium for
 * the camera-side X25519 + ChaCha20-Poly1305 handshake.
 *
 */
#define _GNU_SOURCE
#include <dlfcn.h>
#include <link.h>
#include <pthread.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include <unistd.h>

/* ---- TUTK SDK license key ----
 *
 * The TUTK SDK requires a vendor-issued license key. We load it at
 * runtime from a file path supplied via VTECH_LICENSE_KEY_FILE (env)
 * or as the binary's first positional argument before UID/password.
 *
 * Extract your camera's key from the VTech APK with the helper at
 * decode_license_key.py - see README.md. We do not ship the key in
 * source. */
/* Parse the license-key file. Accepts either:
 *   - a raw single-line key, OR
 *   - a dotenv-style annotated file with `# comments`, blank lines, and
 *     a `LICENSE_KEY=VALUE` (or `KEY=VALUE`) entry, optionally quoted.
 * Returns malloc'd key string; caller frees. NULL on any error. */
static char *load_license_key(const char *path) {
  FILE *fp = fopen(path, "r");
  if (!fp)
    return NULL;
  char line[4096];
  char *result = NULL;
  while (fgets(line, sizeof(line), fp)) {
    /* Skip leading whitespace, comment lines, blank lines */
    char *p = line;
    while (*p == ' ' || *p == '\t')
      p++;
    if (*p == '#' || *p == '\n' || *p == '\r' || *p == '\0')
      continue;

    /* Strip trailing whitespace */
    size_t n = strlen(p);
    while (n > 0 && (p[n - 1] == '\n' || p[n - 1] == '\r' || p[n - 1] == ' ' ||
                     p[n - 1] == '\t')) {
      p[--n] = '\0';
    }
    if (n == 0)
      continue;

    /* If the line is `KEY=VALUE` form, take the value part. */
    char *eq = strchr(p, '=');
    char *value = eq ? eq + 1 : p;

    /* Strip surrounding double or single quotes. */
    size_t vlen = strlen(value);
    if (vlen >= 2 && (value[0] == '"' || value[0] == '\'') &&
        value[vlen - 1] == value[0]) {
      value[vlen - 1] = '\0';
      value++;
    }

    result = strdup(value);
    break;
  }
  fclose(fp);
  return result;
}

/* ---- Resolved SDK function pointers ---- */
typedef int (*set_license_fn)(const char *);
typedef int (*iotc_init_fn)(uint32_t);
typedef int (*iotc_schl_init_fn)(void);
typedef int (*av_init_fn)(int);
typedef int (*iotc_get_sid_fn)(void);
typedef int (*iotc_connect_fn)(const char *, int);

typedef struct {
  uint32_t size;            /* 0x00, =0x38 */
  uint32_t iotc_session_id; /* 0x04 */
  uint8_t iotc_channel_id;  /* 0x08 */
  uint8_t _pad0[3];
  uint32_t timeout_sec;      /* 0x0c */
  char *account_or_identity; /* 0x10 */
  char *password_or_token;   /* 0x18 */
  uint32_t resend;           /* 0x20 */
  uint32_t security_mode;    /* 0x24 */
  uint32_t auth_type;        /* 0x28 */
  uint32_t sync_recv_data;   /* 0x2c */
  char *dtls_cipher_suites;  /* 0x30 */
} AvClientStartInArgs;

typedef struct {
  uint32_t size; /* =0x18 */
  uint32_t server_type;
  uint32_t resend;
  uint32_t two_way_streaming;
  uint32_t sync_recv_data;
  uint32_t security_mode;
} AvClientStartOutArgs;

typedef int (*av_client_start_ex_fn)(AvClientStartInArgs *,
                                     AvClientStartOutArgs *);
typedef int (*av_send_ioctl_fn)(int, uint32_t, const char *, int);
typedef int (*av_recv_ioctl_fn)(int, uint32_t *, char *, int, uint32_t);
typedef int (*av_recv_frame2_fn)(int, char *, int, void *, void *, char *, int,
                                 uint32_t *, void *);

/* ---- libsodium typedefs ----
 * Standard libsodium signatures. We dlopen libsodium.so (pulled from the apk
 * - vanilla build) so we don't depend on bionic having it. */
typedef int (*sodium_init_fn)(void);
typedef int (*crypto_kx_keypair_fn)(unsigned char *pk, unsigned char *sk);
typedef int (*crypto_scalarmult_fn)(unsigned char *q, const unsigned char *n,
                                    const unsigned char *p);
typedef int (*crypto_auth_hmacsha256_fn)(unsigned char *out,
                                         const unsigned char *in,
                                         unsigned long long inlen,
                                         const unsigned char *k);
typedef int (*crypto_stream_chacha20_ietf_xor_fn)(unsigned char *c,
                                                  const unsigned char *m,
                                                  unsigned long long mlen,
                                                  const unsigned char *n,
                                                  const unsigned char *k);
typedef int (*crypto_aead_chacha20poly1305_ietf_decrypt_fn)(
    unsigned char *m, unsigned long long *mlen_p, unsigned char *nsec,
    const unsigned char *c, unsigned long long clen, const unsigned char *ad,
    unsigned long long adlen, const unsigned char *npub,
    const unsigned char *k);

#define LOG(fmt, ...) fprintf(stderr, "[bridge] " fmt "\n", ##__VA_ARGS__)
#define DIE(fmt, ...)                                                          \
  do {                                                                         \
    fprintf(stderr, "[bridge] FATAL: " fmt "\n", ##__VA_ARGS__);               \
    exit(1);                                                                   \
  } while (0)

static void *xdlopen(const char *path) {
  void *h = dlopen(path, RTLD_NOW | RTLD_GLOBAL);
  if (!h)
    DIE("dlopen %s: %s", path, dlerror());
  LOG("dlopen ok: %s", path);
  return h;
}

static int find_lib_base_cb(struct dl_phdr_info *info, size_t sz, void *arg) {
  void **out = arg;
  const char *needle = (const char *)out[1];
  if (info->dlpi_name && strstr(info->dlpi_name, needle)) {
    out[0] = (void *)(uintptr_t)info->dlpi_addr;
    return 1;
  }
  return 0;
}

/* Returns the runtime load base of the .so whose path contains `needle`,
 * or NULL if not found. Used to compute static-offset references into
 * libAVAPIs (e.g. the _DAT_0014d1c0 session-table global). */
static uint8_t *find_lib_base(const char *needle) {
  void *out[2] = {NULL, (void *)needle};
  dl_iterate_phdr(find_lib_base_cb, out);
  return (uint8_t *)out[0];
}

static void *xdlsym(void *h, const char *sym) {
  void *p = dlsym(h, sym);
  if (!p)
    DIE("dlsym %s: %s", sym, dlerror());
  return p;
}

/* Hex-print helper for diagnostic logging (first 16 bytes). */
static void hexlog(const char *label, const uint8_t *p, int n) {
  char buf[3 * 32 + 1] = {0};
  int show = n < 16 ? n : 16;
  for (int i = 0; i < show; i++)
    snprintf(buf + i * 3, 4, "%02x ", p[i]);
  LOG("%s [%dB]: %s%s", label, n, buf, n > 16 ? "..." : "");
}

/* Crypto context - populated after the 0x820/0x821 handshake. */
typedef struct {
  crypto_stream_chacha20_ietf_xor_fn chacha20_ietf_xor;
  crypto_aead_chacha20poly1305_ietf_decrypt_fn chacha20poly1305_decrypt;
  uint8_t prk[32]; /* HMAC-SHA256(salt=cam_salt, data=shared) */
  int ready;       /* 1 once prk is computed */
} crypto_ctx_t;

/* Decrypt one frame in-place (out buffer must hold at least frame_len-60
 * bytes). Returns plaintext length on success, <0 on failure. */
static int decrypt_frame(crypto_ctx_t *cc, const uint8_t *frame, int frame_len,
                         uint8_t *out, int out_cap) {
  if (frame_len < 60)
    return -1;                 /* must hold key+nonce+tag */
  int ct_len = frame_len - 60; /* ciphertext length, sans tag */
  if (ct_len + 16 > out_cap)
    return -2; /* output buffer too small */

  const uint8_t *enc_key = frame + 0; /* [32B] XOR-encrypted ChaCha key */
  const uint8_t *nonce = frame + 32;  /* [12B] ChaCha20 nonce */
  const uint8_t *tag = frame + 44;    /* [16B] Poly1305 tag */
  const uint8_t *ct = frame + 60;     /* [N B] ciphertext */

  /* 1) Recover per-frame ChaCha20 key by XORing enc_key against a stream
   *    derived from PRK + nonce. */
  uint8_t k_frame[32];
  if (cc->chacha20_ietf_xor(k_frame, enc_key, 32, nonce, cc->prk) != 0)
    return -3;

  /* 2) libsodium's AEAD expects ciphertext||tag concatenated. The wire
   *    format separates them, so reassemble into a scratch buffer. We use
   *    `out` itself: write ct then tag at the end, then decrypt into the
   *    same buffer (libsodium's IETF decrypt allows in-place - input and
   *    output may alias as long as plaintext fits). To keep it simple we
   *    use a small heap buffer for the assembled ct||tag. */
  uint8_t *ct_with_tag = malloc(ct_len + 16);
  if (!ct_with_tag)
    return -4;
  memcpy(ct_with_tag, ct, ct_len);
  memcpy(ct_with_tag + ct_len, tag, 16);

  unsigned long long pt_len = 0;
  int rc = cc->chacha20poly1305_decrypt(out, &pt_len, NULL, ct_with_tag,
                                        ct_len + 16, NULL, 0, nonce, k_frame);
  free(ct_with_tag);
  if (rc != 0)
    return -5; /* auth failed */
  return (int)pt_len;
}

int main(int argc, char **argv) {
  if (argc < 3) {
    fprintf(stderr,
            "Usage: %s <UID> <password> [duration_seconds]\n"
            "\n"
            "Required env:\n"
            "  VTECH_LICENSE_KEY_FILE   path to LICENSE_KEY.txt\n"
            "                           (extract from your VTech APK with\n"
            "                            decode_license_key.py - see README)\n",
            argv[0]);
    return 1;
  }
  const char *uid = argv[1];
  const char *password = argv[2];
  int duration = (argc > 3) ? atoi(argv[3]) : 60; /* 0 = forever */

  const char *license_path = getenv("VTECH_LICENSE_KEY_FILE");
  if (!license_path || !*license_path) {
    fprintf(stderr,
            "[bridge] FATAL: VTECH_LICENSE_KEY_FILE env var not set.\n"
            "Extract the key from your VTech APK with decode_license_key.py\n"
            "and point the env var at the resulting file.\n");
    return 1;
  }
  char *license_key = load_license_key(license_path);
  if (!license_key) {
    fprintf(stderr, "[bridge] FATAL: could not read license key from '%s'\n",
            license_path);
    return 1;
  }

  /* Load libs in dependency order. */
  /* libdnsfix.so (optional) - bionic-resolver-redirector for chroot
   * environments. Loaded first with RTLD_GLOBAL so its connect() override
   * is visible to subsequently-loaded TUTK libs. Silently ignored if
   * absent (no-op on a real Android phone). */
  {
    void *h = dlopen("/data/local/tmp/libdnsfix.so", RTLD_NOW | RTLD_GLOBAL);
    if (h)
      LOG("dlopen ok: /data/local/tmp/libdnsfix.so (chroot DNS shim active)");
  }

  void *libGlobal = xdlopen("/data/local/tmp/libTUTKGlobalAPIs.so");
  void *libIOTC = xdlopen("/data/local/tmp/libIOTCAPIs.so");
  void *libAV = xdlopen("/data/local/tmp/libAVAPIs.so");
  void *libSodium = xdlopen("/data/local/tmp/libsodium.so");

  /* Resolve SDK symbols */
  set_license_fn set_license =
      (set_license_fn)xdlsym(libGlobal, "TUTK_SDK_Set_License_Key");
  iotc_init_fn iotc_init = (iotc_init_fn)xdlsym(libIOTC, "IOTC_Initialize2");
  iotc_schl_init_fn schl_init =
      (iotc_schl_init_fn)xdlsym(libIOTC, "IOTC_sCHL_initialize");
  av_init_fn av_init = (av_init_fn)xdlsym(libAV, "avInitialize");
  iotc_get_sid_fn get_sid =
      (iotc_get_sid_fn)xdlsym(libIOTC, "IOTC_Get_SessionID");
  iotc_connect_fn iotc_connect =
      (iotc_connect_fn)xdlsym(libIOTC, "IOTC_Connect_ByUID_Parallel");
  av_client_start_ex_fn av_start_ex =
      (av_client_start_ex_fn)xdlsym(libAV, "avClientStartEx");
  av_send_ioctl_fn send_ioctl = (av_send_ioctl_fn)xdlsym(libAV, "avSendIOCtrl");
  av_recv_ioctl_fn recv_ioctl = (av_recv_ioctl_fn)xdlsym(libAV, "avRecvIOCtrl");
  av_recv_frame2_fn recv_frame =
      (av_recv_frame2_fn)xdlsym(libAV, "avRecvFrameData2");

  /* Resolve libsodium symbols */
  sodium_init_fn sodium_init = (sodium_init_fn)xdlsym(libSodium, "sodium_init");
  crypto_kx_keypair_fn kx_keypair =
      (crypto_kx_keypair_fn)xdlsym(libSodium, "crypto_kx_keypair");
  crypto_scalarmult_fn scalarmult =
      (crypto_scalarmult_fn)xdlsym(libSodium, "crypto_scalarmult");
  crypto_auth_hmacsha256_fn hmac256 =
      (crypto_auth_hmacsha256_fn)xdlsym(libSodium, "crypto_auth_hmacsha256");
  crypto_ctx_t cc = {0};
  cc.chacha20_ietf_xor = (crypto_stream_chacha20_ietf_xor_fn)xdlsym(
      libSodium, "crypto_stream_chacha20_ietf_xor");
  cc.chacha20poly1305_decrypt =
      (crypto_aead_chacha20poly1305_ietf_decrypt_fn)xdlsym(
          libSodium, "crypto_aead_chacha20poly1305_ietf_decrypt");

  int rc;

  /* 1) License */
  rc = set_license(license_key);
  LOG("TUTK_SDK_Set_License_Key = %d", rc);
  if (rc < 0)
    DIE("license rejected");

  /* 2) sodium_init (mandatory before any libsodium primitive on some platforms)
   */
  rc = sodium_init();
  LOG("sodium_init = %d", rc);
  if (rc < 0)
    DIE("sodium_init failed");

  /* 3) Initialise IOTC + AV + DTLS */
  rc = iotc_init(0);
  LOG("IOTC_Initialize2 = %d", rc);
  if (rc < 0)
    DIE("IOTC_Initialize2 failed");

  rc = av_init(16);
  LOG("avInitialize = %d", rc);
  if (rc < 0)
    DIE("avInitialize failed");

  rc = schl_init();
  LOG("IOTC_sCHL_initialize = %d", rc);
  if (rc < 0)
    DIE("IOTC_sCHL_initialize failed");

  /* 4) Get a session slot + connect.
   *
   * Before the connect we do an `IOTC_Lan_Search` broadcast on the
   * local subnet. This is what discovers the camera over UDP without
   * needing TUTK's cloud master server to track the camera's current
   * IP. The side-effect we care about is that the SDK populates its
   * internal device cache from the broadcast replies, so the
   * subsequent `IOTC_Connect_ByUID_Parallel` call uses the LAN-direct
   * path immediately instead of waiting on (and being misled by) the
   * cloud master's stale "device not listening" response. This makes
   * the bridge work on isolated networks where the camera has no
   * internet — just LAN reachability between Pi and camera.
   *
   * stLanSearchInfo layout (from TUTK SDK 4.x headers): UID[24] +
   * IP[16] + Port:u16 + DeviceName[64] + Reserved[64] = 168 bytes per
   * entry. We allocate generously (8 entries × 256 B) to be tolerant
   * of small per-version layout drift.
   *
   * VTECH_LAN_SEARCH_MS env var lets you tune the broadcast wait
   * window; default 3s is fine for most networks. Set to 0 to skip
   * Lan_Search entirely (pre-fix behavior — useful for debugging).
   *
   * Port: TUTK changed the default LAN-search broadcast port from
   * 32761 (older SDK) to 32762 (newer SDK). This camera's firmware
   * listens on 32762 — confirmed by pcap of the official app. The
   * SDK we're loading defaults to 32761, so we explicitly set it
   * via IOTC_Set_LanSearchPort before the search. Override with
   * VTECH_LAN_SEARCH_PORT if you need a different port. */
  typedef int (*set_lan_port_fn)(unsigned short);
  set_lan_port_fn set_lan_port = (set_lan_port_fn)dlsym(libIOTC, "IOTC_Set_LanSearchPort");
  unsigned short lan_port = getenv("VTECH_LAN_SEARCH_PORT")
    ? (unsigned short)atoi(getenv("VTECH_LAN_SEARCH_PORT"))
    : 32762;
  if (set_lan_port) {
    int rc_port = set_lan_port(lan_port);
    LOG("IOTC_Set_LanSearchPort(%u) = %d", lan_port, rc_port);
  } else {
    LOG("IOTC_Set_LanSearchPort not in libIOTCAPIs.so — using SDK default port");
  }

  typedef int (*lan_search_fn)(void *, int, int);
  lan_search_fn lan_search = (lan_search_fn)dlsym(libIOTC, "IOTC_Lan_Search");
  int lan_ms = getenv("VTECH_LAN_SEARCH_MS") ? atoi(getenv("VTECH_LAN_SEARCH_MS")) : 3000;
  if (lan_search && lan_ms > 0) {
    char results[8 * 256] = {0};
    int found = lan_search(results, 8, lan_ms);
    LOG("IOTC_Lan_Search = %d device(s) on LAN (%dms scan)", found, lan_ms);
    /* Dump UID + IP of any discovered devices (UID is the first 20 ASCII
     * bytes of each 168-byte entry, IP is at offset 24). */
    for (int i = 0; i < found && i < 8; i++) {
      const char *entry = results + i * 168;
      char uid_buf[21] = {0};
      char ip_buf[17] = {0};
      memcpy(uid_buf, entry, 20);
      memcpy(ip_buf, entry + 24, 16);
      LOG("  [%d] UID=%s IP=%s", i, uid_buf, ip_buf);
    }
  } else if (!lan_search) {
    LOG("IOTC_Lan_Search not in libIOTCAPIs.so — skipping LAN scan");
  } else {
    LOG("IOTC_Lan_Search skipped (VTECH_LAN_SEARCH_MS=0)");
  }

  int sid = get_sid();
  LOG("IOTC_Get_SessionID = %d", sid);

  int session = iotc_connect(uid, sid);
  LOG("IOTC_Connect_ByUID_Parallel = %d", session);
  if (session < 0)
    DIE("connect failed");

  /* 5) avClientStartEx (plain mode - camera firmware too old for SDK DTLS).
   * Real video unlock comes from the X25519 / ChaCha20-Poly1305 handshake
   * we drive at the application layer via IOCtrl 0x820/0x821 below. */
  AvClientStartInArgs in = {0};
  AvClientStartOutArgs out = {0};
  /* Channel ID + account string are env-overridable for empirical testing
   * (some cameras gate HD by channel or account string). */
  int channel_id =
      getenv("VTECH_IOTC_CHANNEL") ? atoi(getenv("VTECH_IOTC_CHANNEL")) : 0;
  const char *account =
      getenv("VTECH_ACCOUNT") ? getenv("VTECH_ACCOUNT") : "admin";

  in.size = sizeof(in);
  in.iotc_session_id = (uint32_t)session;
  in.iotc_channel_id = (uint8_t)channel_id;
  in.timeout_sec = 60;
  in.account_or_identity = (char *)account;
  in.password_or_token = (char *)password;
  in.resend = 0;
  in.security_mode = 0; /* plain */
  in.auth_type = 0;     /* password */
  in.sync_recv_data = 0;
  in.dtls_cipher_suites = NULL;
  out.size = sizeof(out);
  int av = av_start_ex(&in, &out);
  LOG("avClientStartEx = %d  serv=%u resend=%u sec=%u 2way=%u", av,
      out.server_type, out.resend, out.security_mode, out.two_way_streaming);
  if (av < 0)
    DIE("avClientStartEx failed");

  /* --- HD-path channel-state probe (diagnostic) ---
   *
   * Logs the libAVAPIs channel-struct flags for diagnostic purposes.
   * Useful for future protocol RE; harmless in production.
   * Channel located via session table at libAVAPIs static offset
   * 0x4d1c0 → +sid*0xa0 → +0x98 (per FUN_00117aa8 in the unstripped
   * TUTK SDK build). See memory/project_vtech_hd_investigation.md. */
  {
    uint8_t *libav_base = find_lib_base("libAVAPIs");
    uint8_t *channel = NULL;
    if (libav_base) {
      uint8_t *session_table = *(uint8_t **)(libav_base + 0x4d1c0);
      if (session_table)
        channel = *(uint8_t **)(session_table + (long)av * 0xa0 + 0x98);
    }
    if (channel) {
      LOG("channel-probe: %p +0x90=%u +0xe8=0x%x +0x1f80=%u +0x1f84=%u "
          "+0x1908=%u",
          channel, *(uint8_t *)(channel + 0x90), *(uint32_t *)(channel + 0xe8),
          *(uint32_t *)(channel + 0x1f80), *(uint32_t *)(channel + 0x1f84),
          *(uint8_t *)(channel + 0x1908));
    }
  }

  /* 6) Pre-handshake IOCtrls - match the official app's order:
   *     0xff (4B zeros) - pre-init / new-session marker
   *     0x330 DEVINFO_REQ (20B) - request device info
   *     (Note: 0x1ff IPCAM_START is sent AFTER the handshake, NOT here.
   *      Sending it before auth puts the camera in low-rate snapshot
   *      mode for our session.) */
  char z4[4] = {0};
  char devinfo_req[20] = {0, 1, 0x12, 0x34};
  for (int i = 4; i < 20; i++)
    devinfo_req[i] = (char)(rand() & 0xff);

  rc = send_ioctl(av, 0xff, z4, 4);
  LOG("avSendIOCtrl(0x0ff PRE_INIT, 4B) = %d", rc);
  usleep(50 * 1000);

  rc = send_ioctl(av, 0x330, devinfo_req, 20);
  LOG("avSendIOCtrl(0x330 DEVINFO_REQ, 20B) = %d", rc);
  usleep(50 * 1000);

  /* 0x320 SETSTREAMCTRL was a red herring - the official app doesn't
   * send it and sending it during our session locks us to low-rate
   * snapshot mode. Removed. */

  /* 7) Crypto handshake.
   *
   * Generate an ephemeral X25519 keypair, send our public key in IOCtrl 0x820
   * (payload = [counter:4 LE][my_pub:32]), wait for IOCtrl 0x821 with the
   * camera's pubkey + 32B salt, then derive the per-session PRK.
   *
   *   Outbound:  IOCtrl 0x820  payload [counter:4 LE][my_pub:32]            (36
   * B) Inbound:   IOCtrl 0x821  payload [status:4][valid:4][?:4]
   *                                    [cam_pub:32][cam_salt:32] (≥76 B)
   *
   *   shared = X25519(my_priv, cam_pub)
   *   PRK    = HMAC-SHA256(key=cam_salt, data=shared)            //
   * HKDF-Extract
   *
   * Per-frame:  K_frame = ChaCha20-IETF-XOR(enc_key, nonce, key=PRK)
   *             plaintext = ChaCha20-Poly1305-IETF(ciphertext+tag, nonce,
   * K_frame)
   */
  uint8_t my_pub[32], my_priv[32];
  if (kx_keypair(my_pub, my_priv) != 0)
    DIE("crypto_kx_keypair failed");
  hexlog("my_pub", my_pub, 32);

  uint8_t hs_req[36];
  uint32_t counter = 1;
  memcpy(hs_req, &counter, 4); /* little-endian on aarch64 */
  memcpy(hs_req + 4, my_pub, 32);

  rc = send_ioctl(av, 0x820, (char *)hs_req, 36);
  LOG("avSendIOCtrl(0x820 HANDSHAKE_REQ, 36B) = %d", rc);

  /* Drain incoming IOCtrls until we see 0x821 (or timeout after ~3 seconds). */
  char ioctl_buf[1024];
  uint32_t got_type = 0;
  int got_len = 0;
  int hs_ok = 0;
  for (int attempt = 0; attempt < 60; attempt++) {
    got_type = 0;
    rc = recv_ioctl(av, &got_type, ioctl_buf, sizeof(ioctl_buf), 50 /*ms*/);
    if (rc < 0)
      continue; /* timeout/empty - keep polling */
    LOG("avRecvIOCtrl: type=0x%x len=%d", got_type, rc);
    if (got_type == 0x821) {
      got_len = rc;
      hs_ok = 1;
      break;
    }
  }
  if (!hs_ok)
    DIE("did not receive IOCtrl 0x821 within ~3s");
  if (got_len < 76)
    DIE("0x821 too short (%d bytes, need >=76)", got_len);

  /* Layout per MultiViewActivity$66.smali :sswitch_14d:
   *   v3 = 0, v8 = 4
   *   v4 = byteArrayToInt_Little(v0, 0)  -> must equal 0
   *   v5 = byteArrayToInt_Little(v0, 4)  -> must equal v10 (= 1)
   *   arraycopy(v0, 12, ..., 0, 32)      -> setCancelable = cam pubkey
   *   arraycopy(v0, 44, ..., 0, 32)      -> AlertDialog   = cam salt    */
  int32_t status = *(int32_t *)(ioctl_buf + 0);
  int32_t valid = *(int32_t *)(ioctl_buf + 4);
  int32_t word3 = *(int32_t *)(ioctl_buf + 8);
  uint8_t *cam_pub = (uint8_t *)(ioctl_buf + 12);
  uint8_t *cam_salt = (uint8_t *)(ioctl_buf + 44);
  LOG("0x821: status=%d valid=%d word3=%d", status, valid, word3);
  hexlog("cam_pub", cam_pub, 32);
  hexlog("cam_salt", cam_salt, 32);
  if (status != 0 || valid != 1)
    DIE("0x821 negative ack: status=%d valid=%d", status, valid);

  /* shared = X25519(my_priv, cam_pub) */
  uint8_t shared[32];
  if (scalarmult(shared, my_priv, cam_pub) != 0)
    DIE("crypto_scalarmult failed");
  hexlog("shared", shared, 32);

  /* PRK = HMAC-SHA256(key=cam_salt, data=shared)  - HKDF-Extract */
  if (hmac256(cc.prk, shared, 32, cam_salt) != 0)
    DIE("hmac_sha256 failed");
  hexlog("PRK", cc.prk, 32);
  cc.ready = 1;

  /* 7b) Post-handshake startup, mirroring the official app's order
   *     captured via uprobe on avSendIOCtrl. Each is best-effort: failures
   *     are logged but don't abort.
   *
   * Smali decode (2026-04-30) confirmed structures:
   *   0x7be = [u32 LE Camera-int-field][4 zeros]   (field unknown - try
   *           VTECH_AUTH_ACK_VAL env to sweep candidate values; default 1
   *           preserves prior behavior.)
   *   0x328 = 4 zero bytes (matches what we already send)
   *   0x32a = ? (currently 8 zero bytes; same as we send)
   *
   * 0x719 = [u32 LE 0][u32 LE 0] = 8 zero bytes - THIS IS THE HD TRIGGER.
   *   Identified via bisection (2026-04-30 night). Without it the camera
   *   stays in 1fps-IDR-only-360p preview mode; with it we get full
   *   1920x1080 @ 15fps live H.264. The smali defines it in
   *   `Lo/setThumb$RemoteActionCompatParcelizer;->RemoteActionCompatParcelizer(I)[B`
   *   - DexGuard-renamed from a "switch to live streaming" function.
   *   Camera doesn't ack it (no 0x71a observed) - fire-and-forget mode-set.
   *
   * Tested adjacent IOCtrls 0x713 (8B zeros) and 0x75a (4B zeros) which
   * the app also sends - bisection showed both are irrelevant to HD,
   * removed.
   */
  {
    uint32_t auth_ack_val = (uint32_t)(getenv("VTECH_AUTH_ACK_VAL")
                                           ? atoi(getenv("VTECH_AUTH_ACK_VAL"))
                                           : 1);
    char buf_7be[8] = {0};
    *(uint32_t *)buf_7be = auth_ack_val;
    rc = send_ioctl(av, 0x7be, buf_7be, 8);
    LOG("avSendIOCtrl(0x7be auth_ack[u32=%u]    8B) = %d", auth_ack_val, rc);
    usleep(30 * 1000);

    struct {
      uint32_t code;
      const char *name;
      int len;
      uint8_t b0;
    } post_hs[] = {
        {0x328, "GETSUPPORTSTREAM", 4, 0},
        {0x328, "GETSUPPORTSTREAM", 4, 0}, /* app sends twice */
        {0x32a, "GETAUDIOOUTFORMAT", 8, 0},
        {0x74b, "VTECH_unknown_74b", 4, 0},
        {0x7a4, "VTECH_unknown_7a4", 4, 0},
        {0x7b0, "VTECH_unknown_7b0", 4, 0},
        {0x733, "VTECH_unknown_733", 4, 0},
        {0x7d6, "VTECH_unknown_7d6", 4, 0},
        {0x719, "VTECH_HD_TRIGGER", 8, 0}, /* HD live stream switch */
        {0x300, "STREAM_START", 8, 0},
        {0x1ff, "IPCAM_START", 8, 0},
    };
    char buf16[16] = {0};
    for (size_t i = 0; i < sizeof(post_hs) / sizeof(post_hs[0]); i++) {
      memset(buf16, 0, sizeof(buf16));
      buf16[0] = post_hs[i].b0;
      rc = send_ioctl(av, post_hs[i].code, buf16, post_hs[i].len);
      LOG("avSendIOCtrl(0x%03x %-22s %dB) = %d", post_hs[i].code,
          post_hs[i].name, post_hs[i].len, rc);
      usleep(30 * 1000);
    }
  }

  /* 7c) Optional IOCtrl-drain phase - diagnostic for HD investigation.
   *
   * Bridge gets 1fps IDR-only because the camera is in a default
   * preview/snapshot mode, NOT because of any client-side dispatcher
   * setting (verified via HD-probe: +0x1f84 is already 1 after the
   * existing handshake). The official app must send a follow-up IOCtrl
   * after GETSUPPORTSTREAM to switch the camera to live HD; we don't
   * yet know which one.
   *
   * Set VTECH_DRAIN_IOCTL_SEC=10 to poll avRecvIOCtrl for N seconds and
   * log every response type+len+payload. That reveals what GETSUPPORTSTREAM
   * returns and what other IOCtrls the camera sends spontaneously.
   *
   * stdout is the H.264 stream - drain output goes to stderr (alongside
   * the normal LOG() lines), so production piping (`bridge | ffmpeg`)
   * keeps working. */
  {
    int drain_sec = getenv("VTECH_DRAIN_IOCTL_SEC")
                        ? atoi(getenv("VTECH_DRAIN_IOCTL_SEC"))
                        : 0;
    if (drain_sec > 0) {
      char drain_buf[2048];
      time_t drain_start = time(NULL);
      int seen = 0;
      LOG("=== draining IOCtrl responses for %ds ===", drain_sec);
      while (time(NULL) - drain_start < drain_sec) {
        uint32_t type = 0;
        int n = recv_ioctl(av, &type, drain_buf, sizeof(drain_buf), 100);
        if (n < 0)
          continue;
        seen++;
        char hex[3 * 32 + 1] = {0};
        int show = n < 32 ? n : 32;
        for (int i = 0; i < show; i++)
          snprintf(hex + i * 3, 4, "%02x ", (uint8_t)drain_buf[i]);
        LOG("IOCtrl-rx #%d: type=0x%03x len=%d  %s%s", seen, type, n, hex,
            n > 32 ? "..." : "");
      }
      LOG("=== drain done (saw %d IOCtrl responses) ===", seen);
    }
  }

  /* 8) Receive frames and decrypt. */
  LOG("=== receiving frames for %d s ===", duration);
  char *buf = malloc(5 * 1024 * 1024);
  uint8_t *ptbuf = malloc(5 * 1024 * 1024);
  char info[24];
  uint32_t idx = 0;
  uint32_t frame_no = 0;
  int frames = 0, decrypted = 0, decrypt_fail = 0, passthrough = 0;
  int err_count = 0;
  int last_err = 0;
  time_t start = time(NULL);
  while (duration == 0 || time(NULL) - start < duration) {
    rc = recv_frame(av, buf, 5 * 1024 * 1024, NULL, NULL, info, 24, &idx,
                    &frame_no);
    if (rc < 0) {
      err_count++;
      if (rc != last_err) {
        LOG("recv_frame err=%d (0x%x)", rc, (unsigned)rc);
        last_err = rc;
      }
      usleep(20 * 1000);
      continue;
    }
    frames++;
    const uint8_t *out_buf = (uint8_t *)buf;
    int out_len = rc;

    /* Encrypted frames are always >= 60 bytes (key+nonce+tag minimum).
     * Smaller frames are banner-mode passthrough (or impossible). */
    if (cc.ready && rc >= 60) {
      int n = decrypt_frame(&cc, (uint8_t *)buf, rc, ptbuf, 5 * 1024 * 1024);
      if (n >= 0) {
        out_buf = ptbuf;
        out_len = n;
        decrypted++;
      } else {
        /* Decrypt failed - could be unencrypted banner frame mixed in
         * during transition, or genuine corruption. Drop and log. */
        decrypt_fail++;
        if (decrypt_fail <= 5)
          LOG("decrypt fail rc=%d frame#%d size=%d", n, frames, rc);
        continue;
      }
    } else {
      passthrough++;
    }

    if (frames <= 5 || frames % 30 == 0) {
      uint16_t codec = *(uint16_t *)info;
      LOG("frame#%d codec=%u in=%d out=%d (dec=%d pass=%d fail=%d)", frames,
          codec, rc, out_len, decrypted, passthrough, decrypt_fail);
    }
    static const unsigned char prefix[4] = {0, 0, 0, 1};
    if (out_len >= 4 && out_buf[0] == 0 && out_buf[1] == 0 && out_buf[2] == 0) {
      if (out_buf[3] == 1) {
        /* Annex-B already, write as-is */
        fwrite(out_buf, 1, out_len, stdout);
      } else {
        fwrite(prefix, 1, 4, stdout);
        fwrite(out_buf + 4, 1, out_len - 4, stdout);
      }
    } else {
      fwrite(prefix, 1, 4, stdout);
      fwrite(out_buf, 1, out_len, stdout);
    }
    fflush(stdout);
  }
  LOG("totals: frames=%d  decrypted=%d  passthrough=%d  decrypt_fail=%d  "
      "err=%d  last_err=%d (0x%x)",
      frames, decrypted, passthrough, decrypt_fail, err_count, last_err,
      (unsigned)last_err);
  free(buf);
  free(ptbuf);
  return 0;
}
